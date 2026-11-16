import SwiftUI
import AVFoundation

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var showingExportMembership = false
    @State private var sharing: SharedFile?
    @State private var removing: PracticeRecording?
    @State private var sharingMovieID: UUID?
    @Environment(\.locale) private var locale
    @Binding var filter: String
    let edit: (PracticeRecording) -> Void
    let preview: (PracticeRecording) -> Void
    let openHome: () -> Void

    private let categories = ["All", "Imports", "Exports"]
    private var isExports: Bool { filter == "Exports" }
    private var movies: [PracticeRecording] {
        filter == "All" ? library.movies : library.movies.filter { $0.isExport == isExports }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LocalizedText("Files").font(.glam(.largeTitle, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                ChipFilter(values: categories, selected: filter) { filter = $0 }
                    .disabled(library.importingVideo || sharingMovieID != nil)
                if !isExports {
                    VideoImportControls(onImport: edit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(sharingMovieID != nil)
                }
                let entries = movies
                if entries.isEmpty {
                    GlamoEmptyState(title: isExports ? "No exports yet" : "No imported videos yet",
                                    message: isExports ? "Export a video or audio file from the editor to find it here."
                                                       : "Your imported videos will appear here.") {
                        if isExports {
                            ActionButton(title: "Back to videos", primary: false, action: openHome)
                        }
                    }
                } else {
                    LocalizedText(entries.count == 1 ? "%@ item" : "%@ items", entries.count.formatted(.number.locale(locale)))
                        .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                    LazyVStack(spacing: 14) {
                        ForEach(entries) { movie in movieRow(movie) }
                    }
                }
            }.glamoPage()
        }.glamoScreenBackground()
            .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
            .sheet(isPresented: $showingExportMembership) { MembershipView(requiredBenefit: .mediaExport) }
            .sheet(item: $removing) { movie in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        SheetHeading(title: "Delete this local copy?", inset: false) { removing = nil }
                        Text(verbatim: movie.title).font(.glam(.headline))
                        LocalizedText("This deletes the file from Glamo. Any original in Photos or Files stays there.").foregroundStyle(GlamoStyle.secondary)
                        ActionButton(title: "Delete local copy") { library.delete(movie); removing = nil }
                        ActionButton(title: "Keep it", primary: false) { removing = nil }
                    }.glamoPage()
                }.glamoScreenBackground().presentationDetents([.medium, .large])
            }
    }

    private func movieRow(_ movie: PracticeRecording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { preview(movie) } label: {
                    HStack(spacing: 8) {
                        LocalMediaLabel(movie: movie)
                        Glyph(symbol: .play, size: 13, tint: GlamoStyle.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(PressStyle())
                removeButton(.close, title: "Delete local file") { removing = movie }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { movieActions(movie) }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) { movieActions(movie) }
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Divider().overlay(GlamoStyle.line).allowsHitTesting(false) }
        .disabled(library.importingVideo || sharingMovieID != nil)
    }

    @ViewBuilder private func movieActions(_ movie: PracticeRecording) -> some View {
        if !movie.isAudio {
            Button("Edit") { edit(movie) }.buttonStyle(LibraryActionStyle())
        }
        Button(LocalizedStringKey(sharingMovieID == movie.id ? "Preparing export…" : "Share file")) {
            shareMovie(movie)
        }.buttonStyle(LibraryActionStyle())
    }

    private func shareMovie(_ movie: PracticeRecording) {
        guard sharingMovieID == nil, !library.importingVideo else { return }
        guard commerce.canExportMedia else {
            showingExportMembership = true
            return
        }
        sharingMovieID = movie.id
        Task {
            defer { sharingMovieID = nil }
            do { sharing = SharedFile(url: try await library.shareFile(for: movie, commerce: commerce)) }
            catch { library.error = error.localizedDescription }
        }
    }
}

