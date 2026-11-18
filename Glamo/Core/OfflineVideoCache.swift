import Foundation
import AVFoundation
import UIKit
import Combine

private struct OfflineRequest: Codable, Sendable {
    let videoID: String
    let generation: UUID
    var description: String { (try? JSONEncoder().encode(self).base64EncodedString()) ?? "" }
    init(videoID: String, generation: UUID) { self.videoID = videoID; self.generation = generation }
    init?(_ task: URLSessionTask) {
        guard let value = task.taskDescription, let data = Data(base64Encoded: value),
              let request = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = request
    }
}

// The delegate runs on the main operation queue. Plain-file temporary URLs must
// be moved synchronously, before Foundation removes them after the callback.
private final class OfflineDownloadDelegate: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate, @unchecked Sendable {
    enum Event {
        case progress(OfflineRequest, Double)
        case file(OfflineRequest, URL)
        case asset(OfflineRequest, URL)
        case playlist(OfflineRequest)
        case completed(OfflineRequest, String?)
        case finished(String)
    }
    let directory: URL
    let receive: @MainActor (Event) -> Void
    init(directory: URL, receive: @escaping @MainActor (Event) -> Void) {
        self.directory = directory; self.receive = receive
    }
    private func send(_ event: Event) { MainActor.assumeIsolated { receive(event) } }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let request = OfflineRequest(downloadTask) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            send(.completed(request, "The video server could not provide this file. Try again later.")); return
        }
        do {
            let handle = try FileHandle(forReadingFrom: location)
            let prefix = try handle.read(upToCount: 512) ?? Data()
            try handle.close()
            if String(data: prefix, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") == true {
                send(.playlist(request)); return
            }
            guard !prefix.isEmpty else { throw GlamoError.invalidResponse }
            let text = String(data: prefix, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !text.hasPrefix("<!doctype html"), !text.hasPrefix("<html"),
                  response.mimeType != "application/json", response.mimeType != "text/html" else {
                throw GlamoError.service("The video server returned a page instead of a video. Try opening the link again.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = downloadTask.originalRequest?.url?.pathExtension.lowercased() ?? ""
            let safeExtension = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "ts"].contains(ext) ? ext : "mp4"
            let destination = directory.appendingPathComponent(request.generation.uuidString).appendingPathExtension(safeExtension)
            try FileManager.default.moveItem(at: location, to: destination)
            send(.file(request, destination))
        } catch { send(.completed(request, error.localizedDescription)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let request = OfflineRequest(downloadTask), totalBytesExpectedToWrite > 0 else { return }
        send(.progress(request, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let request = OfflineRequest(assetDownloadTask) else { return }
        send(.asset(request, location))
    }
    @available(iOS 18.0, *)
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        guard let request = OfflineRequest(assetDownloadTask) else { return }
        send(.asset(request, location))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = OfflineRequest(task) else { return }
        send(.completed(request, error?.localizedDescription))
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let id = session.configuration.identifier { send(.finished(id)) }
    }
}

@MainActor
final class OfflineVideoCache: ObservableObject {
    static let fileSessionID = "com.vifol.local-library.saved-files"
    static let assetSessionID = "com.vifol.local-library.saved-hls"
    @Published private(set) var progress: [String: Double] = [:]
    var resolveClip: ((LessonClip) async throws -> LessonClip)?
    private weak var library: LibraryStore?
    private var tasks: [String: URLSessionTask] = [:]
    private var locations: [UUID: URL] = [:]
    private var switchedToHLS = Set<UUID>()
    private var resolving: [String: Task<Void, Never>] = [:]
    private var assetPreparation: [String: Task<Void, Never>] = [:]
    private var progressObservers: [String: NSKeyValueObservation] = [:]
    private var prepared = false
    private var delegate: OfflineDownloadDelegate!
    private var files: URLSession!
    private var assets: AVAssetDownloadURLSession!

    init(library: LibraryStore) {
        self.library = library
        let directory = library.storageRoot.appendingPathComponent("Offline", isDirectory: true)
        delegate = OfflineDownloadDelegate(directory: directory) { [weak self] in self?.receive($0) }
        let fileConfig = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
        fileConfig.isDiscretionary = false
        fileConfig.sessionSendsLaunchEvents = true
        files = URLSession(configuration: fileConfig, delegate: delegate, delegateQueue: .main)
        let assetConfig = URLSessionConfiguration.background(withIdentifier: Self.assetSessionID)
        assetConfig.isDiscretionary = false
        assetConfig.sessionSendsLaunchEvents = true
        assets = AVAssetDownloadURLSession(configuration: assetConfig, assetDownloadDelegate: delegate, delegateQueue: .main)
        OfflineBackgroundEvents.shared.cache = self
    }

    func prepare() async {
        guard !prepared, let library else { return }
        prepared = true
        do { try library.prepareSavedVideos() }
        catch { library.error = error.localizedDescription; return }
        let activeFiles = await files.allTasks
        let activeAssets = await assets.allTasks
        for task in activeFiles + activeAssets {
            guard task.state != .completed, task.state != .canceling else { continue }
            guard let request = OfflineRequest(task),
                  let record = library.savedVideo(request.videoID), record.requestID == request.generation else {
                task.cancel(); continue
            }
            tasks[request.videoID] = task
            observe(task, request: request)
            if record.state == .paused {
                if task.state == .running { task.suspend() }
            } else if task.state == .suspended { task.resume() }
        }
        for record in library.savedVideos {
            if record.state == .ready {
                if library.offlineURL(for: record) != nil { continue }
                try? library.updateSavedVideo(record.id) {
                    $0.state = .failed; $0.failure = "The offline copy is missing. Download it again."
                    $0.cacheFilename = nil; $0.assetPath = nil
                }
            } else if tasks[record.id] == nil, record.state != .paused, record.state != .failed {
                if let url = library.offlineURL(for: record) {
                    let asset = AVURLAsset(url: url)
                    let playable = (try? await asset.load(.isPlayable)) == true
                    let cached = try? await asset.load(.assetCache)
                    let offlineComplete = url.pathExtension != "movpkg" || cached?.isPlayableOffline == true
                    if playable && offlineComplete {
                        try? library.updateSavedVideo(record.id) { $0.state = .ready; $0.failure = nil }
                        continue
                    }
                }
                enqueue(record.id)
            }
        }
    }

    func enqueue(_ id: String) {
        guard let library, let clip = library.favorites.first(where: { $0.id == id }),
              let record = library.savedVideo(id), record.state != .ready,
              resolving[id] == nil, assetPreparation[id] == nil else { return }
        if let task = tasks[id], task.state == .completed || task.state == .canceling {
            tasks[id] = nil
            progressObservers[id] = nil
        }
        if let task = tasks[id] {
            do {
                try library.updateSavedVideo(id) { $0.state = .downloading; $0.failure = nil }
                if task.state == .suspended { task.resume() }
            }
            catch { library.error = error.localizedDescription }
            return
        }
        if let oldURL = library.offlineURL(for: record) { discard(oldURL) }
        if let token = record.requestID { locations[token] = nil }
        let request = OfflineRequest(videoID: id, generation: UUID())
        do {
            try library.updateSavedVideo(id) {
                $0.state = .downloading; $0.requestID = request.generation; $0.failure = nil
                $0.cacheFilename = nil; $0.assetPath = nil
            }
            progress[id] = 0
            if record.state == .failed, clip.isDirect != true, let resolveClip {
                resolving[id] = Task { [weak self] in
                    defer { if self?.isCurrent(request) == true { self?.resolving[id] = nil } }
                    do {
                        let refreshed = try await resolveClip(clip)
                        try Task.checkCancellation()
                        guard let self, self.isCurrent(request) else { return }
                        try library.updateLibrary { next in
                            if let index = next.favorites.firstIndex(where: { $0.id == id }) { next.favorites[index] = refreshed }
                        }
                        self.start(refreshed, request: request)
                    } catch is CancellationError { }
                    catch { self?.fail(request, message: error.localizedDescription) }
                }
            } else {
                start(clip, request: request)
            }
        } catch { library.error = error.localizedDescription }
    }

    func pause(_ id: String) {
        guard let library, library.savedVideo(id)?.state == .downloading else { return }
        do {
            try library.updateSavedVideo(id) { $0.state = .paused }
            resolving.removeValue(forKey: id)?.cancel()
            assetPreparation.removeValue(forKey: id)?.cancel()
            if let task = tasks[id], task.state == .running { task.suspend() }
        }
        catch { library.error = error.localizedDescription }
    }

    func remove(_ id: String, record: SavedVideo?) {
        tasks.removeValue(forKey: id)?.cancel()
        progressObservers[id] = nil
        resolving.removeValue(forKey: id)?.cancel()
        assetPreparation.removeValue(forKey: id)?.cancel()
        progress[id] = nil
        if let record, let url = library?.offlineURL(for: record) { try? FileManager.default.removeItem(at: url) }
        if let token = record?.requestID, let url = locations.removeValue(forKey: token) { discard(url) }
    }

    func invalidate(_ id: String, message: String) {
        guard let library, let record = library.savedVideo(id) else { return }
        do {
            try library.updateSavedVideo(id) {
                $0.state = .failed; $0.failure = message; $0.cacheFilename = nil; $0.assetPath = nil
            }
            remove(id, record: record)
        } catch { library.error = error.localizedDescription }
    }

    private func startAsset(_ clip: LessonClip, request: OfflineRequest) {
        let asset = AVURLAsset(url: clip.originalURL ?? clip.playbackURL)
        assetPreparation[request.videoID] = Task { [weak self] in
            defer { if self?.isCurrent(request) == true { self?.assetPreparation[request.videoID] = nil } }
            do {
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw GlamoError.service("Live streams can’t be saved offline.") }
                try Task.checkCancellation()
                guard let self, self.isCurrent(request), self.library?.savedVideo(request.videoID)?.state != .paused else { return }
                let configuration = AVAssetDownloadConfiguration(asset: asset, title: clip.title)
                let task = self.assets.makeAssetDownloadTask(downloadConfiguration: configuration)
                task.taskDescription = request.description
                self.tasks[request.videoID] = task
                self.observe(task, request: request)
                task.resume()
            } catch is CancellationError { }
            catch { self?.fail(request, message: error.localizedDescription) }
        }
    }
    private func observe(_ task: URLSessionTask, request: OfflineRequest) {
        progressObservers[request.videoID] = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let amount = progress.fractionCompleted
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(request), amount.isFinite else { return }
                self.progress[request.videoID] = min(0.99, max(0, amount))
            }
        }
    }
    private func start(_ clip: LessonClip, request: OfflineRequest) {
        guard isCurrent(request) else { return }
        let source = clip.originalURL ?? clip.playbackURL
        if source.pathExtension.lowercased() == "m3u8" { startAsset(clip, request: request) }
        else {
            let task = files.downloadTask(with: source)
            task.taskDescription = request.description
            tasks[request.videoID] = task
            task.resume()
        }
    }

    private func receive(_ event: OfflineDownloadDelegate.Event) {
        guard let library else { return }
        switch event {
        case .finished(let id): OfflineBackgroundEvents.shared.finish(id)
        case .progress(let request, let amount):
            guard isCurrent(request), amount.isFinite else { return }
            progress[request.videoID] = min(0.99, max(0, amount))
        case .playlist(let request):
            guard isCurrent(request), let clip = library.favorites.first(where: { $0.id == request.videoID }) else { return }
            // A signed endpoint may serve HLS without a .m3u8 path extension.
            switchedToHLS.insert(request.generation)
            startAsset(clip, request: request)
        case .asset(let request, let url), .file(let request, let url):
            guard isCurrent(request) else { discard(url); return }
            locations[request.generation] = url
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path + "/"
            do {
                try library.updateSavedVideo(request.videoID) {
                    if url.pathExtension == "movpkg", url.path.hasPrefix(home + "Library/") {
                        $0.assetPath = String(url.path.dropFirst(home.count))
                    } else if url.deletingLastPathComponent().standardizedFileURL == library.storageRoot.appendingPathComponent("Offline").standardizedFileURL {
                        $0.cacheFilename = url.lastPathComponent
                    }
                }
            } catch { fail(request, message: error.localizedDescription) }
        case .completed(let request, let message):
            if switchedToHLS.remove(request.generation) != nil { return }
            guard isCurrent(request) else {
                if let url = locations.removeValue(forKey: request.generation) { discard(url) }
                return
            }
            tasks[request.videoID] = nil
            progressObservers[request.videoID] = nil
            guard library.savedVideo(request.videoID)?.state != .failed else { return }
            if let message { fail(request, message: message); return }
            guard let url = locations.removeValue(forKey: request.generation)
                ?? library.savedVideo(request.videoID).flatMap({ library.offlineURL(for: $0) }) else {
                fail(request, message: "The download finished without a usable offline file."); return
            }
            do {
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path + "/"
                let isAsset = url.pathExtension == "movpkg"
                guard !isAsset || url.path.hasPrefix(home + "Library/") else { throw GlamoError.storage }
                try library.updateSavedVideo(request.videoID) {
                    $0.state = .ready; $0.failure = nil
                    $0.cacheFilename = isAsset ? nil : url.lastPathComponent
                    $0.assetPath = isAsset ? String(url.path.dropFirst(home.count)) : nil
                    $0.byteCount = attributes.fileSize.map(Int64.init)
                }
                progress[request.videoID] = 1
            } catch { discard(url); fail(request, message: error.localizedDescription) }
        }
    }

    private func isCurrent(_ request: OfflineRequest) -> Bool {
        library?.savedVideo(request.videoID)?.requestID == request.generation
    }
    private func fail(_ request: OfflineRequest, message: String) {
        guard isCurrent(request), let library else { return }
        if let url = locations.removeValue(forKey: request.generation) { discard(url) }
        tasks.removeValue(forKey: request.videoID)?.cancel()
        progressObservers[request.videoID] = nil
        do { try library.updateSavedVideo(request.videoID) { $0.state = .failed; $0.failure = message } }
        catch { library.error = error.localizedDescription }
    }
    private func discard(_ url: URL) {
        guard url.isFileURL, let library else { return }
        let path = url.standardizedFileURL.path
        let offlineRoot = library.storageRoot.appendingPathComponent("Offline").standardizedFileURL.path + "/"
        let systemRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library").path + "/"
        guard path.hasPrefix(offlineRoot) || (path.hasPrefix(systemRoot) && url.pathExtension == "movpkg") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class OfflineBackgroundEvents {
    static let shared = OfflineBackgroundEvents()
    weak var cache: OfflineVideoCache?
    private var handlers: [String: () -> Void] = [:]
    func handle(_ identifier: String, completion: @escaping () -> Void) {
        guard [OfflineVideoCache.fileSessionID, OfflineVideoCache.assetSessionID].contains(identifier) else { completion(); return }
        handlers[identifier] = completion
        if let cache { Task { await cache.prepare() } }
    }
    func finish(_ identifier: String) { handlers.removeValue(forKey: identifier)?() }
}

final class VifolApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        OfflineBackgroundEvents.shared.handle(identifier, completion: completionHandler)
    }
}
