import Foundation
import AVFoundation
import Combine
import CoreTransferable
import UniformTypeIdentifiers

struct VideoImportBatch {
    struct Failure: Identifiable {
        let id = UUID()
        let name: String
        let message: String
    }
    let total: Int
    var processed = 0
    var currentName = ""
    var failures: [Failure] = []
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LessonLibrarySnapshot()
    @Published var error: String?
    @Published private(set) var importingVideo = false
    @Published private(set) var fileImport: VideoImportBatch?
    private let root: URL
    private let snapshotURL: URL
    private var readable = true

    func beginVideoImport() -> Bool {
        guard !importingVideo else { return false }
        fileImport = nil
        importingVideo = true
        return true
    }

    func finishVideoImport() { importingVideo = false }

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("GlamoMedia", isDirectory: true)
        snapshotURL = root.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                snapshot = try JSONDecoder().decode(LessonLibrarySnapshot.self, from: Data(contentsOf: snapshotURL))
            }
        } catch {
            readable = false
            self.error = "Your local library could not be read. Existing files have been preserved."
        }
    }
    var movies: [PracticeRecording] { snapshot.movies }
    var folders: [VideoFolder] { snapshot.folders ?? [] }
    var favorites: [LessonClip] { snapshot.favorites }
    func url(for movie: PracticeRecording) -> URL { root.appendingPathComponent(movie.filename) }
    // Internal IDs stay stable; only the user-facing shared copy gets a readable name.
    func shareFile(for movie: PracticeRecording, commerce: CommerceStore) async throws -> URL {
        try commerce.requireMediaExport()
        let exportOwner = commerce.api.session?.userId.value
        let source = url(for: movie)
        let title = movie.title
        let task = Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("GlamoSharedVideos", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            // Expired staged copies are disposable; never touch the media library.
            for old in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                if let created = try? old.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   created < Date().addingTimeInterval(-7 * 86_400) { try? fm.removeItem(at: old) }
            }
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
            var name = title.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if ["mp4", "mov", "m4v", "m4a"].contains((name as NSString).pathExtension.lowercased()) {
                name = (name as NSString).deletingPathExtension
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            while name.utf8.count > 160 { name.removeLast() }
            if name.isEmpty { name = "Glamo video" }
            let destination = directory.appendingPathComponent(name).appendingPathExtension(source.pathExtension)
            do {
                try Task.checkCancellation()
                try fm.copyItem(at: source, to: destination)
                try Task.checkCancellation()
                return destination
            } catch { try? fm.removeItem(at: directory); throw error }
        }
        let destination = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        do {
            try Task.checkCancellation()
            try commerce.requireMediaExport()
            guard exportOwner == commerce.api.session?.userId.value else { throw GlamoError.unauthorized }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }
    func isSaved(_ clip: LessonClip) -> Bool { favorites.contains { $0.id == clip.id } }
    @discardableResult func toggle(_ clip: LessonClip) -> Bool {
        var next = snapshot
        if isSaved(clip) { next.favorites.removeAll { $0.id == clip.id } }
        else { next.favorites.insert(clip, at: 0) }
        do { try persist(next); return true }
        catch { self.error = "Favorites could not be updated. Please try again."; return false }
    }
    func record(link: String, title: String) {
        var next = snapshot
        next.history.removeAll { $0.link == link }
        next.history.insert(LessonLinkVisit(id: UUID(), link: link, title: title, date: Date()), at: 0)
        next.history = Array(next.history.prefix(100))
        save(next)
    }
    func importFiles(_ sources: [URL], into folderID: UUID?) async {
        guard !sources.isEmpty, beginVideoImport() else { return }
        defer { finishVideoImport() }
        var batch = VideoImportBatch(total: sources.count)
        for source in sources {
            guard !Task.isCancelled else { break }
            batch.currentName = source.lastPathComponent
            fileImport = batch
            do {
                _ = try await importMovie(source, folderID: folderID)
            } catch is CancellationError {
                break
            } catch {
                batch.failures.append(.init(name: batch.currentName, message: error.localizedDescription))
            }
            batch.processed += 1
            fileImport = batch
        }
    }

    func importMovie(_ source: URL, exported: Bool = false, title: String? = nil,
                     folderID: UUID? = nil) async throws -> PracticeRecording {
        guard readable else { throw GlamoError.storage }
        let id = UUID()
        let ext = source.pathExtension.lowercased().nilIfBlank ?? "mov"
        var item = PracticeRecording(id: id, filename: id.uuidString + "." + ext,
                                     title: title ?? source.deletingPathExtension().lastPathComponent,
                                     date: Date(), isExport: exported)
        let destination = url(for: item)
        do {
            try await Task.detached(priority: .userInitiated) {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                guard access else {
                    try FileManager.default.copyItem(at: source, to: destination)
                    return
                }
                var readError: NSError?
                var copyError: Error?
                let coordinator = NSFileCoordinator(filePresenter: nil)
                coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &readError) { url in
                    do { try FileManager.default.copyItem(at: url, to: destination) }
                    catch { copyError = error }
                }
                if let readError { throw readError }
                if let copyError { throw copyError }
            }.value
            try Task.checkCancellation()
            let metadata = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { throw GlamoError.unsupportedMedia }
            item.byteCount = metadata.fileSize.map(Int64.init)
            if !exported {
                let asset = AVURLAsset(url: destination)
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard playable, duration.isFinite, duration > 0.1, !tracks.isEmpty else {
                    throw GlamoError.unsupportedMedia
                }
                item.duration = duration
                try Task.checkCancellation()
            }
            var next = snapshot
            item.folderID = folders.contains { $0.id == folderID } ? folderID : nil
            next.movies.insert(item, at: 0)
            try persist(next)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return item
    }

    func createFolder(named input: String, parentID: UUID?) throws {
        if let parentID, !folders.contains(where: { $0.id == parentID }) { throw GlamoError.storage }
        let name = try checkedFolderName(input, parentID: parentID)
        var next = snapshot
        next.folders = folders + [VideoFolder(id: UUID(), name: name, parentID: parentID)]
        try persist(next)
    }

    func renameFolder(_ id: UUID, to input: String) throws {
        var entries = folders
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw GlamoError.storage }
        entries[index].name = try checkedFolderName(input, parentID: entries[index].parentID, excluding: id)
        var next = snapshot
        next.folders = entries
        try persist(next)
    }

    func removeFolder(_ id: UUID) throws {
        guard !movies.contains(where: { $0.folderID == id }), !folders.contains(where: { $0.parentID == id }) else {
            throw GlamoError.service("Move the files and folders out before deleting this folder.")
        }
        var next = snapshot
        next.folders = folders.filter { $0.id != id }
        try persist(next)
    }

    func folderPath(to id: UUID?) -> [VideoFolder] {
        var path: [VideoFolder] = []
        var seen: Set<UUID> = []
        var cursor = id
        while let key = cursor, seen.insert(key).inserted,
              let folder = folders.first(where: { $0.id == key }) {
            path.append(folder)
            cursor = folder.parentID
        }
        return Array(path.reversed())
    }

    func moveFolder(_ id: UUID, into folderID: UUID?) throws {
        var entries = folders
        guard let index = entries.firstIndex(where: { $0.id == id }),
              folderID == nil || entries.contains(where: { $0.id == folderID }),
              !folderPath(to: folderID).contains(where: { $0.id == id }) else {
            throw GlamoError.service("Choose a folder outside this folder.")
        }
        entries[index].name = try checkedFolderName(entries[index].name, parentID: folderID, excluding: id)
        entries[index].parentID = folderID
        var next = snapshot
        next.folders = entries
        try persist(next)
    }

    func moveFile(_ id: UUID, into folderID: UUID?) throws {
        if let folderID, !folders.contains(where: { $0.id == folderID }) { throw GlamoError.storage }
        try changeMovie(id) { $0.folderID = folderID }
    }

    func renameFile(_ id: UUID, to input: String) throws {
        let name = try checkedName(input)
        try changeMovie(id) { $0.title = name }
    }

    func saveViewingPosition(for id: UUID, seconds: Double, duration: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0.1,
              movies.contains(where: { $0.id == id }) else { return }
        let position = max(0, min(seconds, duration))
        do {
            try changeMovie(id) {
                $0.viewing = FileViewingPosition(date: Date(), seconds: position, duration: duration)
                $0.duration = duration
            }
        } catch { self.error = error.localizedDescription }
    }

    private func changeMovie(_ id: UUID, change: (inout PracticeRecording) -> Void) throws {
        var next = snapshot
        guard let index = next.movies.firstIndex(where: { $0.id == id }) else { throw GlamoError.storage }
        change(&next.movies[index])
        try persist(next)
    }

    private func checkedName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        guard !name.isEmpty, name.count <= 120, name != ".", name != "..", name.rangeOfCharacter(from: invalid) == nil else {
            throw GlamoError.service("Enter a name of up to 120 characters, without slashes or colons.")
        }
        return name
    }

    private func checkedFolderName(_ input: String, parentID: UUID?, excluding id: UUID? = nil) throws -> String {
        let name = try checkedName(input)
        guard !folders.contains(where: {
            $0.parentID == parentID && $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw GlamoError.service("A folder with that name already exists here.") }
        return name
    }

    func delete(_ movie: PracticeRecording) {
        // Commit index removal first; a failed file deletion leaves an orphan, not a broken library entry.
        var next = snapshot
        next.movies.removeAll { $0.id == movie.id }
        do {
            try persist(next)
            let file = url(for: movie)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ next: LessonLibrarySnapshot) {
        do { try persist(next) } catch { self.error = error.localizedDescription }
    }
    private func persist(_ next: LessonLibrarySnapshot) throws {
        guard readable else { throw GlamoError.storage }
        let data = try JSONEncoder().encode(next)
        // Atomic replacement is the commit point for both the index and its referenced files.
        try data.write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        snapshot = next
    }
}

struct ImportedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in SentTransferredFile(movie.url) }
        importing: { received in
            let ext = received.file.pathExtension.nilIfBlank ?? "mov"
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GlamoImport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(received.file.deletingPathExtension().lastPathComponent)
                .appendingPathExtension(ext)
            do { try FileManager.default.copyItem(at: received.file, to: copy) }
            catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            return ImportedMovie(url: copy)
        }
    }
}