struct SavedLessonsSection: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @State private var filter = "Favorites"
    @State private var player: PlayerRoute?
    @State private var removingDownload: OfflineVideo?
    let watchLessons: () -> Void
    let downloadsRequest: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChipFilter(values: ["Favorites", "Downloads"], selected: filter) { filter = $0 }
            if filter == "Downloads" {
                downloads
            } else if library.favorites.isEmpty {
                emptyMessage("No favorites yet", detail: "Tap the bookmark while watching a lesson to save it here.")
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(library.favorites) { lesson in
                        HStack(spacing: 8) {
                            Button { player = PlayerRoute(clips: library.favorites, startID: lesson.id) } label: {
                                HStack(spacing: 12) {
                                    MediaCover(url: lesson.coverURL)
                                        .frame(width: 68, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                        .accessibilityHidden(true)
                                    Text(verbatim: lesson.title).font(.glam(.subheadline, weight: .semibold))
                                        .lineLimit(3)
                                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                }.contentShape(Rectangle())
                            }.buttonStyle(PressStyle())
                            removeButton(.bookmark, title: "Remove saved video") { library.toggle(lesson) }
                        }
                        Divider().overlay(GlamoStyle.line)
                    }
                }
            }
        }
        .onChange(of: downloadsRequest, initial: true) { _, request in
            if request != nil { filter = "Downloads" }
        }
        .fullScreenCover(item: $player) { PlayerScreen(route: $0) }
        .sheet(item: $removingDownload) { video in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SheetHeading(title: "Remove this download?", inset: false) { removingDownload = nil }
                    Text(verbatim: video.clip.title).font(.glam(.headline)).lineLimit(3)
                    LocalizedText("This removes the offline copy. Any bookmark stays in Favorites.")
                        .foregroundStyle(GlamoStyle.secondary)
                    ActionButton(title: "Remove download", primary: false) {
                        offline.remove(video); removingDownload = nil
                    }
                    ActionButton(title: "Keep it") { removingDownload = nil }
                }.glamoPage()
            }.glamoScreenBackground().presentationDetents([.medium, .large])
        }
    }

    private var downloads: some View {
        VStack(alignment: .leading, spacing: 12) {
            downloadStatus
            if offline.isRestoring || offline.preparingID != nil {
                AccountLoadingIndicator(title: offline.isRestoring ? "Restoring downloads…" : "Preparing download…")
                    .frame(maxWidth: .infinity)
            }
            if !offline.videos.isEmpty {
                LazyVStack(spacing: 10) {
                    ForEach(offline.videos) { downloadRow($0) }
                }
            } else if !offline.busy, offline.error == nil {
                emptyMessage("No downloads yet", detail: "Tap Download on a lesson to watch it offline.")
            }
            DownloadAllowanceSummary()
        }
    }

    private func emptyMessage(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LocalizedText(title).font(.glam(.headline))
            LocalizedText(detail).font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
            Button(action: watchLessons) { LocalizedText("Watch lessons") }
                .buttonStyle(CompactActionStyle())
        }.padding(.vertical, 4)
    }

    @ViewBuilder private var downloadStatus: some View {
        if offline.downloadingID != nil || offline.error != nil {
            VStack(alignment: .leading, spacing: 8) {
                if offline.downloadingID != nil {
                    if let title = offline.currentTitle {
                        Text(verbatim: title).font(.glam(.subheadline, weight: .semibold)).lineLimit(2)
                    }
                    LocalizedText("Downloading · \(Int(offline.progress * 100))%")
                        .font(.glam(.caption)).monospacedDigit()
                    Button("Cancel download") { Task { await offline.cancel() } }
                        .buttonStyle(LibraryActionStyle())
                }
                if let error = offline.error {
                    ErrorNote(message: error)
                    if offline.downloadingID != nil {
                        Button("Retry") { Task { await offline.retryCompletion() } }
                            .buttonStyle(LibraryActionStyle())
                    }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .glamoCard(radius: 20)
        }
    }

    private func downloadRow(_ video: OfflineVideo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { playDownload(video) } label: {
                HStack(spacing: 12) {
                    itemGlyph(.play)
                    Text(verbatim: video.clip.title).font(.glam(.headline, weight: .semibold, editorial: true)).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(PressStyle())
            HStack(spacing: 8) {
                VideoExportEntry(clip: offline.playable(video.clip), compact: true)
                Spacer(minLength: 0)
                removeButton(.close, title: "Remove download") { removingDownload = video }
            }
        }
        .modifier(LibraryRowSurface())
    }

    private func itemGlyph(_ symbol: GlamoGlyph) -> some View {
        Glyph(symbol: symbol, size: 19, tint: GlamoStyle.accent)
            .frame(width: 46, height: 46)
            .background(GlamoStyle.raised, in: Capsule())
            .accessibilityHidden(true)
    }

    private func playDownload(_ video: OfflineVideo) {
        let clips = offline.videos.compactMap { item -> LessonClip? in
            offline.cached(item.id) == nil ? nil : offline.playable(item.clip)
        }
        if clips.contains(where: { $0.id == video.id }) {
            player = PlayerRoute(clips: clips, startID: video.id)
        } else { offline.error = "This download is no longer on this device. Download it again." }
    }

}

private func removeButton(_ symbol: GlamoGlyph, title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Glyph(symbol: symbol, size: 16, tint: GlamoStyle.ink)
            .frame(width: 36, height: 36)
            .background(GlamoStyle.paper, in: Circle())
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }.buttonStyle(PressStyle()).accessibilityLabel(LocalizedStringKey(title))
}

private struct LibraryRowSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).glamoCard(radius: 22)
    }
}

