import SwiftUI
import Photos
@preconcurrency import AVFoundation

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

private struct DriveRemoteListLabel<Preview: View, Metadata: View>: View {
    let title: String
    let preview: Preview
    let metadata: Metadata
    @Environment(\.dynamicTypeSize) private var typeSize

    init(title: String, @ViewBuilder preview: () -> Preview, @ViewBuilder metadata: () -> Metadata) {
        self.title = title
        self.preview = preview()
        self.metadata = metadata()
    }

    var body: some View {
        HStack(spacing: 12) {
            preview.frame(width: 32, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).driveFont(15, relativeTo: .subheadline)
                    .foregroundStyle(DriveStyle.ink)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 1).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                metadata.driveFont(12, relativeTo: .caption).foregroundStyle(DriveStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .multilineTextAlignment(.leading)
        .padding(.leading, 16).padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 53, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct DriveRemoteFolderCover: View {
    let url: URL?

    var body: some View {
        let edge: CGFloat = 32
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
                    .frame(width: edge, height: edge)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Glyph(symbol: .folder, size: 28, tint: DriveStyle.folder)
                    .frame(width: edge, height: edge)
            }
        }
        .frame(width: edge, height: edge)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct DriveRemoteFolderRow: View {
    let folder: DriveCollection
    let open: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                DriveRemoteListLabel(title: folder.title) {
                    DriveRemoteFolderCover(url: folder.coverURL)
                } metadata: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { details }
                        VStack(alignment: .leading, spacing: 3) { details }
                    }
                }
                Glyph(symbol: .back, size: 11, tint: DriveStyle.secondary)
                    .rotationEffect(.degrees(180))
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var details: some View {
        LocalizedText("Folder")
        if let date = folder.addedAt {
            Text(verbatim: date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)))
        }
    }
}

@MainActor
private enum DriveRemoteDurationCache {
    static let values: NSCache<NSURL, NSNumber> = {
        let cache = NSCache<NSURL, NSNumber>()
        cache.countLimit = 128
        return cache
    }()
}

@MainActor
private struct DriveRemoteVideoRow: View {
    let clip: LessonClip
    var viewingHistory = false
    let play: () -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @State private var measuredDuration: Double?
    @State private var measuringDuration = false

    private var title: String { library.favorites.first { $0.id == clip.id }?.title ?? clip.title }
    private var source: URL { library.playbackURL(for: clip) }
    private var position: FileViewingPosition? { library.remotePlayback.first { $0.id == clip.id }?.viewing }
    private var suppliedDuration: Double? {
        [library.savedVideo(clip.id)?.duration, clip.duration, position?.duration]
            .compactMap { $0 }.first { $0.isFinite && $0 > 0 }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: play) {
                DriveRemoteListLabel(title: title) {
                    thumbnail
                } metadata: {
                    metadata
                }
            }
            .buttonStyle(PressStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            DriveRemoteMoreButton(clip: clip)
        }
        .task(id: source) { await readDuration() }
    }

    private var thumbnail: some View {
        DriveRemotePreview(coverURL: clip.coverURL, size: 32)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { metadataItems }
                VStack(alignment: .leading, spacing: 3) { metadataItems }
            }
            if viewingHistory, let position, position.duration > 0 {
                DriveMeter(value: position.seconds / position.duration, tint: DriveStyle.accent)
            }
        }
    }

    @ViewBuilder private var metadataItems: some View {
        if viewingHistory, let position {
            Text(verbatim: DriveRemoteVideoRows.time(position.seconds) + " / " + DriveRemoteVideoRows.time(position.duration))
                .monospacedDigit().environment(\.layoutDirection, .leftToRight)
        } else if let duration = suppliedDuration ?? measuredDuration {
            LocalizedText("Duration · %@", DriveRemoteVideoRows.time(duration)).monospacedDigit()
        } else {
            LocalizedText(measuringDuration ? "Loading…" : "Duration unavailable")
        }
        if let bytes = library.savedVideo(clip.id)?.byteCount ?? clip.byteCount, bytes > 0 {
            Text(verbatim: bytes.formatted(.byteCount(style: .file).locale(locale)))
                .monospacedDigit()
        }
        if let record = library.savedVideo(clip.id) {
            LocalizedText(record.state.title)
                .foregroundStyle(record.state == .failed ? GlamoStyle.danger : GlamoStyle.secondary)
        }
    }

    private func readDuration() async {
        measuredDuration = nil
        measuringDuration = false
        guard suppliedDuration == nil else { return }
        let url = source
        if let cached = DriveRemoteDurationCache.values.object(forKey: url as NSURL) {
            measuredDuration = cached.doubleValue
            return
        }
        measuringDuration = true
        defer { if !Task.isCancelled { measuringDuration = false } }
        let asset = AVURLAsset(url: url)
        let seconds = try? await withTaskCancellationHandler {
            try await asset.load(.duration).seconds
        } onCancel: { asset.cancelLoading() }
        guard !Task.isCancelled, source == url, let seconds, seconds.isFinite, seconds > 0 else { return }
        measuredDuration = seconds
        DriveRemoteDurationCache.values.setObject(NSNumber(value: seconds), forKey: url as NSURL)
    }
}

