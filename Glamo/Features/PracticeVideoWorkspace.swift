import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

enum VideoTool: String, Identifiable, CaseIterable {
    case audio, speed, frame, studio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: return "Extract audio"
        case .speed: return "Change speed"
        case .frame: return "Crop & rotate"
        case .studio: return "Full editor"
        }
    }
    var detail: String {
        switch self {
        case .audio: return "Save the audio as an M4A file."
        case .speed: return "Slow down or speed up a video."
        case .frame: return "Crop to portrait, square or landscape."
        case .studio: return "Trim the clip, adjust its speed or change the frame."
        }
    }
    var editorTab: String {
        switch self {
        case .audio: return "Audio"
        case .speed: return "Speed"
        case .frame: return "Frame"
        case .studio: return "Trim"
        }
    }
    var glyph: GlamoGlyph {
        switch self {
        case .audio: return .sound
        case .speed: return .play
        case .frame: return .feed
        case .studio: return .edit
        }
    }
}

struct ToolsView: View {
    @State private var selectedTool: VideoTool?
    private let tools: [VideoTool] = [.studio, .frame, .speed, .audio]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 0) {
                    ForEach(tools) { tool in
                        if tool != tools.first { Divider().overlay(GlamoStyle.line) }
                        Button { selectedTool = tool } label: {
                            HStack(spacing: 8) {
                                FeatureRow(symbol: tool.glyph, title: tool.title, detail: tool.detail)
                                Glyph(symbol: .back, size: 12, tint: GlamoStyle.secondary).rotationEffect(.degrees(180))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityIdentifier("tools.\(tool.rawValue)")
                    }
                }.glamoCard(radius: 20)
            }.glamoPage()
        }.glamoScreenBackground()
            .sheet(item: $selectedTool) { EditorSheet(initialTool: $0) }
    }
}

struct VideoImportControls: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var photo: PhotosPickerItem?
    @State private var error: String?
    let onImport: (PracticeRecording) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { sources(fillsWidth: false) }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 8) { sources(fillsWidth: true) }
            }
            .disabled(library.importingVideo || showFiles || showPhotos)
            if library.importingVideo { AccountLoadingIndicator(title: "Importing…") }
            if let error { ErrorNote(message: error) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie]) { result in
            switch result {
            case .success(let url): importVideo { try await library.importMovie(url) }
            case .failure(let failure): report(failure)
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .videos, photoLibrary: .shared())
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            importVideo { try await library.importPhoto(item) }
        }
    }

    @ViewBuilder private func sources(fillsWidth: Bool) -> some View {
        Button { error = nil; showFiles = true } label: {
            Label { LocalizedText("Import from Files") } icon: {
                Glyph(symbol: .folder, size: 17, tint: GlamoStyle.onAccent)
            }
        }.buttonStyle(GlamoActionStyle(fillsWidth: fillsWidth))
            .accessibilityIdentifier("video.importFiles")
        Button { error = nil; showPhotos = true } label: {
            Label { LocalizedText("Import from Photos") } icon: {
                Glyph(symbol: .feed, size: 17, tint: GlamoStyle.accent)
            }
        }.buttonStyle(GlamoActionStyle(primary: false, fillsWidth: fillsWidth))
            .accessibilityIdentifier("video.importPhotos")
    }

    private func importVideo(_ load: @escaping () async throws -> PracticeRecording) {
        guard library.beginVideoImport() else { return }
        error = nil
        Task {
            defer { library.finishVideoImport() }
            do {
                let movie = try await load()
                onImport(movie)
            }
            catch { report(error) }
        }
    }

    private func report(_ failure: Error) {
        let cocoa = failure as NSError
        guard !(failure is CancellationError),
              !(cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError),
              !(cocoa.domain == NSURLErrorDomain && cocoa.code == NSURLErrorCancelled) else { return }
        error = failure.localizedDescription
    }
}

extension LibraryStore {
    func importPhoto(_ item: PhotosPickerItem, folderID: UUID? = nil) async throws -> PracticeRecording {
        guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
            throw GlamoError.unsupportedMedia
        }
        defer { try? FileManager.default.removeItem(at: movie.url.deletingLastPathComponent()) }
        return try await importMovie(movie.url, folderID: folderID)
    }
}