private struct LibraryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.glam(.footnote, weight: .semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(enabled ? GlamoStyle.accent : GlamoStyle.secondary)
            .background(GlamoStyle.paper, in: Capsule())
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

// Uses the existing original bitmap action surfaces; no new system artwork.
struct OfflineDownloadButton: View {
    let clip: LessonClip
    var starting = false
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var downloadGate = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DownloadAllowanceSummary()
            if offline.cached(clip.id) != nil || clip.playbackURL.isFileURL {
                LocalizedText("Available offline").font(.glam(.subheadline)).foregroundStyle(GlamoStyle.accent)
                DownloadCompletionNotice()
            } else if starting || offline.preparingID == clip.id {
                AccountLoadingIndicator(title: "Preparing download…")
            } else if offline.downloadingID == clip.id {
                LocalizedText("Downloading · \(Int(offline.progress * 100))%").font(.glam(.caption))
                ActionButton(title: "Cancel download", primary: false) { Task { await offline.cancel() } }
            } else {
                ActionButton(title: "Download lesson", primary: false) {
                    if quota.mayDownload(clip.id, premium: commerce.premium) {
                        Task { await offline.download(clip) }
                    } else { downloadGate = true }
                }.disabled(offline.busy || clip.playbackURL.isFileURL)
                    .accessibilityIdentifier("player.downloadOffline")
                if offline.isRestoring {
                    LocalizedText("Restoring downloads…").font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                } else if offline.busy {
                    LocalizedText("Another download is in progress.").font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                }
            }
            VideoExportEntry(clip: clip)
            if let error = offline.error {
                ErrorNote(message: error)
                if offline.downloadingID == clip.id {
                    ActionButton(title: "Retry", primary: false) { Task { await offline.retryCompletion() } }
                }
            }
        }.sheet(isPresented: $downloadGate) { MembershipView(rewardKind: .download) }
    }
}

// A separate, always-visible workflow; users need not visit the cache panel.
struct VideoExportEntry: View {
    let clip: LessonClip
    var compact = false
    @State private var showingExport = false
    @EnvironmentObject private var commerce: CommerceStore
    var body: some View {
        Group {
            if compact {
                Button("Export") { showingExport = true }.buttonStyle(LibraryActionStyle())
            } else {
                ActionButton(title: "Export video", primary: false) { showingExport = true }
            }
        }.accessibilityIdentifier("player.openExport")
            .sheet(isPresented: $showingExport) {
                if commerce.canExportMedia { OfflineExportSheet(clip: clip) }
                else { MembershipView(requiredBenefit: .mediaExport) }
            }
    }
}

private struct OfflineExportSheet: View {
    let clip: LessonClip
    @Environment(\.dismiss) private var dismiss
    @StateObject private var departure = ExportDeparture()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeading(title: "Export video", inset: false) { departure.request { dismiss() } }
                Text(verbatim: clip.title).font(.glam(.subheadline)).lineLimit(2)
                OfflineExportButton(clip: clip)
            }.glamoPage()
        }.glamoScreenBackground().presentationDetents([.medium, .large])
            .environmentObject(departure)
            .modifier(ExportDepartureProtection(departure: departure))
    }
}