struct DriveRemoteVideoRows: View {
    let clips: [LessonClip]
    var viewingHistory = false
    var playbackQueue: [LessonClip]? = nil
    var collection: DriveCollection? = nil
    var nextPage = 1
    var hasMore = false
    var searchContinuation: SearchPlaybackContinuation? = nil
    var fileListStyle = false
    var hasCard = true
    var rowInset: CGFloat = 16
    var rowDate: String? = nil
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var ads: RewardedAds
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing: RemotePlaybackRequest?
    @State private var playedFolderVideo = false

    var body: some View {
        Group {
            if hasCard { rowStack.driveGlassCard() }
            else { rowStack }
        }
        .foregroundStyle(DriveStyle.ink)
        .fullScreenCover(item: $playing, onDismiss: returnFromPlayer) { request in
            LinkedVideoView(search: searchContinuation?.query ?? "", initialClips: request.clips, selectedClipID: request.selectedID,
                            initialCollection: collection, collectionNextPage: nextPage, collectionHasMore: hasMore,
                            initialSearchPage: searchContinuation, onPlaybackStarted: {
                                if collection != nil { playedFolderVideo = true }
                            })
                .task {
                    if collection != nil, scenePhase == .active { ads.preloadInterstitial(commerce: commerce) }
                }
        }
    }

    private var rowStack: some View {
        LazyVStack(spacing: 0) { rows }
    }

    private func returnFromPlayer() {
        defer { playedFolderVideo = false }
        guard collection != nil, playedFolderVideo, scenePhase == .active else { return }
        ads.presentInterstitialIfReady(commerce: commerce)
    }

    private var rows: some View {
        Group {
            ForEach(clips) { clip in
                if clip.id != clips.first?.id {
                    DriveRowSeparator(leading: viewingHistory ? 88 : 56)
                }
                if fileListStyle {
                    DriveRemoteVideoRow(clip: clip, viewingHistory: viewingHistory, play: {
                        var queue = playbackQueue ?? clips
                        if !queue.contains(where: { $0.id == clip.id }) { queue.insert(clip, at: 0) }
                        playing = .init(clips: queue, selectedID: clip.id)
                    })
                } else { savedRow(clip) }
            }
        }
    }

    private func savedRow(_ clip: LessonClip) -> some View {
        let record = library.savedVideo(clip.id)
        let position = viewingHistory ? library.remotePlayback.first(where: { $0.id == clip.id })?.viewing : nil
        let size = (record?.byteCount ?? clip.byteCount).flatMap { bytes in
            bytes > 0 ? bytes.formatted(.byteCount(style: .file).locale(locale)) : nil
        }
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                                  : AnyLayout(HStackLayout(spacing: 8))
        let inlineSize = viewingHistory || typeSize.isAccessibilitySize
        return HStack(spacing: 2) {
            Button {
                var queue = playbackQueue ?? clips
                if !queue.contains(where: { $0.id == clip.id }) { queue.insert(clip, at: 0) }
                playing = .init(clips: queue, selectedID: clip.id)
            } label: {
                HStack(spacing: 6) {
                    layout {
                        DriveRemotePreview(coverURL: clip.coverURL, size: viewingHistory ? 64 : 32,
                                           progress: position.map { $0.seconds / max(1, $0.duration) })
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: library.favorites.first(where: { $0.id == clip.id })?.title ?? clip.title)
                                .driveFont(15, relativeTo: .subheadline)
                                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1).truncationMode(.middle)
                            savedMetadata(record, clip: clip, position: position, size: inlineSize ? size : nil)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !inlineSize, let size {
                        Text(verbatim: size).driveFont(14, relativeTo: .footnote)
                            .foregroundStyle(DriveStyle.secondary).lineLimit(1).fixedSize()
                    }
                }
                .multilineTextAlignment(.leading)
                .padding(.leading, rowInset).padding(.vertical, viewingHistory ? 8 : 5)
                .frame(minHeight: viewingHistory ? 80 : 53)
                .contentShape(Rectangle())
            }.buttonStyle(PressStyle())
            DriveRemoteMoreButton(clip: clip)
        }
    }

    private func savedMetadata(_ record: SavedVideo?, clip: LessonClip,
                               position: FileViewingPosition?, size: String?) -> some View {
        let duration = position.map { Self.time($0.seconds) + " / " + Self.time($0.duration) }
            ?? (record?.duration ?? clip.duration).map(Self.time)
        let detail = [rowDate, duration, size].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 2) {
            if !detail.isEmpty { Text(verbatim: detail).monospacedDigit().lineLimit(2) }
            if let record, !viewingHistory, record.state != .ready || detail.isEmpty {
                LocalizedText(record.state.title)
                    .foregroundStyle(record.state == .failed ? GlamoStyle.danger : DriveStyle.secondary)
            } else if detail.isEmpty {
                LocalizedText("Video")
            }
        }
        .driveFont(12, relativeTo: .caption).foregroundStyle(DriveStyle.secondary)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return "0:00" }
        let value = Int(seconds)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct DriveRemotePreview: View {
    let coverURL: URL?
    let size: CGFloat
    var progress: Double? = nil

    var body: some View {
        AsyncImage(url: coverURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Glyph(symbol: .feed, size: size > 32 ? 23 : 16, tint: DriveStyle.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GlamoStyle.paper)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottom) {
            if let progress { DriveMeter(value: progress, tint: DriveStyle.accent) }
        }
        .clipShape(RoundedRectangle(cornerRadius: size > 32 ? 12 : 8))
        .accessibilityHidden(true).allowsHitTesting(false)
    }
}