struct EditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    var initialMovie: PracticeRecording? = nil
    var initialTool: VideoTool = .studio
    @StateObject private var departure = ExportDeparture()
    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                SheetHeading(title: initialTool == .studio ? "Video editor" : initialTool.title, inset: false) {
                    departure.request { dismiss() }
                }
                .pageHorizontalMargins().padding(.top, 8)
                .disabled(library.importingVideo)
                EditorWorkspace(initialMovie: initialMovie, initialTool: initialTool)
            }
            .padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }.glamoScreenBackground()
            .environmentObject(departure)
            .modifier(ExportDepartureProtection(departure: departure, additionalDismissalLock: library.importingVideo))
    }
}
struct EditorWorkspace: View {
    @EnvironmentObject private var commerce: CommerceStore
    @State private var showingExportMembership = false
    @EnvironmentObject private var departure: ExportDeparture
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    var initialMovie: PracticeRecording? = nil
    var initialTool: VideoTool = .studio
    @StateObject private var editor = VideoEditor()
    @State private var selected: PracticeRecording?
    @State private var completedExport: PracticeRecording?
    @State private var cancelledExportFormat: ExportFormat?
    @State private var exportFailure: ExportFailure?
    @State private var exportShareError: String?
    @State private var exportSharePresentation: ExportSharePresentation?
    @State private var shareURL: SharedFile?
    @State private var tool = "Trim"
    @State private var exportTask: Task<Void, Never>?
    @State private var activeExport: ActiveExport?
    @State private var exportShareTask: Task<Void, Never>?
    @State private var openTask: Task<Void, Never>?
    @State private var didOpenInitialMovie = false
    private let tools = ["Trim", "Frame", "Speed", "Audio"]
    private static let exportCancelledMessage = "Export cancelled. Your original video is unchanged."

    private enum ExportScrollTarget: Hashable { case export, result }

    private enum ExportFormat: String {
        case mp4 = "MP4"
        case m4a = "M4A"
    }

    private struct ActiveExport {
        let format: ExportFormat
        var isFinishing = false
    }

    private struct ExportFailure {
        let format: ExportFormat
        let message: String
    }

    private struct ExportSharePresentation {
        let id: UUID
        var outcome: ShareSheet.Outcome? = nil
    }

