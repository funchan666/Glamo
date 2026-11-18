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
            preview.frame(width: 64, height: 52).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title).driveFont(15, relativeTo: .subheadline, weight: .medium)
                    .foregroundStyle(DriveStyle.ink)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                metadata.font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .multilineTextAlignment(.leading)
        .padding(.leading, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct DriveRemoteFolderCover: View {
    let url: URL?
    var compact = false

    var body: some View {
        let width: CGFloat = compact ? 26 : 64
        let height: CGFloat = compact ? 26 : 52
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 10))
            } else {
                Glyph(symbol: compact ? .driveFolder : .folder, size: compact ? 26 : 30,
                      tint: compact ? DriveStyle.accent : DriveStyle.folder)
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
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
                    .frame(width: 44, height: 44).padding(.trailing, 8)
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

            DriveRemoteMoreButton(clip: clip).padding(.trailing, 8)
        }
        .task(id: source) { await readDuration() }
    }

    private var thumbnail: some View {
        AsyncImage(url: clip.coverURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Glyph(symbol: .feed, size: 25, tint: GlamoStyle.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GlamoStyle.paper)
            }
        }
        .frame(width: 64, height: 52)
        .overlay(alignment: .bottomLeading) {
            Glyph(symbol: .play, size: 13, tint: .white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.50), in: Circle()).padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var playing: RemotePlaybackRequest?

    var body: some View {
        Group {
            if fileListStyle { LazyVStack(spacing: 0) { rows } }
            else { VStack(spacing: 0) { rows } }
        }
        .foregroundStyle(DriveStyle.ink)
        .glamoGlass(in: RoundedRectangle(cornerRadius: DriveStyle.cardRadius), tint: .white)
        .fullScreenCover(item: $playing) { request in
            LinkedVideoView(search: searchContinuation?.query ?? "", initialClips: request.clips, selectedClipID: request.selectedID,
                            initialCollection: collection, collectionNextPage: nextPage, collectionHasMore: hasMore,
                            initialSearchPage: searchContinuation)
        }
    }

    private var rows: some View {
        Group {
            ForEach(clips) { clip in
                if clip.id != clips.first?.id {
                    Divider().overlay(DriveStyle.separator)
                        .padding(.leading, fileListStyle ? 88 : 76).padding(.trailing, fileListStyle ? 12 : 0)
                }
                if fileListStyle {
                    DriveRemoteVideoRow(clip: clip, viewingHistory: viewingHistory, play: {
                        var queue = playbackQueue ?? clips
                        if !queue.contains(where: { $0.id == clip.id }) { queue.insert(clip, at: 0) }
                        playing = .init(clips: queue, selectedID: clip.id)
                    })
                } else {
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
                                    } else {
                                        LocalizedText("Video").font(.glam(.caption)).foregroundStyle(DriveStyle.secondary)
                                        if let duration = clip.duration {
                                            Text(verbatim: Self.time(duration)).font(.glam(.caption)).monospacedDigit()
                                                .foregroundStyle(DriveStyle.secondary)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.multilineTextAlignment(.leading).padding(.vertical, 12).padding(.leading, 12)
                                .contentShape(Rectangle())
                        }.buttonStyle(PressStyle())
                        DriveRemoteMoreButton(clip: clip)
                    }
                }
            }
        }
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

private struct DriveRemoteMoreButton: View {
    let clip: LessonClip
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showingMenu = false
    @State private var showingSheet = false

    private var title: String { library.favorites.first { $0.id == clip.id }?.title ?? clip.title }

    var body: some View {
        IconButton(symbol: .driveMore, label: "Video options", tint: DriveStyle.ink, glass: true, glyphSize: 16) {
            if typeSize >= .xxLarge || verticalSizeClass == .compact { showingSheet = true }
            else { showingMenu = true }
        }
        .frame(width: 44, height: 44).fixedSize()
        .accessibilityValue(Text(verbatim: title))
        .popover(isPresented: $showingMenu, attachmentAnchor: .rect(.bounds), arrowEdge: nil) {
            DriveRemoteVideoActions(clip: clip, compactMenu: true)
                .presentationBackground(.regularMaterial)
                .presentationCompactAdaptation(.popover)
        }
        .sheet(isPresented: $showingSheet) { DriveRemoteVideoActions(clip: clip) }
    }
}

struct DriveRemoteVideoActions: View {
    let clip: LessonClip
    var compactMenu = false
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
    @State private var error: String?
    private var saved: Bool { library.isSaved(clip) }
    private var title: String { library.favorites.first { $0.id == clip.id }?.title ?? clip.title }

