import SwiftUI
import Photos

private struct LocalPlaybackPauseKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var pauseLocalPlayback: () -> Void {
        get { self[LocalPlaybackPauseKey.self] }
        set { self[LocalPlaybackPauseKey.self] = newValue }
    }
}

struct RemotePlaybackRequest: Identifiable {
    let id = UUID()
    let clips: [LessonClip]
    let selectedID: String
}

struct DriveRemoteVideoRows: View {
    let clips: [LessonClip]
    var viewingHistory = false
    var playbackQueue: [LessonClip]? = nil
    var collection: DriveCollection? = nil
    var nextPage = 1
    var hasMore = false
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var playing: RemotePlaybackRequest?
    @State private var options: LessonClip?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(clips) { clip in
                if clip.id != clips.first?.id { Divider().padding(.leading, 76) }
                HStack(spacing: 4) {
                    Button {
                        var queue = playbackQueue ?? clips
                        if !queue.contains(where: { $0.id == clip.id }) { queue.insert(clip, at: 0) }
                        playing = .init(clips: queue, selectedID: clip.id)
                    } label: {
                        HStack(spacing: 12) {
                            thumbnail(clip)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: library.favorites.first(where: { $0.id == clip.id })?.title ?? clip.title)
                                    .driveFont(15, relativeTo: .subheadline, weight: .medium)
                                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 2).truncationMode(.middle)
                                if viewingHistory, let position = library.remotePlayback.first(where: { $0.id == clip.id })?.viewing {
                                    Text(verbatim: Self.time(position.seconds) + " / " + Self.time(position.duration))
                                        .driveFont(12, relativeTo: .caption).monospacedDigit()
                                        .foregroundStyle(DriveStyle.secondary)
                                    DriveMeter(value: position.seconds / max(1, position.duration), tint: DriveStyle.accent)
                                } else if let record = library.savedVideo(clip.id) {
                                    LocalizedText(record.state.title).driveFont(12, relativeTo: .caption)
                                        .foregroundStyle(record.state == .failed ? GlamoStyle.danger : DriveStyle.secondary)
                                    if let duration = record.duration ?? clip.duration {
                                        Text(verbatim: Self.time(duration)).font(.glam(.caption)).monospacedDigit()
                                            .foregroundStyle(DriveStyle.secondary)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.multilineTextAlignment(.leading).padding(.vertical, 12).padding(.leading, 12)
                            .contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                    IconButton(symbol: .driveMore, label: "Video options", tint: DriveStyle.secondary) { options = clip }
                }
            }
        }
        .foregroundStyle(DriveStyle.ink)
        .glamoGlass(in: RoundedRectangle(cornerRadius: DriveStyle.cardRadius), tint: .white)
        .fullScreenCover(item: $playing) { request in
            LinkedVideoView(search: "", initialClips: request.clips, selectedClipID: request.selectedID,
                            initialCollection: collection, collectionNextPage: nextPage, collectionHasMore: hasMore)
        }
        .sheet(item: $options) { DriveRemoteVideoActions(clip: $0) }
    }