    init(initialMovie: PracticeRecording? = nil, initialTool: VideoTool = .studio) {
        self.initialMovie = initialMovie
        self.initialTool = initialTool
        _tool = State(initialValue: initialTool.editorTab)
    }
    var body: some View {
        GeometryReader { container in
            let short = container.size.height < 520
            let wide = container.size.width >= (short ? 660 : 820) && !typeSize.isAccessibilitySize
                && !driveHasReservedRegion(container)
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            let previewAspect: CGFloat = short ? 16.0 / 9.0 : 4.0 / 3.0
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let selected {
                            layout {
                                previewPanel(selected, aspect: previewAspect)
                                    .frame(maxWidth: wide ? 580 : .infinity)
                                editingPanel(selected)
                                    .frame(maxWidth: wide ? 440 : .infinity)
                            }
                        } else {
                            GlamoEmptyState(title: "Choose a video", message: initialTool.detail) {
                                VideoImportControls(onImport: choose)
                            }
                            let availableVideos = library.movies.filter { !$0.isAudio }
                            if !availableVideos.isEmpty {
                                SectionLabel(title: "Video files")
                                ForEach(availableVideos) { movie in
                                    Button { choose(movie) } label: { LocalMediaLabel(movie: movie) }
                                        .buttonStyle(PressStyle()).disabled(library.importingVideo)
                                }
                            }
                        }
                    }
                    .pageHorizontalMargins().padding(.top, 12).padding(.bottom, 24)
                    .frame(maxWidth: wide && selected != nil ? 1060 : 680).frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: exportScrollTarget) { _, target in
                    if let target { scroll.scrollTo(target, anchor: .top) }
                }
            }
        }.glamoScreenBackground()
            .onReceive(editor.preview.$error) { message in
                if let message { editor.error = "Preview could not play. \(message)" }
            }
            .sheet(item: $shareURL) { file in
                ShareSheet(items: [file.url], onCompletion: { [id = file.id, recordingID = file.recordingID] outcome in
                    guard exportSharePresentation?.id == id else { return }
                    if case .completed = outcome, let recordingID { library.recordSharedFile(recordingID) }
                    exportSharePresentation?.outcome = outcome
                })
            }
            .fullScreenCover(isPresented: $showingExportMembership) { MembershipView(requiredBenefit: .mediaExport) }
            .task {
                guard !didOpenInitialMovie, selected == nil, let initialMovie else { return }
                didOpenInitialMovie = true
                choose(initialMovie)
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { editor.preview.pause() } }
            .onDisappear {
                editor.preview.pause()
                exportShareTask?.cancel()
            }
    }

    private var previewOrExportDisabled: Bool {
        editor.isLoading || editor.isPreparingPreview || editor.duration <= 0
    }

    private var editingDisabled: Bool {
        departure.running || editor.isExporting || editor.isLoading || editor.isPreparingPreview
    }

    private var showsExportResult: Bool {
        !departure.running && (completedExport != nil || cancelledExportFormat != nil || exportFailure != nil)
    }

    private var exportScrollTarget: ExportScrollTarget? {
        guard selected != nil else { return nil }
        if departure.running { return .export }
        if showsExportResult, shareURL == nil { return .result }
        return nil
    }

    private func previewPanel(_ movie: PracticeRecording, aspect: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22)
        let title = Text(verbatim: movie.title)
            .font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
            .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
        return VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    title
                    changeVideoButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    changeVideoButton
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            Color.black.overlay {
                VideoSurface(player: editor.preview.player, fill: false)
            }
            .aspectRatio(aspect, contentMode: .fit)

            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        previewPlaybackControls
                        Spacer(minLength: 0)
                        applyPreviewButton
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        previewPlaybackControls
                        applyPreviewButton
                    }
                }
                if editor.isLoading || editor.isPreparingPreview {
                    HStack(spacing: 8) {
                        Image("GlamoLoadingMark").resizable().scaledToFit()
                            .frame(width: 26, height: 5).accessibilityHidden(true)
                        LocalizedText(editor.isPreparingPreview ? "Preparing preview…" : "Preparing your video…")
                            .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .clipShape(shape)
        .glamoGlass(in: shape, tint: GlamoStyle.paper, mediaBackdrop: true)
    }

    @ViewBuilder private var changeVideoButton: some View {
        if !departure.running, !editor.isExporting, !editor.isPreparingPreview {
            Button("Change video") {
                selected = nil
                openTask?.cancel()
                editor.close()
            }
            .buttonStyle(CompactActionStyle()).disabled(library.importingVideo || exportShareTask != nil)
        }
    }

    private var previewPlaybackControls: some View {
        HStack(spacing: 8) {
            PreviewButton(playback: editor.preview)
            DrivePlayerTimes(timeline: editor.preview.timeline, compact: true)
        }
    }

    @ViewBuilder private var applyPreviewButton: some View {
        if !departure.running {
            Button("Preview changes") { Task { await editor.applyPreview() } }
                .buttonStyle(CompactActionStyle()).disabled(previewOrExportDisabled)
        }
    }

    private func editingPanel(_ movie: PracticeRecording) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if initialTool == .studio { toolbar }
            if tool != "Export" {
                controls.disabled(editingDisabled)
            }
            if let error = editor.error, error != exportFailure?.message,
               cancelledExportFormat == nil || error != Self.exportCancelledMessage {
                ErrorNote(message: error)
            }
            if showsExportResult {
                exportFeedback(movie).id(ExportScrollTarget.result)
            }
            exportPanel(movie).id(ExportScrollTarget.export)
        }
    }

    private var toolbar: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 4))
                                                  : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tools, id: \.self) { name in
                        toolButton(name)
                    }
                }
            }
            toolButton("Export")
        }
        .padding(4)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 14), tint: GlamoStyle.surface)
    }

    private func toolButton(_ name: String) -> some View {
        let active = tool == name
        let export = name == "Export"
        return Button { tool = name } label: {
            LocalizedText(name)
                .font(.glam(.subheadline, weight: .semibold))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(active ? GlamoStyle.onAccent : export ? GlamoStyle.accent : GlamoStyle.ink)
                .background(active ? GlamoStyle.accent : export ? GlamoStyle.paperMuted : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).accessibilityAddTraits(active ? .isSelected : [])
    }

    private func exportPanel(_ movie: PracticeRecording) -> some View {
        let language = AppLanguage.from(locale)
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Export").accessibilityAddTraits(.isHeader)
            if departure.running {
                exportProgress
            } else {
                VStack(spacing: 8) {
                    if initialTool != .audio {
                        VStack(alignment: .leading, spacing: 0) {
                            exportOption(audio: false, title: movie.title)
                            if tool == "Export" { exportQuality }
                        }
                        .background(GlamoStyle.paperMuted, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if initialTool == .studio || initialTool == .audio {
                        exportOption(audio: true, title: movie.title)
                            .background(initialTool == .audio ? GlamoStyle.paperMuted : GlamoStyle.paper,
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            LocalizedText("Find exported files in %@ › %@.",
                          L10n.text("Activity", language: language),
                          L10n.text("Exports", language: language))
                .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20),
                    tint: departure.running ? GlamoStyle.paperMuted : GlamoStyle.surface,
                    mediaBackdrop: departure.running)
    }

    private var exportProgress: some View {
        let rawProgress = Double(editor.progress)
        let progress = rawProgress.isFinite ? min(1, max(0, rawProgress)) : 0
        let percentage = (progress * 100).rounded(.down) / 100
        let status = editor.isExporting ? "Exporting" : (activeExport?.isFinishing == true ? "Finishing export…" : "Preparing export…")
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                          : AnyLayout(HStackLayout(spacing: 12))

        return VStack(alignment: .leading, spacing: 12) {
            layout {
                VStack(alignment: .leading, spacing: 5) {
                    if let format = activeExport?.format {
                        Text(verbatim: format.rawValue)
                            .font(.glam(.caption, weight: .semibold)).monospaced()
                            .foregroundStyle(GlamoStyle.accent)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(GlamoStyle.surface, in: Capsule())
                    }
                    LocalizedText(status)
                        .font(.glam(.headline))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if editor.isExporting {
                    Text(verbatim: percentage.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                        .font(.glam(.title2, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(GlamoStyle.accent)
                } else {
                    ProgressView().tint(GlamoStyle.accent).accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)

            if editor.isExporting {
                DriveMeter(value: progress, thickness: 6)
            }
            Divider().overlay(GlamoStyle.line)
            ActionButton(title: "Cancel export", primary: false) { departure.request() }
        }
    }

    @ViewBuilder private func exportFeedback(_ movie: PracticeRecording) -> some View {
        if let completedExport {
            exportResultCard(completedExport)
        } else if let cancelledExportFormat {
            exportRecoveryCard(cancelledExportFormat, movie: movie, title: "Export cancelled")
        } else if let exportFailure {
            exportRecoveryCard(exportFailure.format, movie: movie, title: "Export failed",
                               reason: exportFailure.message)
        }
    }

    private func exportRecoveryCard(_ format: ExportFormat, movie: PracticeRecording, title: String,
                                    reason: String? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        return VStack(alignment: .leading, spacing: 12) {
            if let reason {
                exportIssue(title: title, message: reason)
                Divider().overlay(GlamoStyle.line)
            } else {
                LocalizedText(title)
                    .font(.glam(.title3, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }

            HStack(alignment: .top, spacing: 10) {
                Glyph(symbol: .driveFolder, size: 18, tint: GlamoStyle.accent)
                    .frame(width: 34, height: 34)
                    .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: movie.displayName)
                        .font(.glam(.subheadline, weight: .semibold))
                    LocalizedText("Your original video is still in your library.")
                        .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            Divider().overlay(GlamoStyle.line)
            Button {
                export(audio: format == .m4a, title: movie.title)
            } label: {
                LocalizedText("Export %@ again", format.rawValue)
            }
            .buttonStyle(GlamoActionStyle())
            .disabled(previewOrExportDisabled || exportShareTask != nil)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glamoGlass(in: shape, tint: reason == nil ? GlamoStyle.paperMuted : GlamoStyle.surface, mediaBackdrop: true)
        .overlay {
            if reason != nil {
                shape.strokeBorder(GlamoStyle.danger.opacity(0.36)).allowsHitTesting(false)
            }
        }
    }

    private func exportResultCard(_ file: PracticeRecording) -> some View {
        let detailsLayout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                                 : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        let size = file.byteCount?.formatted(.byteCount(style: .file).locale(locale))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Glyph(symbol: file.isAudio ? .sound : .feed, size: 19, tint: GlamoStyle.accent)
                    .frame(width: 38, height: 38)
                    .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    LocalizedText("Export complete")
                        .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.accent)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: file.displayName)
                        .font(.glam(.headline)).fixedSize(horizontal: false, vertical: true)
                }
            }
            detailsLayout {
                exportDetail("Format", value: file.fileExtension.uppercased().nilIfBlank)
                exportDetail("File size", value: size)
            }
            Divider().overlay(GlamoStyle.line)
            exportShareControls(file)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
    }

    @ViewBuilder private func exportShareControls(_ file: PracticeRecording) -> some View {
        if exportShareTask != nil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(GlamoStyle.accent)
                    .accessibilityHidden(true)
                LocalizedText("Preparing to share…")
                    .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        } else {
            let finishedPresentation = shareURL == nil ? exportSharePresentation : nil
            let cancelledAfterSaving: ShareSheet.Outcome? = cancelledExportFormat == nil ? nil : .cancelled
            let outcome = finishedPresentation?.outcome ?? cancelledAfterSaving
            if exportShareError != nil || finishedPresentation != nil || outcome != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let exportShareError {
                        exportIssue(title: "Share preparation failed", message: exportShareError)
                    } else if let outcome {
                        exportShareOutcomeDetails(outcome)
                    }
                    if library.movies.contains(where: { $0.id == file.id }) {
                        HStack(alignment: .top, spacing: 8) {
                            Glyph(symbol: .driveFolder, size: 16, tint: GlamoStyle.accent)
                            LocalizedText("Your exported file is still in your library.")
                                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            let actionTitle = switch (exportShareError, outcome) {
            case (.some(_), _), (_, .some(.failed(_))): "Retry sharing"
            default: finishedPresentation == nil && outcome == nil ? "Share file" : "Share again"
            }
            Button {
                shareExport(file)
            } label: {
                Label { LocalizedText(actionTitle) } icon: {
                    Glyph(symbol: .driveShare, size: 17, tint: shareURL == nil ? GlamoStyle.onAccent : GlamoStyle.secondary)
                }
            }
            .buttonStyle(GlamoActionStyle())
            .disabled(shareURL != nil)
        }
    }

    @ViewBuilder private func exportShareOutcomeDetails(_ outcome: ShareSheet.Outcome) -> some View {
        switch outcome {
        case .completed:
            LocalizedText("Share complete")
                .font(.glam(.headline)).foregroundStyle(GlamoStyle.accent)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .cancelled:
            LocalizedText("Share cancelled")
                .font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .failed(let message):
            exportIssue(title: "Share failed", message: message)
        }
    }

    private func exportDetail(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LocalizedText(title).font(.glam(.caption, weight: .medium)).foregroundStyle(GlamoStyle.secondary)
            Group {
                if let value { Text(verbatim: value) }
                else { LocalizedText("Unavailable") }
            }
            .font(.glam(.subheadline, weight: .semibold)).monospacedDigit()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func exportIssue(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LocalizedText(title)
                .font(.glam(.headline)).foregroundStyle(GlamoStyle.danger)
                .accessibilityAddTraits(.isHeader)
            LocalizedText(message)
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.ink)
        }
        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
    }

    private var exportQuality: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(GlamoStyle.controlLine.opacity(0.24))
            LocalizedText("Export quality").font(.glam(.subheadline, weight: .semibold))
            FlowChoices(values: ExportQuality.allCases.map(\.rawValue), selected: editor.recipe.quality.rawValue) { value in
                editor.recipe.quality = ExportQuality(rawValue: value) ?? .full
            }
            LocalizedText("MP4 · Up to the selected resolution · 30 fps\nSmaller resolutions reduce export size. Source videos are never upscaled.")
                .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .disabled(editingDisabled)
    }

    private func exportOption(audio: Bool, title: String) -> some View {
        let primary = !audio || initialTool == .audio
        let format = audio ? "M4A" : "MP4"
        let detail = audio ? "Keep just the soundtrack as an M4A file." : "Save a separate MP4 copy of your edits."
        return Button {
            export(audio: audio, title: title)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: format).font(.glam(.headline)).monospaced()
                        .foregroundStyle(GlamoStyle.accent)
                    LocalizedText(detail).font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Glyph(symbol: .back, size: 14, tint: primary ? GlamoStyle.onAccent : GlamoStyle.accent)
                    .rotationEffect(.degrees(layoutDirection == .leftToRight ? 180 : 0))
                    .frame(width: 38, height: 38)
                    .background(primary ? GlamoStyle.accent : GlamoStyle.surface, in: Circle())
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(previewOrExportDisabled || exportShareTask != nil)
        .accessibilityLabel(Text(LocalizedStringKey(audio ? "Export M4A" : "Export MP4")))
        .accessibilityHint(Text(LocalizedStringKey(detail)))
    }
    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tool {
            case "Trim":
                trimControls
            case "Frame":
                LocalizedText("Crop & rotate").font(.glam(.title3, weight: .bold))
                FlowChoices(values: VideoFrame.allCases.map(\.rawValue), selected: editor.recipe.frame.rawValue) { value in editor.recipe.frame = VideoFrame(rawValue: value) ?? .original }
                ActionButton(title: "Rotate 90° · \((editor.recipe.quarterTurns % 4) * 90)°", primary: false) { editor.recipe.quarterTurns = (editor.recipe.quarterTurns + 1) % 4 }
                ActionButton(title: editor.recipe.mirrored ? "Mirror: On" : "Mirror: Off", primary: false) { editor.recipe.mirrored.toggle() }
                LocalizedText("Crop starts at the center. Tap Preview changes to check the result.").font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
            case "Speed":
                LocalizedText("Playback speed").font(.glam(.title3, weight: .bold))
                FlowChoices(values: ["0.5×", "0.75×", "1×", "1.5×", "2×"], selected: String(format: "%g×", editor.recipe.speed)) { value in editor.recipe.speed = Double(value.replacingOccurrences(of: "×", with: "")) ?? 1 }
            case "Audio":
                if initialTool == .audio {
                    LocalizedText("Choose a clip with sound to export its audio.")
                        .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                } else {
                    LocalizedText("Video sound").font(.glam(.title3, weight: .bold))
                    ActionButton(title: editor.recipe.muted ? "Audio: Muted" : "Audio: Original", primary: false) { editor.recipe.muted.toggle() }
                    LocalizedText("Audio extraction uses your trim and speed settings.").font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                }
            default:
                EmptyView()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.surface)
    }

    private var trimControls: some View {
        let heading = LocalizedText("Trim video").font(.glam(.title3, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
        let duration = LocalizedText("Final duration · %@",
                                     durationLabel((editor.recipe.end - editor.recipe.start) / editor.recipe.speed))
            .font(.glam(.footnote, weight: .semibold)).monospacedDigit()
            .foregroundStyle(GlamoStyle.accent)
            .fixedSize(horizontal: false, vertical: true)
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    heading
                    Spacer(minLength: 0)
                    duration
                }
                VStack(alignment: .leading, spacing: 4) {
                    heading
                    duration
                }
            }
            if !editor.thumbnails.isEmpty { trimFilmstrip }

            VStack(spacing: 2) {
                trimControl("Start", label: "Trim start", value: Binding(
                    get: { editor.recipe.start },
                    set: {
                        editor.recipe.start = min($0, editor.recipe.end - 0.1)
                        editor.preview.seek($0)
                    }
                ))
                trimControl("End", label: "Trim end", value: Binding(
                    get: { editor.recipe.end },
                    set: { editor.recipe.end = max($0, editor.recipe.start + 0.1) }
                ))
            }
        }
    }

    private var trimFilmstrip: some View {
        GeometryReader { strip in
            let width = strip.size.width
            let frameWidth = width / CGFloat(max(1, editor.thumbnails.count))
            let duration = max(0.1, editor.duration)
            let start = width * CGFloat(min(1, max(0, editor.recipe.start / duration)))
            let end = width * CGFloat(min(1, max(0, editor.recipe.end / duration)))

            HStack(spacing: 0) {
                ForEach(Array(editor.thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: frameWidth, height: strip.size.height)
                        .clipped()
                }
            }
            .overlay {
                HStack(spacing: 0) {
                    GlamoStyle.ink.opacity(0.58).frame(width: start)
                    Rectangle().strokeBorder(GlamoStyle.onAccent, lineWidth: 2)
                        .background(GlamoStyle.accent.opacity(0.16))
                        .frame(width: max(0, end - start))
                    GlamoStyle.ink.opacity(0.58).frame(width: width - end)
                }
            }
        }
        .frame(height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true).allowsHitTesting(false)
    }

    private func trimControl(_ title: String, label: String, value: Binding<Double>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                LocalizedText(title).foregroundStyle(GlamoStyle.secondary)
                Spacer(minLength: 0)
                Text(verbatim: durationLabel(value.wrappedValue)).monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
            }
            .font(.glam(.subheadline, weight: .semibold))
            GlamoScrubber(value: value, range: 0...max(0.1, editor.duration), label: label,
                          tint: GlamoStyle.accent, trackTint: GlamoStyle.controlLine.opacity(0.5))
        }
    }
    private func choose(_ movie: PracticeRecording) {
        openTask?.cancel()
        selected = movie
        clearExportFeedback()
        openTask = Task {
            guard !Task.isCancelled else { return }
            await editor.open(library.url(for: movie))
        }
    }
    private func export(audio: Bool, title: String) {
        guard exportTask == nil, exportShareTask == nil else { return }
        guard commerce.canExportMedia else { showingExportMembership = true; return }
        let folderID = selected?.folderID
        clearExportFeedback()
        let format: ExportFormat = audio ? .m4a : .mp4
        activeExport = ActiveExport(format: format)
        exportTask = Task {
            defer {
                if Task.isCancelled { cancelledExportFormat = format }
                exportTask = nil
                activeExport = nil
                departure.finish()
            }
            guard let output = await editor.export(audioOnly: audio) else {
                if !Task.isCancelled, editor.error != Self.exportCancelledMessage {
                    let message = editor.error ?? "Export could not finish. Your original video is unchanged."
                    exportFailure = ExportFailure(format: format, message: message)
                }
                return
            }
            if Task.isCancelled { try? FileManager.default.removeItem(at: output); return }
            activeExport?.isFinishing = true
            do {
                defer { try? FileManager.default.removeItem(at: output) }
                try commerce.requireMediaExport()
                let suffix = L10n.text(audio ? "Audio" : "Edit")
                let saved = try await library.importMovie(output, exported: true, title: "\(title) · \(suffix)",
                                                          folderID: folderID)
                if !Task.isCancelled { completedExport = saved }
                await presentExportShare(saved)
            } catch is CancellationError { }
            catch {
                let message = "Couldn’t save the export to your library. \(error.localizedDescription)"
                exportFailure = ExportFailure(format: format, message: message)
            }
        }
        departure.begin { exportTask?.cancel(); editor.cancelExport() }
    }

    private func clearExportFeedback() {
        completedExport = nil
        cancelledExportFormat = nil
        exportFailure = nil
        exportShareError = nil
        exportSharePresentation = nil
    }

    private func shareExport(_ file: PracticeRecording) {
        guard exportTask == nil, exportShareTask == nil, shareURL == nil else { return }
        guard commerce.canExportMedia else { showingExportMembership = true; return }
        exportShareError = nil
        exportSharePresentation = nil
        cancelledExportFormat = nil
        exportShareTask = Task {
            defer { exportShareTask = nil }
            await presentExportShare(file)
        }
    }

    private func presentExportShare(_ file: PracticeRecording) async {
        do {
            let share = try await library.shareFile(for: file, commerce: commerce)
            if !Task.isCancelled {
                let sharedFile = SharedFile(url: share, recordingID: file.id)
                exportSharePresentation = ExportSharePresentation(id: sharedFile.id)
                shareURL = sharedFile
            }
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled { exportShareError = error.localizedDescription }
        }
    }
}

struct LocalMediaLabel: View {
    let movie: PracticeRecording

    var body: some View {
        HStack(spacing: 12) {
            LocalMediaThumbnail(movie: movie)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: movie.title).font(.glam(.subheadline, weight: .semibold))
                    .lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { metadata }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 3) { metadata }
                }
                .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                .accessibilityElement(children: .combine)
            }.fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(GlamoStyle.ink)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var metadata: some View {
        if !movie.fileExtension.isEmpty {
            Text(verbatim: movie.fileExtension.uppercased()).monospaced()
        }
        LocalizedDateText(date: movie.date)
    }
}

@MainActor
func makeLocalThumbnail(_ url: URL, edge: CGFloat) async -> UIImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: edge, height: edge)
    guard let frame = try? await generator.image(at: .zero), !Task.isCancelled else { return nil }
    return UIImage(cgImage: frame.image)
}

