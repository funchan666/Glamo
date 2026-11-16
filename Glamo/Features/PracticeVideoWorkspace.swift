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
            importVideo {
                guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                    throw GlamoError.unsupportedMedia
                }
                defer { try? FileManager.default.removeItem(at: movie.url.deletingLastPathComponent()) }
                return try await library.importMovie(movie.url)
            }
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
            Label { LocalizedText("Choose from Photos") } icon: {
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

struct EditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    var initialMovie: PracticeRecording? = nil
    var initialTool: VideoTool = .studio
    @StateObject private var departure = ExportDeparture()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                IconButton(symbol: .close, label: "Close", glass: true) {
                    departure.request { dismiss() }
                }.disabled(library.importingVideo)
            }
            .pageHorizontalMargins().padding(.top, 8)
            EditorWorkspace(initialMovie: initialMovie, initialTool: initialTool)
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
    var initialMovie: PracticeRecording? = nil
    var initialTool: VideoTool = .studio
    @StateObject private var editor = VideoEditor()
    @State private var selected: PracticeRecording?
    @State private var error: String?
    @State private var shareURL: SharedFile?
    @State private var tool = "Trim"
    @State private var exportTask: Task<Void, Never>?
    @State private var openTask: Task<Void, Never>?
    @State private var didOpenInitialMovie = false
    private let tools = ["Trim", "Frame", "Speed", "Audio", "Export"]
    init(initialMovie: PracticeRecording? = nil, initialTool: VideoTool = .studio) {
        self.initialMovie = initialMovie
        self.initialTool = initialTool
        _tool = State(initialValue: initialTool.editorTab)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let selected {
                    HStack {
                        Text(verbatim: selected.title).font(.glam(.subheadline, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if !departure.running, !editor.isExporting, !editor.isPreparingPreview {
                            Button("Change video") {
                                self.selected = nil
                                openTask?.cancel()
                                editor.close()
                            }
                                .buttonStyle(CompactActionStyle()).disabled(library.importingVideo)
                        }
                    }
                    VideoSurface(player: editor.preview.player, fill: false)
                        .aspectRatio(4.0 / 3.0, contentMode: .fit).background(.black).clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(alignment: .bottomTrailing) { PreviewButton(playback: editor.preview).padding(8) }
                    if editor.isLoading { LocalizedText("Preparing your video…").foregroundStyle(GlamoStyle.secondary) }
                    if editor.isPreparingPreview { AccountLoadingIndicator(title: "Preparing preview…").frame(maxWidth: .infinity) }
                    if initialTool == .studio {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(tools, id: \.self) { name in
                                    Button(LocalizedStringKey(name)) { tool = name }.font(.glam(.subheadline, weight: .semibold))
                                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 20).frame(minHeight: 48)
                                        .foregroundStyle(tool == name ? GlamoStyle.onAccent : GlamoStyle.ink)
                                        .background { GlamSurface(tone: tool == name ? .accent : .raised) }.buttonStyle(PressStyle())
                                        .accessibilityAddTraits(tool == name ? .isSelected : [])
                                }
                            }
                        }
                    }
                    controls.disabled(departure.running || editor.isExporting || editor.isLoading || editor.isPreparingPreview)
                    if let error = editor.error { ErrorNote(message: error) }
                    if let error { ErrorNote(message: error) }
                    if departure.running {
                        VStack(spacing: 14) {
                            LocalizedText(editor.isExporting ? "Exporting · \(Int(editor.progress * 100))%" : "Preparing export…")
                                .font(.glam(.subheadline)).monospacedDigit()
                            GeometryReader { geometry in
                                Color.clear.background(GlamoStyle.raised)
                                    .overlay(alignment: .leading) { GlamoStyle.accent.frame(width: geometry.size.width * CGFloat(editor.progress)) }
                            }.frame(height: 4)
                            ActionButton(title: "Cancel export", primary: false) { departure.request() }
                        }
                    } else {
                        ActionButton(title: initialTool == .audio ? "Export M4A" : "Export video") {
                            export(audio: initialTool == .audio, title: selected.title)
                        }.disabled(editor.isLoading || editor.isPreparingPreview || editor.duration <= 0)
                        ActionButton(title: "Preview changes", primary: false) { Task { await editor.applyPreview() } }
                            .disabled(editor.isLoading || editor.isPreparingPreview || editor.duration <= 0)
                    }
                    LocalizedText("Processed on your device. Finished files appear in Files under Exports.")
                        .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                } else {
                    GlamoEmptyState(title: "Choose a video", message: initialTool.detail) {
                        VideoImportControls(onImport: choose)
                    }
                    if let error { ErrorNote(message: error) }
                    let availableVideos = library.movies.filter { !$0.isAudio }
                    if !availableVideos.isEmpty {
                        SectionLabel(title: "Video files")
                        ForEach(availableVideos) { movie in
                            Button { choose(movie) } label: { LocalMediaLabel(movie: movie) }
                                .buttonStyle(PressStyle()).disabled(library.importingVideo)
                        }
                    }
                }
            }.glamoPage()
        }.glamoScreenBackground()
            .onReceive(editor.preview.$error) { message in
                if let message { editor.error = "Preview could not play. \(message)" }
            }
            .sheet(item: $shareURL) { ShareSheet(items: [$0.url]) }
            .sheet(isPresented: $showingExportMembership) { MembershipView(requiredBenefit: .mediaExport) }
            .task {
                guard !didOpenInitialMovie, selected == nil, let initialMovie else { return }
                didOpenInitialMovie = true
                choose(initialMovie)
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { editor.preview.pause() } }
            .onDisappear { editor.preview.pause() }
    }
    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch tool {
            case "Trim":
                LocalizedText("Trim video").font(.glam(.title3, weight: .bold))
                if !editor.thumbnails.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(Array(editor.thumbnails.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 42, height: 64).clipped()
                            }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                }
                HStack { LocalizedText("Start"); Spacer(); Text(verbatim: durationLabel(editor.recipe.start)).monospacedDigit() }
                GlamoScrubber(value: Binding(get: { editor.recipe.start }, set: { editor.recipe.start = min($0, editor.recipe.end - 0.1); editor.preview.seek($0) }), range: 0...max(0.1, editor.duration), label: "Trim start")
                HStack { LocalizedText("End"); Spacer(); Text(verbatim: durationLabel(editor.recipe.end)).monospacedDigit() }
                GlamoScrubber(value: Binding(get: { editor.recipe.end }, set: { editor.recipe.end = max($0, editor.recipe.start + 0.1) }), range: 0...max(0.1, editor.duration), label: "Trim end")
                LocalizedText("Final duration · \(durationLabel((editor.recipe.end - editor.recipe.start) / editor.recipe.speed))").font(.glam(.footnote)).foregroundStyle(GlamoStyle.accent)
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
                    ActionButton(title: "Export M4A", primary: false) { export(audio: true, title: selected?.title ?? "Audio") }
                    LocalizedText("Audio extraction uses your trim and speed settings.").font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                }
            default:
                LocalizedText("Export quality").font(.glam(.title3, weight: .bold))
                FlowChoices(values: ExportQuality.allCases.map(\.rawValue), selected: editor.recipe.quality.rawValue) { value in editor.recipe.quality = ExportQuality(rawValue: value) ?? .full }
                LocalizedText("MP4 · Up to the selected resolution · 30 fps\nSmaller resolutions reduce export size. Source videos are never upscaled.").font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
            }
        }.padding(18).glamoCard(radius: 24)
    }
    private func choose(_ movie: PracticeRecording) {
        openTask?.cancel()
        selected = movie
        error = nil
        openTask = Task {
            guard !Task.isCancelled else { return }
            await editor.open(library.url(for: movie))
        }
    }
    private func export(audio: Bool, title: String) {
        guard exportTask == nil else { return }
        guard commerce.canExportMedia else { showingExportMembership = true; return }
        error = nil
        exportTask = Task {
            defer { exportTask = nil; departure.finish() }
            guard let output = await editor.export(audioOnly: audio) else { return }
            if Task.isCancelled { try? FileManager.default.removeItem(at: output); return }
            do {
                defer { try? FileManager.default.removeItem(at: output) }
                try commerce.requireMediaExport()
                let suffix = L10n.text(audio ? "Audio" : "Edit")
                let saved = try await library.importMovie(output, exported: true, title: "\(title) · \(suffix)")
                let share = try await library.shareFile(for: saved, commerce: commerce)
                if !Task.isCancelled { shareURL = SharedFile(url: share) }
            } catch is CancellationError { }
            catch { self.error = "Couldn’t save the export to your library. \(error.localizedDescription)" }
        }
        departure.begin { exportTask?.cancel(); editor.cancelExport() }
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
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: library.url(for: movie)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 208, height: 152)
            if let result = try? await generator.image(at: .zero), !Task.isCancelled {
                image = UIImage(cgImage: result.image)
            }
        }
    }
}