    var body: some View {
        Group {
            if compactMenu { compactPanel }
            else { sheetPanel }
        }
        .foregroundStyle(DriveStyle.ink)
        .preferredColorScheme(.light)
        .presentationBackground(.regularMaterial)
        .presentationDetents(typeSize >= .xxLarge ? [.large] : [.height(360), .large])
        .presentationDragIndicator(.hidden)
        .accessibilityAction(.escape) { dismiss() }
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

    private var compactPanel: some View {
        VStack(spacing: 6) {
            fileSummary(compact: true)
            menuDivider
            ScrollView { menuActions }
                .scrollBounceBehavior(.basedOnSize)
                .frame(idealHeight: 252, maxHeight: 280)
        }
        .padding(10)
        .frame(idealWidth: 316, maxWidth: 360)
        // Existing confirmation and allowance overlays keep room for their actions.
        .frame(minHeight: collectionPrompt ? 520 : deleting ? 360 : nil)
    }

    private var sheetPanel: some View {
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { dismiss() }
                .accessibilityHidden(true)
            GeometryReader { container in
                let margins = drivePaneMargins(in: container, includesHorizontalFold: true)
                VStack(spacing: 8) {
                    fileSummary(compact: container.size.height - margins.top - margins.bottom < 400)
                    menuDivider
                    ViewThatFits(in: .vertical) {
                        menuActions.fixedSize(horizontal: false, vertical: true)
                        ScrollView { menuActions }.scrollBounceBehavior(.basedOnSize)
                    }
                }
                .padding(10)
                .background {
                    Color.clear.contentShape(RoundedRectangle(cornerRadius: 26)).onTapGesture {}
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(margins)
            }
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
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize >= .xxLarge ? 1 : 2)
        return VStack(spacing: 2) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                DriveRemoteMenuOption(title: saved ? "Video saved" : "Save video",
                                      hint: saved ? nil : "Saves a copy for offline playback.",
                                      image: saved ? "PlayerSaved" : "PlayerSave", selected: saved,
                                      action: saved ? nil : { save(moveAfter: false) })
                DriveRemoteDownloadOption(clipID: clip.id, record: library.savedVideo(clip.id),
                                          saved: saved, cache: library.offline) { save(moveAfter: false) }
            }
            if let record = library.savedVideo(clip.id), record.state == .failed {
                ErrorNote(message: record.failure ?? "Download failed").padding(.horizontal, 8)
            }
            DriveRemoteMenuOption(title: "Export video", hint: "MP4 and M4A export", glyph: .driveShare) {
                exporting = true
            }
            menuDivider.padding(.vertical, 5)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                DriveRemoteMenuOption(title: "Rename", hint: saved ? nil : "Save this video first.",
                                      glyph: .edit) { renaming = true }.disabled(!saved)
                DriveRemoteMenuOption(title: "Move to folder", hint: saved ? nil : "Saves the video before moving it.",
                                      glyph: .driveFolder) {
                    if saved { moving = true } else { save(moveAfter: true) }
                }
            }
            menuDivider.padding(.vertical, 5)
            DriveRemoteMenuOption(title: "Delete", detail: saved ? "Removes the saved copy only." : nil,
                                  hint: saved ? nil : "No saved copy to remove.",
                                  glyph: .close, tint: GlamoStyle.danger, role: .destructive) {
                deleting = true
            }.disabled(!saved)
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
        collectionPrompt = false
        if !saved, quota.mayCollect(premium: commerce.premium) { save(moveAfter: moveAfterSaving) }
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
                    Glyph(symbol: glyph, size: 16, tint: tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(title).driveFont(14, relativeTo: .subheadline, weight: .medium)
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
                              tint: Color(red: 0.70, green: 0.34, blue: 0.09), progress: progress,
                              action: record?.state == .ready || record?.state == .downloading ? nil : {
            if saved { cache.enqueue(clipID) } else { save() }
        })
    }
}

struct DriveCollectionRows: View {
    let collections: [DriveCollection]
    var fileListStyle = false
    var openFolder: ((DriveCollection) -> Void)? = nil
    @State private var opened: DriveCollection?
    @State private var playing: RemotePlaybackRequest?
    var body: some View {
        VStack(spacing: 0) {
            ForEach(collections) { collection in
                if collection.id != collections.first?.id {
                    Divider().overlay(DriveStyle.separator)
                        .padding(.leading, fileListStyle ? 88 : 54).padding(.trailing, fileListStyle ? 12 : 0)
                }
                if fileListStyle, collection.isFolder {
                    DriveRemoteFolderRow(folder: collection) { open(collection) }
                } else if fileListStyle, let clip = collection.clip {
                    DriveRemoteVideoRow(clip: clip, play: { open(collection) })
                } else {
                    Button { open(collection) } label: {
                        HStack(spacing: 12) {
                            if collection.isFolder {
                                DriveRemoteFolderCover(url: collection.coverURL, compact: true)
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
        }.foregroundStyle(DriveStyle.ink).glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: .white)
            .fullScreenCover(item: $opened) { DriveCollectionBrowser(initial: $0) }
            .fullScreenCover(item: $playing) {
                LinkedVideoView(search: "", initialClips: $0.clips, selectedClipID: $0.selectedID)
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
    let trail: [String]
    let openFolder: (DriveCollection) -> Void
    let back: () -> Void
    @EnvironmentObject private var api: APIClient
    @StateObject private var store = DriveCollectionStore()
    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    IconButton(symbol: .back, label: "Back", glass: true, action: back)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: collection.title).font(.glam(.headline)).lineLimit(2).truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                        if trail.count > 1 {
                            Text(verbatim: trail.joined(separator: " / "))
                                .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        } else {
                            LocalizedText("Folder").font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, DriveStyle.pageInset).padding(.vertical, 8)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        let folders = store.items.filter(\.isFolder)
                        if !folders.isEmpty {
                            DriveCollectionRows(collections: folders, fileListStyle: true, openFolder: openFolder)
                        }
                        let clips = store.items.compactMap(\.clip)
                        if !clips.isEmpty {
                            DriveRemoteVideoRows(clips: clips, collection: collection, nextPage: store.page,
                                                 hasMore: store.hasMore, fileListStyle: true)
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
