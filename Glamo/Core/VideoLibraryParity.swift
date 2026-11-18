import Foundation
import Combine

enum OfflineVideoState: String, Codable {
    case queued, downloading, paused, ready, failed
    var title: String {
        switch self {
        case .queued: "Waiting to download"
        case .downloading: "Downloading…"
        case .paused: "Download paused"
        case .ready: "Available offline"
        case .failed: "Download failed"
        }
    }
}

struct SavedVideo: Codable, Identifiable, Hashable {
    let id: String
    var addedAt: Date
    var folderID: UUID?
    var state: OfflineVideoState = .queued
    var requestID: UUID?
    var cacheFilename: String?
    // HLS assets stay at the system's location, relative to the app container.
    var assetPath: String?
    var byteCount: Int64?
    var failure: String?
    var duration: Double?
}

struct RemotePlaybackRecord: Codable, Identifiable, Hashable {
    var clip: LessonClip
    var viewing: FileViewingPosition
    var id: String { clip.id }
}

@MainActor
final class PlaybackPreferences: ObservableObject {
    static let shared = PlaybackPreferences()
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private let defaults = UserDefaults.standard
    @Published var speed: Float {
        didSet { defaults.set(speed, forKey: "vifol.playback.defaultSpeed") }
    }
    @Published var resume: Bool {
        didSet { defaults.set(resume, forKey: "vifol.playback.resume") }
    }
    @Published var loop: Bool {
        didSet { defaults.set(loop, forKey: "vifol.playback.loop") }
    }
    private init() {
        let settings = UserDefaults.standard
        let rate = settings.float(forKey: "vifol.playback.defaultSpeed")
        speed = Self.rates.contains(rate) ? rate : 1
        resume = settings.object(forKey: "vifol.playback.resume") as? Bool ?? true
        loop = settings.bool(forKey: "vifol.playback.loop")
    }
}

@MainActor
extension LibraryStore {
    var savedVideos: [SavedVideo] { snapshot.savedVideos ?? [] }
    var remotePlayback: [RemotePlaybackRecord] { snapshot.remotePlayback ?? [] }
    var favoriteFiles: [PracticeRecording] { movies.filter { $0.isFavorite == true } }
    var recentlyPlayedFiles: [PracticeRecording] {
        movies.filter { ($0.viewing?.date ?? .distantPast) > (snapshot.playbackHistoryClearedAt ?? .distantPast) }
    }
    var recentRemotePlayback: [RemotePlaybackRecord] {
        remotePlayback.filter { $0.viewing.date > (snapshot.playbackHistoryClearedAt ?? .distantPast) }
    }

    func prepareSavedVideos() throws {
        guard Set(savedVideos.map(\.id)) != Set(favorites.map(\.id)) else { return }
        let previous = Dictionary(savedVideos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        try updateLibrary { next in
            next.savedVideos = next.favorites.map {
                previous[$0.id] ?? SavedVideo(id: $0.id, addedAt: Date(), folderID: nil)
            }
        }
    }

    func savedVideo(_ id: String) -> SavedVideo? { savedVideos.first { $0.id == id } }

    func offlineURL(for record: SavedVideo) -> URL? {
        let fm = FileManager.default
        if let filename = record.cacheFilename, filename == (filename as NSString).lastPathComponent {
            let url = storageRoot.appendingPathComponent("Offline", isDirectory: true).appendingPathComponent(filename)
            if fm.fileExists(atPath: url.path) { return url }
        }
        if let path = record.assetPath, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") {
            let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(path).standardizedFileURL
            let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library").path + "/"
            if url.path.hasPrefix(library), url.pathExtension == "movpkg", fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func playbackURL(for clip: LessonClip) -> URL {
        if let record = savedVideo(clip.id), record.state == .ready, let local = offlineURL(for: record) { return local }
        return favorites.first(where: { $0.id == clip.id })?.playbackURL ?? clip.playbackURL
    }

    func requiresWatchAllowance(_ clip: LessonClip) -> Bool {
        !clip.playbackURL.isFileURL && clip.isDirect != true && !isSaved(clip)
    }

    func saveVideo(_ clip: LessonClip, into folderID: UUID? = nil) throws {
        guard !isSaved(clip) else { return }
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else { throw GlamoError.storage }
        try updateLibrary { next in
            next.favorites.insert(clip, at: 0)
            var records = next.savedVideos ?? []
            records.insert(SavedVideo(id: clip.id, addedAt: Date(), folderID: folderID), at: 0)
            next.savedVideos = records
        }
        offline.enqueue(clip.id)
    }

    func removeSavedVideo(_ id: String) throws {
        let record = savedVideo(id)
        try updateLibrary { next in
            next.favorites.removeAll { $0.id == id }
            next.savedVideos?.removeAll { $0.id == id }
        }
        offline.remove(id, record: record)
    }

    func updateSavedVideo(_ id: String, change: (inout SavedVideo) -> Void) throws {
        try updateLibrary { next in
            guard let index = next.savedVideos?.firstIndex(where: { $0.id == id }) else { throw GlamoError.storage }
            change(&next.savedVideos![index])
        }
    }

    func moveSavedVideo(_ id: String, into folderID: UUID?) throws {
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else { throw GlamoError.storage }
        try updateSavedVideo(id) { $0.folderID = folderID }
    }

    func renameSavedVideo(_ id: String, to input: String) throws {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120,
              name.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: "/\\:"))) == nil else {
            throw GlamoError.service("Enter a name of up to 120 characters, without slashes or colons.")
        }
        try updateLibrary { next in
            guard let index = next.favorites.firstIndex(where: { $0.id == id }) else { throw GlamoError.storage }
            next.favorites[index].title = name
            if let history = next.remotePlayback?.firstIndex(where: { $0.id == id }) {
                next.remotePlayback?[history].clip.title = name
            }
        }
    }

    func toggleFileFavorite(_ id: UUID) throws {
        try updateLibrary { next in
            guard let index = next.movies.firstIndex(where: { $0.id == id }) else { throw GlamoError.storage }
            next.movies[index].isFavorite = !(next.movies[index].isFavorite ?? false)
        }
    }

    func recordRemotePlayback(_ clip: LessonClip, seconds: Double, duration: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        do {
            try updateLibrary { next in
                var records = next.remotePlayback ?? []
                records.removeAll { $0.id == clip.id }
                let current = next.favorites.first(where: { $0.id == clip.id }) ?? clip
                records.insert(RemotePlaybackRecord(clip: current, viewing: .init(date: Date(),
                    seconds: max(0, min(seconds, duration)), duration: duration)), at: 0)
                next.remotePlayback = Array(records.prefix(20))
                if let index = next.savedVideos?.firstIndex(where: { $0.id == clip.id }) {
                    next.savedVideos?[index].duration = duration
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func clearPlaybackHistory() throws {
        try updateLibrary { next in
            // History visibility and resume positions are independent, as in
            // the reference. Clearing history never resets saved positions.
            next.playbackHistoryClearedAt = Date()
        }
    }
    func clearSavedVideos() throws {
        let records = savedVideos
        try updateLibrary { next in
            next.favorites = []; next.savedVideos = []
            for index in next.movies.indices { next.movies[index].isFavorite = false }
        }
        for record in records { offline.remove(record.id, record: record) }
    }
}