private struct LocalMediaThumbnail: View {
    @EnvironmentObject private var library: LibraryStore
    let movie: PracticeRecording
    @State private var image: UIImage?

    var body: some View {
        GlamoStyle.raised.overlay {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Glyph(symbol: movie.isAudio ? .sound : .feed, size: 19, tint: GlamoStyle.secondary)
            }
        }
        .frame(width: 68, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
        .task(id: movie.id) {
            image = nil
            guard !movie.isAudio else { return }
            image = await makeLocalThumbnail(library.url(for: movie), edge: 208)
        }
    }
}

struct PreviewButton: View {
    @ObservedObject var playback: PlaybackController
    var body: some View {
        IconButton(symbol: playback.isPlaying ? .pause : .play,
                   label: playback.isPlaying ? "Pause preview" : "Play preview",
                   tint: GlamoStyle.onAccent) { playback.toggle() }
            .background(GlamoStyle.accent, in: Circle())
    }
}
struct FlowChoices: View {
    let values: [String]
    let selected: String
    var action: (String) -> Void
    var body: some View {
        ChipFilter(values: values, selected: selected, select: action)
    }
}
struct SharedFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    var recordingID: UUID? = nil
}
struct ShareSheet: UIViewControllerRepresentable {
    enum Outcome: Sendable {
        case completed
        case cancelled
        case failed(String)
    }