    private func thumbnail(_ clip: LessonClip) -> some View {
        AsyncImage(url: clip.coverURL) { image in image.resizable().scaledToFill() } placeholder: {
            Image("DriveShelf").resizable().scaledToFit()
        }
        .frame(width: 56, height: 64).background(DriveStyle.background)
        .overlay { Glyph(symbol: .play, size: 17, tint: .white).shadow(color: .black.opacity(0.7), radius: 3, y: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return "0:00" }
        let value = Int(seconds)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct DriveRemoteVideoActions: View {
    let clip: LessonClip
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @State private var renaming = false
    @State private var moving = false
    @State private var deleting = false
    @State private var exporting = false
    @State private var collectionPrompt = false
    @State private var collectionMembership = false
    @State private var moveAfterSaving = false
    @State private var error: String?
    private var saved: Bool { library.isSaved(clip) }
    private var title: String { library.favorites.first { $0.id == clip.id }?.title ?? clip.title }

    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                SheetHeading(title: "Video options") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: title).font(.glam(.headline)).fixedSize(horizontal: false, vertical: true)
                        if let record = library.savedVideo(clip.id) {
                            LocalizedText(record.state.title).font(.glam(.subheadline)).foregroundStyle(DriveStyle.secondary)
                            if let failure = record.failure { ErrorNote(message: failure) }
                        }
                        ActionButton(title: "Export video") { exporting = true }
                        if !saved {
                            ActionButton(title: "Save video", primary: false) { save(moveAfter: false) }
                            ActionButton(title: "Move to folder", primary: false) { save(moveAfter: true) }
                        }
                        if saved {
                            ActionButton(title: "Rename", primary: false) { renaming = true }
                            ActionButton(title: "Move to folder", primary: false) { moving = true }
                            if library.savedVideo(clip.id)?.state != .ready {
                                ActionButton(title: "Download again", primary: false) { library.offline.enqueue(clip.id) }
                            }
                            ActionButton(title: "Remove saved video", primary: false) { deleting = true }
                        }
                        if let error { ErrorNote(message: error) }
                    }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }.scrollBounceBehavior(.basedOnSize)
            }.padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }
        .driveScreenBackground()
        .sheet(isPresented: $renaming) {
            DriveNameSheet(title: "Rename", startingName: title) { try library.renameSavedVideo(clip.id, to: $0) }
        }
        .sheet(isPresented: $moving) { SavedVideoMoveSheet(clip: clip) }
        .sheet(isPresented: $exporting) { RemoteVideoExportView(clip: clip) }
        .fullScreenCover(isPresented: $collectionMembership, onDismiss: {
            if commerce.premium { finishSaving() }
        }) { MembershipView() }
        .overlay {
            if deleting {
                AccountDecisionDialog(title: "Remove saved video", message: "The offline copy will be removed. Your playback history and original video stay available.",
                                      confirmTitle: "Remove saved video", destructive: true, cancel: { deleting = false }) {
                    do { try library.removeSavedVideo(clip.id); deleting = false; dismiss() }
                    catch { self.error = error.localizedDescription; deleting = false }
                }
            }
            if collectionPrompt {
                WatchLimitPrompt(showingMembership: $collectionMembership, kind: .collect, finish: finishSaving)
            }
        }
    }
    private func save(moveAfter: Bool) {
        moveAfterSaving = moveAfter
        guard quota.mayCollect(premium: commerce.premium) else { collectionPrompt = true; return }
        var charged = false
        do {
            if !library.isSaved(clip) {
                try quota.recordCollection(premium: commerce.premium)
                charged = !commerce.premium
                try library.saveVideo(clip)
            }
            if moveAfter { moving = true }
        } catch {
            if charged { quota.refundCollection() }
            self.error = error.localizedDescription
        }
    }
    private func finishSaving() {
        collectionPrompt = false
        if !saved, quota.mayCollect(premium: commerce.premium) { save(moveAfter: moveAfterSaving) }
    }
}

struct DriveCollectionRows: View {
    let collections: [DriveCollection]
    @State private var opened: DriveCollection?
    @State private var playing: RemotePlaybackRequest?
    var body: some View {
        VStack(spacing: 0) {
            ForEach(collections) { collection in
                if collection.id != collections.first?.id { Divider().padding(.leading, 54) }
                Button {
                    if let clip = collection.clip { playing = .init(clips: [clip], selectedID: clip.id) }
                    else { opened = collection }
                } label: {
                    HStack(spacing: 12) {
                        Glyph(symbol: collection.isFolder ? .driveFolder : .play, size: 26, tint: DriveStyle.accent)
                        Text(verbatim: collection.title).font(.glam(.subheadline, weight: .medium))
                            .lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        Glyph(symbol: .back, size: 12, tint: DriveStyle.secondary).rotationEffect(.degrees(180))
                    }.multilineTextAlignment(.leading).padding(14).frame(minHeight: 60).contentShape(Rectangle())
                }.buttonStyle(PressStyle())
            }
        }.foregroundStyle(DriveStyle.ink).glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: .white)
            .fullScreenCover(item: $opened) { DriveCollectionBrowser(initial: $0) }
            .fullScreenCover(item: $playing) {
                LinkedVideoView(search: "", initialClips: $0.clips, selectedClipID: $0.selectedID)
            }
    }
}