// One owner for the close button, explicit cancel and interactive dismissal.
@MainActor
final class ExportDeparture: ObservableObject {
    @Published private(set) var running = false
    @Published var confirming = false
    private var cancellation: (() -> Void)?
    private var afterCancellation: (() -> Void)?
    func begin(cancel: @escaping () -> Void) { running = true; cancellation = cancel }
    func finish() {
        running = false; cancellation = nil
        confirming = false; afterCancellation = nil
    }
    func request(_ close: @escaping () -> Void = {}) {
        guard running else { close(); return }
        afterCancellation = close; confirming = true
    }
    func keepWorking() { confirming = false; afterCancellation = nil }
    func stop() {
        let close = afterCancellation
        cancellation?()
        confirming = false; afterCancellation = nil
        close?()
    }
}

struct ExportDepartureProtection: ViewModifier {
    @ObservedObject var departure: ExportDeparture
    var additionalDismissalLock = false
    func body(content: Content) -> some View {
        content.interactiveDismissDisabled(departure.running || additionalDismissalLock)
            .accessibilityHidden(departure.confirming)
            .overlay {
                if departure.confirming {
                    GeometryReader { container in
                        ScrollView {
                            VStack(spacing: 18) {
                                LocalizedText("Stop this export?").font(.glam(.headline))
                                LocalizedText("Stopping cancels this export. Your source video stays in the library.")
                                    .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                ActionButton(title: "Keep exporting", action: departure.keepWorking)
                                ActionButton(title: "Stop export", primary: false, action: departure.stop)
                            }.padding(22).frame(maxWidth: 360)
                                .foregroundStyle(GlamoStyle.ink)
                                .glamoCard(radius: 24).padding(20)
                                .frame(maxWidth: .infinity, minHeight: container.size.height)
                        }.background(.black.opacity(0.7))
                            .accessibilityAddTraits(.isModal)
                    }
                }
            }
    }
}

struct DownloadCompletionNotice: View {
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if offline.completedDownloadID != nil {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    LocalizedText("Ready to watch offline")
                        .font(.glam(.caption)).fixedSize(horizontal: false, vertical: true)
                    Button("View downloads") {
                        offline.completedDownloadID = nil
                        library.openDownloads()
                    }.buttonStyle(CompactActionStyle())
                    IconButton(symbol: .close, label: "Dismiss message") { offline.completedDownloadID = nil }
                }.padding(12).foregroundStyle(GlamoStyle.ink)
                    .glamoGlass(in: RoundedRectangle(cornerRadius: 22))
                    .padding(.horizontal, 12)
            }
        }.task(id: offline.completedDownloadID) {
            guard let notice = offline.completedDownloadID else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            if offline.completedDownloadID == notice { offline.completedDownloadID = nil }
        }
    }
}