    let items: [Any]
    var onCompletion: (@MainActor @Sendable (Outcome) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let onCompletion {
            controller.completionWithItemsHandler = { @Sendable _, completed, _, error in
                let outcome: Outcome
                if let error {
                    outcome = .failed(error.localizedDescription)
                } else {
                    outcome = completed ? .completed : .cancelled
                }
                Task { @MainActor in onCompletion(outcome) }
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
    @AccessibilityFocusState private var confirmationFocused: Bool

    func body(content: Content) -> some View {
        content.interactiveDismissDisabled(departure.running || additionalDismissalLock)
            .allowsHitTesting(!departure.confirming)
            .accessibilityHidden(departure.confirming)
            .overlay {
                if departure.confirming {
                    GeometryReader { container in
                        let pane = drivePaneMargins(in: container, includesHorizontalFold: true)
                        ScrollView {
                            confirmationCard
                                .padding(20)
                                .frame(maxWidth: .infinity, minHeight: max(0, container.size.height - pane.top - pane.bottom))
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .padding(pane)
                    }
                    .background(GlamoStyle.ink.opacity(0.66).ignoresSafeArea(.container, edges: .all))
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { departure.keepWorking() }
                    .onAppear { confirmationFocused = true }
                }
            }
    }

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                LocalizedText("Stop this export?")
                    .font(.glam(.title3, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($confirmationFocused)
                LocalizedText("Your original video will stay in your library.")
                    .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
            }
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ActionButton(title: "Keep exporting", action: departure.keepWorking)
                Button(role: .destructive, action: departure.stop) {
                    LocalizedText("Stop export")
                        .font(.glam(.subheadline, weight: .semibold))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(GlamoStyle.danger)
                        .background(GlamoStyle.danger.opacity(0.10), in: Capsule())
                        .contentShape(.interaction, Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(20).frame(maxWidth: 360)
        .foregroundStyle(GlamoStyle.ink)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 24), tint: GlamoStyle.surface, mediaBackdrop: true)
    }
}