struct DriveCollectionBrowser: View {
    let initial: DriveCollection
    @Environment(\.dismiss) private var dismiss
    @State private var path: [DriveCollection] = []
    var body: some View {
        NavigationStack(path: $path) {
            contents(initial)
                .navigationDestination(for: DriveCollection.self) { contents($0) }
        }.toolbar(.hidden, for: .navigationBar)
    }
    private func contents(_ resource: DriveCollection) -> some View {
        DriveCollectionContents(collection: resource, openFolder: { path.append($0) }, back: {
            if path.isEmpty { dismiss() } else { path.removeLast() }
        })
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct IncomingSharedResourceView: View {
    let link: String
    let back: () -> Void
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @State private var resource: DriveCollection?
    @State private var error: String?
    @State private var retry = UUID()
    var body: some View {
        Group {
            if let resource {
                if resource.isFolder { DriveCollectionBrowser(initial: resource) }
                else if let clip = resource.clip { LinkedVideoView(search: "", initialClips: [clip], selectedClipID: clip.id) }
            } else {
                GeometryReader { container in
                    VStack(spacing: 0) {
                        HStack { IconButton(symbol: .back, label: "Back", glass: true, action: back); Spacer() }
                        ScrollView {
                            VStack(spacing: 16) {
                                if api.session == nil { ConnectionPanel() }
                                else if let error {
                                    ErrorNote(message: error)
                                    ActionButton(title: "Try again") { retry = UUID() }
                                } else { AccountLoadingIndicator(title: "Opening link…") }
                            }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
                        }
                    }.padding(drivePaneMargins(in: container, includesHorizontalFold: true))
                }.driveScreenBackground()
            }
        }
        .task(id: "\(api.session?.userId.value ?? ""):\(retry.uuidString)") {
            guard api.session != nil, resource == nil else { return }
            let owner = api.session?.userId.value
            error = nil
            do {
                let item = try await api.sharedResource(link: link)
                try Task.checkCancellation()
                guard owner == api.session?.userId.value else { return }
                resource = item
                library.record(link: link, title: item.title)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct DriveCollectionContents: View {
    let collection: DriveCollection
    let openFolder: (DriveCollection) -> Void
    let back: () -> Void
    @EnvironmentObject private var api: APIClient
    @StateObject private var store = DriveCollectionStore()
    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    IconButton(symbol: .back, label: "Back", glass: true, action: back)
                    Text(verbatim: collection.title).font(.glam(.headline)).lineLimit(2).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
                }.padding(.horizontal, 16).padding(.vertical, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.items.filter(\.isFolder)) { folder in
                            Button { openFolder(folder) } label: {
                                HStack(spacing: 12) {
                                    Glyph(symbol: .driveFolder, size: 24, tint: DriveStyle.accent)
                                    Text(verbatim: folder.title).font(.glam(.subheadline)).frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(16).frame(minHeight: 56).contentShape(Rectangle())
                            }.buttonStyle(PressStyle()).glamoCard(radius: 14)
                        }
                        let clips = store.items.compactMap(\.clip)
                        if !clips.isEmpty {
                            DriveRemoteVideoRows(clips: clips, collection: collection, nextPage: store.page, hasMore: store.hasMore)
                        }
                        if store.loading { AccountLoadingIndicator(title: "Loading videos…").frame(maxWidth: .infinity) }
                        if let error = store.error {
                            ErrorNote(message: error)
                            ActionButton(title: "Try again", primary: false) { load() }
                        } else if store.items.isEmpty && !store.loading {
                            GlamoEmptyState(title: "No videos here yet", message: "This folder has no videos yet.", art: "DriveShelf") {
                                ActionButton(title: "Try again", primary: false) { load(refresh: true) }
                            }
                        } else if store.hasMore && !store.loading {
                            ActionButton(title: "Load more videos", primary: false) { load() }
                                .onAppear { load() }
                        }
                    }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }.refreshable { await store.load(collection, api: api, refresh: true) }
            }.padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }.driveScreenBackground()
            .task { await store.load(collection, api: api) }
    }
    private func load(refresh: Bool = false) { Task { await store.load(collection, api: api, refresh: refresh) } }
}

struct SavedVideoMoveSheet: View {
    let clip: LessonClip
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var error: String?
    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                SheetHeading(title: "Move to folder") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: clip.title).font(.glam(.headline))
                        LocalizedText("Current location").font(.glam(.footnote)).foregroundStyle(DriveStyle.secondary)
                        Text(verbatim: path(library.savedVideo(clip.id)?.folderID)).font(.glam(.subheadline))
                        destination(nil)
                        ForEach(library.folders.sorted { path($0.id).localizedStandardCompare(path($1.id)) == .orderedAscending }) { folder in
                            destination(folder)
                        }
                        if let error { ErrorNote(message: error) }
                    }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
            }.padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }.driveScreenBackground()
    }
    private func path(_ id: UUID?) -> String {
        ([L10n.text("All Files")] + library.folderPath(to: id).map(\.name)).joined(separator: " / ")
    }
    private func destination(_ folder: VideoFolder?) -> some View {
        Button {
            do { try library.moveSavedVideo(clip.id, into: folder?.id); dismiss() }
            catch { self.error = error.localizedDescription }
        } label: {
            HStack(spacing: 12) {
                Glyph(symbol: .driveFolder, size: 20, tint: DriveStyle.accent)
                Text(verbatim: path(folder?.id)).font(.glam(.subheadline)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if library.savedVideo(clip.id)?.folderID == folder?.id {
                    LocalizedText("Current location").font(.glam(.caption)).foregroundStyle(DriveStyle.secondary)
                }
            }.padding(12).frame(minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(PressStyle()).glamoCard(radius: 14)
    }
}

struct OfflineTransfersSection: View {
    @ObservedObject var cache: OfflineVideoCache
    let records: [SavedVideo]
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LocalizedText("Offline downloads").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: library.favorites.first { $0.id == record.id }?.title ?? "")
                        .font(.glam(.subheadline, weight: .medium)).lineLimit(2).truncationMode(.middle)
                    HStack(spacing: 10) {
                        LocalizedText(record.state.title).font(.glam(.footnote))
                            .foregroundStyle(record.state == .failed ? GlamoStyle.danger : DriveStyle.secondary)
                        Spacer(minLength: 0)
                        if record.state == .downloading {
                            Text(verbatim: (cache.progress[record.id] ?? 0).formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                                .font(.glam(.footnote)).monospacedDigit()
                            IconButton(symbol: .pause, label: "Pause download") { cache.pause(record.id) }
                        } else if record.state != .ready {
                            IconButton(symbol: .play, label: record.state == .failed ? "Retry download" : "Resume download") { cache.enqueue(record.id) }
                        }
                    }
                    if record.state == .downloading { DriveMeter(value: cache.progress[record.id] ?? 0, tint: DriveStyle.accent) }
                    if let failure = record.failure { ErrorNote(message: failure) }
                }.padding(14).glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: .white)
            }
        }
    }
}