private struct DriveRemoteMoreButton: View {
    let clip: LessonClip
    @EnvironmentObject private var library: LibraryStore
    @State private var showingMenu = false
    private var title: String { library.favorites.first { $0.id == clip.id }?.title ?? clip.title }
    var body: some View {
        IconButton(symbol: .driveMore, label: "Video options", tint: DriveStyle.secondary, glyphSize: 16) {
            showingMenu = true
        }
        .frame(width: 44, height: 44).fixedSize()
        .accessibilityValue(Text(verbatim: title))
        .driveDialog(isPresented: $showingMenu) { DriveRemoteVideoActions(clip: clip) }
    }
}

struct DriveRemoteVideoActions: View {
    let clip: LessonClip
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
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
    @State private var resumeSavingAfterPrompt = false
    @State private var error: String?
    private var saved: Bool { library.isSaved(clip) }
    private var title: String { library.favorites.first { $0.id == clip.id }?.title ?? clip.title }

    var body: some View {
        VStack(spacing: 8) {
            fileSummary(compact: false)
            menuDivider
            menuActions
        }
        .padding(16)
        .foregroundStyle(DriveStyle.ink)
        .preferredColorScheme(.light)
        .accessibilityAction(.escape) { dismiss() }
        .driveDialog(isPresented: $renaming) {
            DriveNameSheet(title: "Rename", startingName: title) { try library.renameSavedVideo(clip.id, to: $0) }
        }
        .driveDialog(isPresented: $moving, maxWidth: 420, height: 540) { SavedVideoMoveSheet(clip: clip) }
        .fullScreenCover(isPresented: $exporting) { RemoteVideoExportView(clip: clip) }
        .fullScreenCover(isPresented: $deleting) {
            AccountDecisionDialog(title: "Remove saved video", message: "The offline copy will be removed. Your playback history and original video stay available.",
                                  confirmTitle: "Remove saved video", destructive: true, cancel: { deleting = false }) {
                do { try library.removeSavedVideo(clip.id); deleting = false; dismiss() }
                catch { self.error = error.localizedDescription; deleting = false }
            }
        }
        .fullScreenCover(isPresented: $collectionPrompt, onDismiss: {
            guard resumeSavingAfterPrompt else { return }
            resumeSavingAfterPrompt = false
            if !saved, quota.mayCollect(premium: commerce.premium) { save(moveAfter: moveAfterSaving) }
        }) {
            WatchLimitPrompt(showingMembership: $collectionMembership, kind: .collect, finish: finishSaving)
                .fullScreenCover(isPresented: $collectionMembership, onDismiss: {
                    if commerce.premium { finishSaving() }
                }) { MembershipView() }
        }
    }