// Uncached exports use the same download admission and completion journal.
// Export is a Plus benefit; cached copies still pass the membership check.
private struct OfflineExportButton: View {
    let clip: LessonClip
    @EnvironmentObject private var departure: ExportDeparture
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var downloadGate = false
    @State private var preparingSource = false
    @State private var exportTask: Task<Void, Never>?
    @State private var sharing: SharedFile?
    @State private var exportError: String?
    @State private var exportedFile: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ActionButton(title: preparingSource ? "Preparing export…" : exportTask == nil ? "Export video" : "Exporting…",
                         primary: false, action: startExport)
                .disabled(exportTask != nil)
                .accessibilityIdentifier("player.exportVideo")
            if !clip.playbackURL.isFileURL, offline.cached(clip.id) == nil {
                LocalizedText("Glamo downloads this video before exporting.")
                    .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                DownloadAllowanceSummary()
            }
            if preparingSource, offline.downloadingID == clip.id {
                LocalizedText("Downloading · \(Int(offline.progress * 100))%").font(.glam(.caption))
            }
            if exportTask != nil {
                Button("Cancel export") { departure.request() }.buttonStyle(CompactActionStyle())
            }
            if let exportError { ErrorNote(message: exportError) }
        }
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .sheet(isPresented: $downloadGate) { MembershipView(requiredBenefit: .mediaExport) }
        .onDisappear { exportTask?.cancel() }
    }

    private func startExport() {
        guard exportTask == nil else { return }
        guard commerce.canExportMedia else { downloadGate = true; return }
        if !clip.playbackURL.isFileURL, offline.cached(clip.id) == nil,
           !quota.mayDownload(clip.id, premium: commerce.premium) {
            downloadGate = true
            return
        }
        if let exportedFile, FileManager.default.fileExists(atPath: exportedFile.path) {
            sharing = SharedFile(url: exportedFile); return
        }
        exportError = nil
        exportTask = Task { @MainActor in
            defer { exportTask = nil; preparingSource = false; departure.finish() }
            var ownsDownload = false
            var converted: URL?
            defer { if let converted { try? FileManager.default.removeItem(at: converted) } }
            do {
                try commerce.requireMediaExport()
                var source = clip.playbackURL
                if !source.isFileURL || offline.cached(clip.id)?.isHLS == true {
                    preparingSource = true
                    // A cache request may already be finishing for this clip.
                    // Let it finish, then decide whether its result is a file
                    // or whether the original-file download is still needed.
                    if offline.downloadingID == clip.id {
                        for await downloadID in offline.$downloadingID.values {
                            try Task.checkCancellation()
                            if downloadID != clip.id { break }
                        }
                    }
                    try Task.checkCancellation()
                    if offline.cached(clip.id)?.isHLS != false, offline.downloadingID != clip.id {
                        guard !offline.busy else { throw GlamoError.service("Another download is in progress.") }
                        ownsDownload = true
                        await offline.download(clip, forExport: true)
                    }
                    // Subscribe to the shared download state, including its
                    // current value, so a very fast completion is not missed.
                    for await downloadID in offline.$downloadingID.values {
                        try Task.checkCancellation()
                        if let cached = offline.cached(clip.id), !cached.isHLS { source = cached.url; break }
                        guard downloadID == clip.id else {
                            throw GlamoError.service(offline.error ?? "Download failed. No download allowance was used.")
                        }
                    }
                    try Task.checkCancellation()
                    guard source.isFileURL else { throw GlamoError.storage }
                    preparingSource = false
                }
                var output = source
                if !["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) {
                    let asset = AVURLAsset(url: source)
                    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
                          session.supportedFileTypes.contains(.mp4) else {
                        throw GlamoError.service("This video format cannot be exported. Please use an MP4 or MOV file.")
                    }
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
                    converted = destination
                    session.outputURL = destination
                    session.outputFileType = .mp4
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            session.exportAsynchronously { continuation.resume() }
                        }
                    } onCancel: { session.cancelExport() }
                    try Task.checkCancellation()
                    guard session.status == .completed else {
                        throw GlamoError.service("Video export failed. Please try again.")
                    }
                    output = destination
                }
                try Task.checkCancellation()
                try commerce.requireMediaExport()
                let recording = try await library.importMovie(output, exported: true, title: clip.title)
                let url = try await library.shareFile(for: recording, commerce: commerce)
                exportedFile = url
                if !Task.isCancelled { sharing = SharedFile(url: url) }
            } catch is CancellationError {
                if ownsDownload, offline.downloadingID == clip.id { await offline.cancel() }
            }
            catch {
                exportError = error.localizedDescription
            }
        }
        departure.begin { exportTask?.cancel() }
    }
}

// Shared, live allowance display at the download decision and in the offline library.
struct DownloadAllowanceSummary: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var showingReward = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalizedText("Downloads left").font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
            LocalizedText(api.session == nil ? "Connect to Glamo to see your downloads left." :
                            commerce.premium || quota.downloadsUnlimited ? "Unlimited" :
                            quota.usage == nil ? "Loading…" : "\(quota.downloadsLeft) downloads left today")
                .font(.glam(.subheadline, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if quota.usage != nil, !commerce.premium { AllowanceResetText() }
            if quota.canRequestReward(for: .download, premium: commerce.premium) {
                ActionButton(title: "Get more downloads", primary: false) { showingReward = true }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .glamoCard(radius: 24, fill: GlamoStyle.paper)
            .accessibilityElement(children: .contain)
            .onAppear { quota.resetIfNeeded() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in quota.resetIfNeeded() }
            .sheet(isPresented: $showingReward) { MembershipView(rewardKind: .download) }
    }
}