struct PlaybackSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var preferences = PlaybackPreferences.shared
    @Environment(\.locale) private var locale
    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                SheetHeading(title: "Playback settings") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            LocalizedText("Default playback speed").font(.glam(.headline))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                                ForEach(PlaybackPreferences.rates, id: \.self) { rate in
                                    Button { preferences.speed = rate } label: {
                                        VStack(spacing: 4) {
                                            Text(verbatim: driveRateText(rate, locale: locale))
                                            if preferences.speed == rate { LocalizedText("Selected").font(.glam(.caption)) }
                                        }.font(.glam(.subheadline, weight: .semibold))
                                            .frame(maxWidth: .infinity, minHeight: 56)
                                            .foregroundStyle(preferences.speed == rate ? .white : DriveStyle.ink)
                                            .background(preferences.speed == rate ? DriveStyle.accent : .white, in: RoundedRectangle(cornerRadius: 14))
                                    }.buttonStyle(PressStyle()).accessibilityAddTraits(preferences.speed == rate ? .isSelected : [])
                                }
                            }
                        }
                        setting("Resume playback", detail: "Continue from where you stopped.", value: $preferences.resume)
                        setting("Loop playback", detail: "Replay the current video when it ends.", value: $preferences.loop)
                    }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }.scrollBounceBehavior(.basedOnSize)
            }.padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }.driveScreenBackground()
    }
    private func setting(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    LocalizedText(title).font(.glam(.headline)).frame(maxWidth: .infinity, alignment: .leading)
                    LocalizedText(value.wrappedValue ? "On" : "Off").font(.glam(.subheadline, weight: .semibold))
                        .foregroundStyle(value.wrappedValue ? DriveStyle.accent : DriveStyle.secondary)
                }
                LocalizedText(detail).font(.glam(.subheadline)).foregroundStyle(DriveStyle.secondary)
            }.multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .padding(16).frame(maxWidth: .infinity, minHeight: 60).contentShape(Rectangle())
        }.buttonStyle(PressStyle()).glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: .white)
            .accessibilityValue(LocalizedStringKey(value.wrappedValue ? "On" : "Off"))
    }
}