struct LocalMediaPreview: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var playback = PlaybackController()
    @State private var scrubbing = false
    @State private var editing = false
    let movie: PracticeRecording

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: movie.title).font(.glam(.title2, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if movie.isAudio {
                        Glyph(symbol: .sound, size: 34, tint: GlamoStyle.secondary)
                            .frame(maxWidth: .infinity, minHeight: 98)
                            .background(GlamoStyle.raised, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        VideoSurface(player: playback.player, fill: false)
                            .aspectRatio(16.0 / 10.0, contentMode: .fit)
                            .background(.black, in: RoundedRectangle(cornerRadius: 16))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    if let error = playback.error {
                        ErrorNote(message: error)
                    } else if playback.isLoading {
                        LocalizedText("Loading…").foregroundStyle(GlamoStyle.secondary)
                    }
                    HStack(spacing: 12) {
                        IconButton(symbol: playback.isPlaying ? .pause : .play,
                                   label: playback.isPlaying ? "Pause preview" : "Play preview", glass: true) {
                            playback.toggle()
                        }.disabled(playback.error != nil || playback.isLoading)
                        PlayerProgressControl(playback: playback, timeline: playback.timeline,
                                              enabled: !playback.isLoading, canResume: phase == .active && !editing,
                                              scrubbing: $scrubbing, tint: GlamoStyle.ink)
                    }
                    if !movie.isAudio {
                        ActionButton(title: "Edit") {
                            playback.pause()
                            editing = true
                        }.disabled(playback.isLoading || playback.error != nil)
                    }
                }.glamoPage()
            }
        }
        .glamoScreenBackground()
        .task { playback.load(library.url(for: movie), autoplay: false) }
        .onChange(of: phase) { _, phase in
            if phase != .active { playback.pause() }
        }
        .onDisappear { playback.release() }
        .sheet(isPresented: $editing) { EditorSheet(initialMovie: movie) }
    }
}

struct PreviewButton: View {
    @ObservedObject var playback: PlaybackController
    var body: some View {
        IconButton(symbol: playback.isPlaying ? .pause : .play,
                   label: playback.isPlaying ? "Pause preview" : "Play preview", glass: true) { playback.toggle() }
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
struct SharedFile: Identifiable { let id = UUID(); let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