    private func fileSummary(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !compact, !typeSize.isAccessibilitySize {
                AsyncImage(url: clip.coverURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else {
                        Glyph(symbol: .feed, size: 24, tint: GlamoStyle.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(GlamoStyle.paper)
                    }
                }
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title).font(.glam(.subheadline, weight: .semibold))
                    .lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(Text(verbatim: title))
                LocalizedText(saved ? "Video saved" : "Not saved")
                    .font(.glam(.caption, weight: .medium))
                    .foregroundStyle(saved ? GlamoStyle.accent : GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            IconButton(symbol: .close, label: "Close", glyphSize: 13) { dismiss() }
                .frame(width: 44, height: 44).fixedSize()
                .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, 8).padding(.top, 6).padding(.bottom, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var menuActions: some View {
        VStack(spacing: 2) {
            DriveRemoteMenuOption(title: saved ? "Video saved" : "Save video",
                                  hint: saved ? nil : "Saves a copy for offline playback.",
                                  image: saved ? "PlayerSaved" : "PlayerSave", selected: saved,
                                  action: saved ? nil : { save(moveAfter: false) })
            DriveRemoteDownloadOption(clipID: clip.id, record: library.savedVideo(clip.id),
                                      saved: saved, cache: library.offline) { save(moveAfter: false) }
            if let record = library.savedVideo(clip.id), record.state == .failed {
                ErrorNote(message: record.failure ?? "Download failed").padding(.horizontal, 8)
            }
            DriveRemoteMenuOption(title: "Export video", hint: "MP4 and M4A export", glyph: .driveShare,
                                  tint: Color(red: 0.16, green: 0.72, blue: 0.90)) { exporting = true }
            DriveRemoteMenuOption(title: "Rename", hint: saved ? nil : "Save this video first.", glyph: .edit) {
                renaming = true
            }.disabled(!saved)
            DriveRemoteMenuOption(title: "Move to folder", hint: saved ? nil : "Saves the video before moving it.",
                                  glyph: .driveFolder, tint: Color(red: 0.22, green: 0.68, blue: 0.37)) {
                if saved { moving = true } else { save(moveAfter: true) }
            }
            menuDivider.padding(.vertical, 5)
            DriveRemoteMenuOption(title: "Delete", detail: saved ? "Removes the saved copy only." : nil,
                                  hint: saved ? nil : "No saved copy to remove.",
                                  glyph: .close, tint: GlamoStyle.danger, role: .destructive) { deleting = true }
                .disabled(!saved)
            if let error { ErrorNote(message: error).padding(.horizontal, 10) }
        }
    }

    private var menuDivider: some View {
        Divider().overlay(GlamoStyle.line).padding(.horizontal, 10)
            .accessibilityHidden(true)
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
        resumeSavingAfterPrompt = !saved && quota.mayCollect(premium: commerce.premium)
        collectionPrompt = false
    }
}

private struct DriveRemoteMenuOption: View {
    let title: String
    var detail: String? = nil
    var hint: String? = nil
    var glyph: GlamoGlyph = .feed
    var image: String? = nil
    var tint: Color = GlamoStyle.accent
    var selected = false
    var progress: Double? = nil
    var role: ButtonRole? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(role: role, action: action) { label }.buttonStyle(PressStyle())
            } else {
                label.accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityHint(LocalizedStringKey(hint ?? ""))
    }

    private var label: some View {
        HStack(spacing: 8) {
            Group {
                if let image { Image(image).resizable().scaledToFit() }
                else {
                    Glyph(symbol: glyph, size: 17, tint: .white)
                        .frame(width: 32, height: 32)
                        .background(tint, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .frame(width: 32, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(title).driveFont(16, relativeTo: .subheadline, weight: .medium)
                    .foregroundStyle(role == .destructive || selected ? tint : DriveStyle.ink)
                if let detail {
                    LocalizedText(detail).font(.glam(.caption))
                        .foregroundStyle(GlamoStyle.secondary)
                }
                if let progress {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { downloadProgress(progress) }
                        VStack(alignment: .leading, spacing: 5) { downloadProgress(progress) }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(selected ? GlamoStyle.accent.opacity(0.09) : role == .destructive ? GlamoStyle.danger.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func downloadProgress(_ value: Double) -> some View {
        DriveMeter(value: value, tint: tint, thickness: 3).frame(minWidth: 40)
        Text(value, format: .percent.precision(.fractionLength(0)))
            .font(.glam(.caption, weight: .medium)).monospacedDigit().foregroundStyle(GlamoStyle.secondary)
            .fixedSize()
    }
}

private struct DriveRemoteDownloadOption: View {
    let clipID: String
    let record: SavedVideo?
    let saved: Bool
    @ObservedObject var cache: OfflineVideoCache
    let save: () -> Void

    private var title: String {
        switch record?.state {
        case .downloading: "Downloading…"
        case .paused: "Resume download"
        case .ready: "Available offline"
        case .failed: "Retry download"
        default: "Download video"
        }
    }

    private var detail: String? {
        guard saved else { return nil }
        if record?.state == .ready, let size = record?.byteCount, size > 0 {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        if record?.state == .queued { return record?.state.title }
        return nil
    }

    private var progress: Double? {
        guard record?.state == .downloading || record?.state == .paused,
              let value = cache.progress[clipID], value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    var body: some View {
        DriveRemoteMenuOption(title: title, detail: detail,
                              hint: record?.state == .failed ? record?.failure : saved ? nil : "Saves the video before downloading.",
                              glyph: .driveActivity,
                              tint: Color(red: 0.98, green: 0.58, blue: 0.15), progress: progress,
                              action: record?.state == .ready || record?.state == .downloading ? nil : {
            if saved { cache.enqueue(clipID) } else { save() }
        })
    }
}

struct DriveCollectionRows: View {
    let collections: [DriveCollection]
    var fileListStyle = false
    var openFolder: ((DriveCollection) -> Void)? = nil
    var hasCard = true
    @State private var opened: DriveCollection?
    @State private var playing: RemotePlaybackRequest?
    var body: some View {
        Group {
            if hasCard { rows.driveGlassCard() }
            else { rows }
        }
        .foregroundStyle(DriveStyle.ink)
        .fullScreenCover(item: $opened) { DriveCollectionBrowser(initial: $0) }
        .fullScreenCover(item: $playing) {
            LinkedVideoView(search: "", initialClips: $0.clips, selectedClipID: $0.selectedID)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(collections) { collection in
                if collection.id != collections.first?.id {
                    DriveRowSeparator()
                }
                if fileListStyle, collection.isFolder {
                    DriveRemoteFolderRow(folder: collection) { open(collection) }
                } else if fileListStyle, let clip = collection.clip {
                    DriveRemoteVideoRow(clip: clip, play: { open(collection) })
                } else {
                    Button { open(collection) } label: {
                        HStack(spacing: 12) {
                            if collection.isFolder {
                                DriveRemoteFolderCover(url: collection.coverURL)
                            } else {
                                Glyph(symbol: .play, size: 26, tint: DriveStyle.accent)
                            }
                            Text(verbatim: collection.title).font(.glam(.subheadline, weight: .medium))
                                .lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                            Glyph(symbol: .back, size: 12, tint: DriveStyle.secondary).rotationEffect(.degrees(180))
                        }.multilineTextAlignment(.leading).padding(14).frame(minHeight: 60).contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                }
            }
        }
    }

    private func open(_ collection: DriveCollection) {
        if let clip = collection.clip { playing = .init(clips: [clip], selectedID: clip.id) }
        else if let openFolder { openFolder(collection) }
        else { opened = collection }
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
        let index = path.firstIndex(where: { $0.id == resource.id })
        let trail = [initial.title] + (index.map { Array(path.prefix($0 + 1)).map(\.title) } ?? [])
        return DriveCollectionContents(collection: resource, trail: trail, openFolder: { path.append($0) }, back: {
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
        GeometryReader { container in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    IconButton(symbol: .back, label: "Back", glass: true, action: back)
                    LocalizedText("Files").driveFont(22, relativeTo: .title2, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DriveStyle.pageInset).padding(.vertical, 8)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if api.session == nil { ConnectionPanel() }
                        else if let resource {
                            if let clip = resource.clip {
                                DriveRemoteVideoRows(clips: [clip], fileListStyle: true)
                            } else {
                                DriveCollectionRows(collections: [resource], fileListStyle: true)
                            }
                        } else if let error {
                            ErrorNote(message: error)
                            ActionButton(title: "Try again") { retry = UUID() }
                        } else {
                            AccountLoadingIndicator(title: "Opening link…")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, DriveStyle.pageInset).padding(.vertical, 12)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }
        .driveScreenBackground()
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
    let trail: [String]
    let openFolder: (DriveCollection) -> Void
    let back: () -> Void
    @EnvironmentObject private var api: APIClient
    @StateObject private var store = DriveCollectionStore()
    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        IconButton(symbol: .back, label: "Back", glass: true, glyphSize: 13, action: back)
                        Text(verbatim: collection.title).driveFont(20, relativeTo: .headline, weight: .medium)
                            .multilineTextAlignment(.center).lineLimit(2).truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: .infinity)
                        Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                    }
                    if trail.count > 1 {
                        Text(verbatim: trail.joined(separator: " / "))
                            .driveFont(12, relativeTo: .caption).foregroundStyle(DriveStyle.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, DriveStyle.pageInset).padding(.vertical, 8)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        let folders = store.items.filter(\.isFolder)
                        let clips = store.items.compactMap(\.clip)
                        if !folders.isEmpty || !clips.isEmpty {
                            VStack(spacing: 0) {
                                if !folders.isEmpty {
                                    DriveCollectionRows(collections: folders, fileListStyle: true,
                                                        openFolder: openFolder, hasCard: false)
                                }
                                if !clips.isEmpty {
                                    if !folders.isEmpty { DriveRowSeparator() }
                                    DriveRemoteVideoRows(clips: clips, collection: collection, nextPage: store.page,
                                                         hasMore: store.hasMore, fileListStyle: true, hasCard: false)
                                }
                            }
                            .driveGlassCard()
                        }
                        if store.loading { AccountLoadingIndicator(title: "Loading videos…").frame(maxWidth: .infinity) }
                        if let error = store.error {
                            if store.items.isEmpty {
                                DriveWorkspaceEmpty(artwork: "DriveConnectionArtwork",
                                                    artworkWidth: min(container.size.width * 0.56, container.size.height * 0.35, 240),
                                                    title: "Couldn’t load files", message: error) {
                                    Button { load() } label: { LocalizedText("Try again") }
                                        .buttonStyle(DrivePrimaryButtonStyle(fillsWidth: false, radius: 8))
                                }
                                .padding(.vertical, 32)
                            } else {
                                ErrorNote(message: error)
                                ActionButton(title: "Try again", primary: false) { load() }
                            }
                        } else if store.items.isEmpty && !store.loading {
                            DriveWorkspaceEmpty(artwork: "DriveShelf", artworkWidth: min(container.size.width * 0.56, 240),
                                                title: "No videos here yet", message: "This folder has no videos yet.") {
                                Button { load(refresh: true) } label: { LocalizedText("Try again") }
                                    .buttonStyle(DriveEmptyActionStyle())
                            }
                        } else if store.hasMore && !store.loading {
                            ActionButton(title: "Load more videos", primary: false) { load() }
                                .onAppear { load() }
                        }
                    }
                    .padding(.horizontal, DriveStyle.pageInset).padding(.vertical, 12)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
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
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingDeviceSpace = false

    var body: some View {
        let byDay = Dictionary(grouping: records) { calendar.startOfDay(for: $0.addedAt) }
        return LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                if let records = byDay[day] {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)))
                            .driveFont(20, relativeTo: .subheadline).foregroundStyle(DriveStyle.secondary)
                            .padding(.horizontal, 12)
                            .accessibilityAddTraits(.isHeader)
                        DriveGroupedRows(items: records.sorted { $0.addedAt > $1.addedAt }) { record in
                            transferRow(record)
                        }
                    }
                }
            }
        }
        .onChange(of: records) { previous, current in
            let priorFailures = Set(previous.filter { $0.failure == DeviceSpaceFailure.downloadMessage }.map(\.id))
            if current.contains(where: { $0.failure == DeviceSpaceFailure.downloadMessage && !priorFailures.contains($0.id) }) {
                showingDeviceSpace = true
            }
        }
        .driveDialog(isPresented: $showingDeviceSpace) { DriveDeviceSpaceNotice(message: DeviceSpaceFailure.downloadMessage) }
    }

    private func transferRow(_ record: SavedVideo) -> some View {
        let clip = library.favorites.first { $0.id == record.id }
        let size = (record.byteCount ?? clip?.byteCount).flatMap { bytes in
            bytes > 0 ? bytes.formatted(.byteCount(style: .file).locale(locale)) : nil
        }
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                                  : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                layout {
                    DriveRemotePreview(coverURL: clip?.coverURL, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        if let clip {
                            Text(verbatim: clip.title).driveFont(15, relativeTo: .subheadline)
                                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1).truncationMode(.middle)
                        } else {
                            LocalizedText("Video").driveFont(15, relativeTo: .subheadline)
                        }
                        transferStatus(record, progress: cache.progress[record.id])
                        if typeSize.isAccessibilitySize, let size {
                            Text(verbatim: size).driveFont(12, relativeTo: .caption)
                                .foregroundStyle(DriveStyle.secondary).monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !typeSize.isAccessibilitySize, let size {
                    Text(verbatim: size).driveFont(14, relativeTo: .footnote)
                        .foregroundStyle(DriveStyle.secondary).lineLimit(1).fixedSize()
                }
                transferAction(record)
            }
            if let failure = record.failure { ErrorNote(message: failure) }
        }
        .padding(.leading, 6).padding(.vertical, 5)
        .frame(minHeight: 53)
    }

    private func transferStatus(_ record: SavedVideo, progress: Double?) -> some View {
        Group {
            if record.state == .downloading, let progress {
                let percentage = progress.formatted(.percent.precision(.fractionLength(0)).locale(locale))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        DriveMeter(value: progress, tint: DriveStyle.accent).frame(minWidth: 28)
                        Text(verbatim: percentage).monospacedDigit().fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: percentage).monospacedDigit()
                        DriveMeter(value: progress, tint: DriveStyle.accent)
                    }
                }
                .accessibilityLabel(Text(LocalizedStringKey(record.state.title)))
                .accessibilityValue(Text(verbatim: percentage))
            } else {
                LocalizedText(record.failure == DeviceSpaceFailure.downloadMessage ? "Not enough device space" : record.state.title)
                    .foregroundStyle(record.state == .failed ? GlamoStyle.danger : DriveStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .driveFont(12, relativeTo: .caption)
        .foregroundStyle(DriveStyle.secondary)
    }

    @ViewBuilder private func transferAction(_ record: SavedVideo) -> some View {
        if record.state == .downloading {
            IconButton(symbol: .pause, label: "Pause download", tint: DriveStyle.secondary, glyphSize: 14) {
                cache.pause(record.id)
            }
        } else if record.state != .ready {
            IconButton(symbol: .play, label: record.state == .failed ? "Retry download" : "Resume download",
                       tint: DriveStyle.secondary, glyphSize: 14) { cache.enqueue(record.id) }
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
            .driveDialog(item: $options) { DriveItemSheet(item: .file($0), pausePlayback: pauseLocalPlayback) }
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
    @Environment(\.locale) private var locale
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @StateObject private var editor = VideoEditor()
    @State private var job: Task<Void, Never>?
    @State private var result: PracticeRecording?
    @State private var share: SharedFile?
    @State private var sharePresentationID: UUID?
    @State private var preparingShare = false
    @State private var shareError: String?
    @State private var shareOutcome: ShareSheet.Outcome?
    @State private var exportingFormat: String?
    @State private var previousExportFormat: String?
    @State private var exportWasCancelled = false
    @State private var showingDeviceSpace = false
    @State private var paywall = false
    @State private var cancelPrompt = false
    @State private var message: String?
    @State private var failure: String?
    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                SheetHeading(title: "Export video") { if exportingFormat != nil { cancelPrompt = true } else { dismiss() } }
                    .disabled(job != nil && exportingFormat == nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(verbatim: clip.title).font(.glam(.headline)).fixedSize(horizontal: false, vertical: true)
                        if editor.isLoading { AccountLoadingIndicator(title: "Preparing video…") }
                        if editor.duration > 0 {
                            VideoSurface(player: editor.preview.player, fill: false).aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        if let format = exportingFormat {
                            exportProgress(format: format)
                        } else if preparingShare {
                            AccountLoadingIndicator(title: "Preparing to share…")
                        } else if job != nil {
                            AccountLoadingIndicator(title: "Preparing file…")
                        }
                        if let file = result {
                            Text(verbatim: file.displayName).font(.glam(.subheadline, weight: .semibold))
                            let size = file.byteCount?.formatted(.byteCount(style: .file).locale(locale))
                            Text(verbatim: [file.fileExtension.uppercased(), size].compactMap { $0 }.joined(separator: " · "))
                                .font(.glam(.footnote)).foregroundStyle(DriveStyle.secondary)
                            LocalizedText("Your exported file is still in your library.").font(.glam(.footnote))
                            shareFeedback
                            ActionButton(title: shareTitle) { shareFile(file) }.disabled(job != nil || share != nil)
                            if !file.isAudio {
                                ActionButton(title: "Save to Photos", primary: false) { saveToPhotos(file) }.disabled(job != nil)
                            }
                        }
                        if let message { LocalizedText(message).font(.glam(.subheadline)).foregroundStyle(DriveStyle.accent) }
                        if job == nil, result == nil, editor.duration > 0 {
                            if exportWasCancelled {
                                MessagePanel(title: "Export cancelled", message: "Your original video will stay available.")
                            } else if let error = failure ?? editor.error {
                                MessagePanel(title: "Export failed", message: error)
                            }
                            exportButton(audio: false)
                            exportButton(audio: true)
                        } else if let error = failure ?? editor.error {
                            ErrorNote(message: error)
                            if job == nil, result == nil, editor.duration <= 0 {
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
            ShareSheet(items: [item.url]) { [id = item.id, recordingID = item.recordingID] outcome in
                guard sharePresentationID == id else { return }
                shareOutcome = outcome
                if case .completed = outcome, let recordingID { library.recordSharedFile(recordingID) }
            }
        }
        .driveDialog(isPresented: $showingDeviceSpace) { DriveDeviceSpaceNotice() }
        .overlay {
            if cancelPrompt {
                AccountDecisionDialog(title: "Stop export?", message: "Your original video will stay available.",
                                      confirmTitle: "Stop export", destructive: true, cancel: { cancelPrompt = false }) {
                    job?.cancel(); editor.cancelExport(); cancelPrompt = false
                }
            }
        }
    }

    private func exportButton(audio: Bool) -> some View {
        Button { export(audio: audio) } label: {
            let format = audio ? "M4A" : "MP4"
            if previousExportFormat == format, exportWasCancelled || failure != nil || editor.error != nil {
                LocalizedText("Export %@ again", format)
            } else {
                LocalizedText(audio ? "Export M4A" : "Export MP4")
            }
        }
        .buttonStyle(GlamoActionStyle(primary: !audio))
    }

    private func exportProgress(format: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    LocalizedText("Exporting…").font(.glam(.headline))
                    Spacer(minLength: 8)
                    Text(verbatim: format).font(.glam(.subheadline, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 4) {
                    LocalizedText("Exporting…").font(.glam(.headline))
                    Text(verbatim: format).font(.glam(.subheadline, weight: .semibold))
                }
            }
            if editor.isExporting {
                let amount = Double(editor.progress)
                Text(verbatim: amount.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                    .font(.glam(.subheadline, weight: .semibold)).monospacedDigit()
                DriveMeter(value: amount, tint: DriveStyle.accent)
            } else {
                AccountLoadingIndicator(title: "Preparing file…")
            }
            ActionButton(title: "Cancel export", primary: false) { cancelPrompt = true }
        }
        .padding(14)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: .white)
    }

    private var shareTitle: String {
        if shareError != nil { return "Retry sharing" }
        switch shareOutcome {
        case .some(.failed(_)): return "Retry sharing"
        case .some(.completed), .some(.cancelled): return "Share again"
        case nil: return "Share file"
        }
    }

    @ViewBuilder private var shareFeedback: some View {
        if let shareError { MessagePanel(title: "Share preparation failed", message: shareError) }
        else if let shareOutcome {
            switch shareOutcome {
            case .completed: LocalizedText("Share complete").foregroundStyle(DriveStyle.accent)
            case .cancelled: LocalizedText("Share cancelled").foregroundStyle(DriveStyle.secondary)
            case .failed(let reason): MessagePanel(title: "Share failed", message: reason)
            }
        }
    }

    private func export(audio: Bool) {
        guard job == nil else { return }
        guard commerce.canExportMedia else { paywall = true; return }
        failure = nil; message = nil
        exportWasCancelled = false
        exportingFormat = audio ? "M4A" : "MP4"
        previousExportFormat = exportingFormat
        let owner = commerce.api.session?.userId.value
        job = Task {
            defer {
                exportWasCancelled = Task.isCancelled && result == nil
                cancelPrompt = false
                job = nil
                exportingFormat = nil
            }
            guard let output = await editor.export(audioOnly: audio) else {
                showingDeviceSpace = editor.error == DeviceSpaceFailure.message
                return
            }
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try Task.checkCancellation()
                try commerce.requireMediaExport()
                guard commerce.api.session?.userId.value == owner else { throw GlamoError.unauthorized }
                result = try await library.importMovie(output, exported: true, title: clip.title,
                                                        folderID: library.savedVideo(clip.id)?.folderID)
            } catch is CancellationError { }
            catch { reportFailure(error) }
        }
    }
    private func shareFile(_ file: PracticeRecording) {
        guard job == nil, share == nil else { return }
        shareError = nil
        shareOutcome = nil
        sharePresentationID = nil
        preparingShare = true
        job = Task {
            defer { job = nil; preparingShare = false }
            do {
                let prepared = SharedFile(url: try await library.shareFile(for: file, commerce: commerce), recordingID: file.id)
                try Task.checkCancellation()
                sharePresentationID = prepared.id
                share = prepared
            } catch is CancellationError { }
            catch {
                let reason = DeviceSpaceFailure.description(for: error)
                shareError = reason
                showingDeviceSpace = reason == DeviceSpaceFailure.message
            }
        }
    }
    private func saveToPhotos(_ file: PracticeRecording) {
        guard job == nil else { return }
        message = nil
        failure = nil
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
            } catch is CancellationError { }
            catch { reportFailure(error) }
        }
    }

    private func reportFailure(_ error: Error) {
        let reason = DeviceSpaceFailure.description(for: error)
        failure = reason
        showingDeviceSpace = reason == DeviceSpaceFailure.message
    }
}