enum MediaStorageSize {
    static func bytes(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
        if values.isRegularFile == true { return values.fileSize.map(Int64.init) }
        guard values.isDirectory == true, let scan = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return nil }
        var size: Int64 = 0
        for case let file as URL in scan {
            guard let item = try? file.resourceValues(forKeys: keys), item.isSymbolicLink != true else { continue }
            if item.isRegularFile == true { size += Int64(item.fileSize ?? 0) }
        }
        return size
    }
}

struct StorageManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pauseLocalPlayback) private var pauseLocalPlayback
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @State private var sizes: [UUID: Int64] = [:]
    @State private var options: PracticeRecording?
    private var revision: [String] { library.movies.map { $0.id.uuidString } + library.savedVideos.map { "\($0.id):\($0.state.rawValue)" } }
    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                SheetHeading(title: "File storage") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(library.movies.sorted { (sizes[$0.id] ?? $0.byteCount ?? 0) > (sizes[$1.id] ?? $1.byteCount ?? 0) }) { file in
                            Button { options = file } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(verbatim: file.displayName).font(.glam(.subheadline, weight: .medium)).lineLimit(2).truncationMode(.middle)
                                    Text(verbatim: (sizes[file.id] ?? file.byteCount ?? 0).formatted(.byteCount(style: .file).locale(locale)))
                                        .font(.glam(.footnote)).foregroundStyle(DriveStyle.secondary)
                                }.multilineTextAlignment(.leading).padding(14).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(PressStyle()).glamoCard(radius: 14)
                        }
                        if !library.favorites.isEmpty {
                            LocalizedText("Saved").font(.glam(.headline))
                            DriveRemoteVideoRows(clips: library.favorites)
                        }
                        if library.movies.isEmpty, library.favorites.isEmpty {
                            GlamoEmptyState(title: "No files yet", message: "Add your first file to keep everything in one place.", art: "DriveShelf") {
                                ActionButton(title: "Done", primary: false) { dismiss() }
                            }
                        }
                    }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
            }.padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }.driveScreenBackground()
            .sheet(item: $options) { DriveItemSheet(item: .file($0), pausePlayback: pauseLocalPlayback) }
            .task(id: revision) {
                let files = library.movies.map { ($0.id, library.url(for: $0)) }
                let result = await Task.detached(priority: .utility) {
                    Dictionary(files.map { ($0.0, MediaStorageSize.bytes(at: $0.1) ?? 0) }, uniquingKeysWith: { first, _ in first })
                }.value
                if !Task.isCancelled { sizes = result }
            }
    }
}

struct RemoteVideoExportView: View {
    let clip: LessonClip
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @StateObject private var editor = VideoEditor()
    @State private var job: Task<Void, Never>?
    @State private var result: PracticeRecording?
    @State private var share: SharedFile?
    @State private var paywall = false
    @State private var cancelPrompt = false
    @State private var message: String?
    @State private var failure: String?
    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                SheetHeading(title: "Export video") { if job != nil { cancelPrompt = true } else { dismiss() } }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(verbatim: clip.title).font(.glam(.headline)).fixedSize(horizontal: false, vertical: true)
                        if editor.isLoading { AccountLoadingIndicator(title: "Preparing video…") }
                        if editor.duration > 0 {
                            VideoSurface(player: editor.preview.player, fill: false).aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            if job == nil, result == nil {
                                ActionButton(title: "Export MP4") { export(audio: false) }
                                ActionButton(title: "Export M4A", primary: false) { export(audio: true) }
                            }
                        }
                        if editor.isExporting {
                            LocalizedText("Exporting…").font(.glam(.headline))
                            DriveMeter(value: Double(editor.progress), tint: DriveStyle.accent)
                            ActionButton(title: "Cancel export", primary: false) { cancelPrompt = true }
                        } else if job != nil {
                            AccountLoadingIndicator(title: "Preparing file…")
                        }
                        if let file = result {
                            Text(verbatim: file.displayName).font(.glam(.subheadline, weight: .semibold))
                            Text(verbatim: file.fileExtension.uppercased() + " · " + (file.byteCount ?? 0).formatted(.byteCount(style: .file)))
                                .font(.glam(.footnote)).foregroundStyle(DriveStyle.secondary)
                            LocalizedText("Your exported file is still in your library.").font(.glam(.footnote))
                            ActionButton(title: "Share file") { shareFile(file) }
                            if !file.isAudio { ActionButton(title: "Save to Photos", primary: false) { saveToPhotos(file) } }
                        }
                        if let message { LocalizedText(message).font(.glam(.subheadline)).foregroundStyle(DriveStyle.accent) }
                        if let error = failure ?? editor.error {
                            ErrorNote(message: error)
                            if job == nil, result == nil {
                                ActionButton(title: "Try again", primary: false) { Task { await editor.open(library.playbackURL(for: clip)) } }
                            }
                        }
                    }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }.scrollBounceBehavior(.basedOnSize)
            }.padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }
        .driveScreenBackground().interactiveDismissDisabled(job != nil)
        .task { await editor.open(library.playbackURL(for: clip)) }
        .onDisappear { job?.cancel(); editor.close() }
        .fullScreenCover(isPresented: $paywall) { MembershipView(requiredBenefit: .mediaExport) }
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url]) { outcome in
                switch outcome {
                case .completed:
                    message = "Share complete"
                    if let id = result?.id { library.recordSharedFile(id) }
                case .cancelled: message = "Sharing cancelled"
                case .failed(let reason): failure = reason
                }
            }
        }
        .overlay {
            if cancelPrompt {
                AccountDecisionDialog(title: "Stop export?", message: "Your original video will stay available.",
                                      confirmTitle: "Stop export", destructive: true, cancel: { cancelPrompt = false }) {
                    job?.cancel(); editor.cancelExport(); cancelPrompt = false
                }
            }
        }
    }
    private func export(audio: Bool) {
        guard job == nil else { return }
        guard commerce.canExportMedia else { paywall = true; return }
        failure = nil; message = nil
        let owner = commerce.api.session?.userId.value
        job = Task {
            defer { job = nil }
            guard let output = await editor.export(audioOnly: audio) else { return }
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try Task.checkCancellation()
                try commerce.requireMediaExport()
                guard commerce.api.session?.userId.value == owner else { throw GlamoError.unauthorized }
                result = try await library.importMovie(output, exported: true, title: clip.title,
                                                        folderID: library.savedVideo(clip.id)?.folderID)
            } catch { failure = error.localizedDescription }
        }
    }
    private func shareFile(_ file: PracticeRecording) {
        guard job == nil else { return }
        job = Task {
            defer { job = nil }
            do { share = SharedFile(url: try await library.shareFile(for: file, commerce: commerce), recordingID: file.id) }
            catch { failure = error.localizedDescription }
        }
    }
    private func saveToPhotos(_ file: PracticeRecording) {
        guard job == nil else { return }
        job = Task {
            defer { job = nil }
            do {
                try commerce.requireMediaExport()
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    throw GlamoError.service("Allow photo access in Settings to save this video.")
                }
                try Task.checkCancellation()
                let fileURL = library.url(for: file)
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                }
                message = "Saved to Photos"
            } catch { failure = error.localizedDescription }
        }
    }
}
