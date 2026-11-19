import SwiftUI
import AVFoundation
import Combine

@MainActor
final class DrivePlaybackSession: ObservableObject {
    let playback = PlaybackController()
    @Published private(set) var currentID: UUID?
    @Published var expanded = false
    @Published private(set) var hasFinished = false
    private(set) var queue: [UUID] = []
    private weak var library: LibraryStore?
    private var started = false
    private var savedSeconds: Double?
    private var elapsedObservation: AnyCancellable?

    init() {
        playback.onEnd = { [weak self] in self?.finishFile() }
        // A manual seek away from the start after completion dismisses the notice.
        elapsedObservation = playback.timeline.$elapsed
            .filter { $0 > 0 }
            .sink { [weak self] _ in self?.clearCompletion() }
    }

    func open(_ file: PracticeRecording, among files: [PracticeRecording], library: LibraryStore) {
        self.library = library
        queue = files.map(\.id)
        if !queue.contains(file.id) { queue.insert(file.id, at: 0) }
        if currentID != file.id || playback.error != nil { load(file) }
        else { playback.play() }
        expanded = true
    }

    func files(in library: LibraryStore) -> [PracticeRecording] {
        let indexed = Dictionary(library.movies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return queue.compactMap { indexed[$0] }
    }

    func neighbor(_ offset: Int, in files: [PracticeRecording]) -> PracticeRecording? {
        guard let index = files.firstIndex(where: { $0.id == currentID }),
              files.indices.contains(index + offset) else { return nil }
        return files[index + offset]
    }

    func select(_ file: PracticeRecording) {
        if currentID == file.id, playback.error == nil { return }
        load(file)
    }

    func retry(_ file: PracticeRecording) { load(file) }

    func markStarted() {
        guard !started else { return }
        clearCompletion()
        started = true
        checkpoint()
    }

    func checkpoint() {
        persist(seconds: playback.timeline.elapsed)
    }

    func pause() {
        checkpoint()
        playback.pause()
    }

    func stop() {
        checkpoint()
        clearCompletion()
        expanded = false
        currentID = nil
        queue = []
        playback.release()
        started = false
        savedSeconds = nil
    }

    private func load(_ file: PracticeRecording) {
        guard let library else { return }
        checkpoint()
        clearCompletion()
        started = false
        savedSeconds = nil
        currentID = file.id
        playback.setSpeed(PlaybackPreferences.shared.speed)
        playback.load(library.url(for: file), autoplay: false)
        if PlaybackPreferences.shared.resume, let position = file.viewing,
           position.seconds > 0, position.seconds < position.duration - 1 {
            playback.seek(position.seconds)
        }
        playback.play()
    }

    private func finishFile() {
        persist(seconds: 0, completed: true)
        started = false
        hasFinished = true
    }

    private func clearCompletion() {
        if hasFinished { hasFinished = false }
    }

    private func persist(seconds: Double, completed: Bool = false) {
        guard started, let currentID, let library, playback.error == nil else { return }
        let duration = playback.timeline.duration
        guard duration.isFinite, duration > 0.1, seconds.isFinite else { return }
        if !completed, let savedSeconds, abs(savedSeconds - seconds) < 0.75 { return }
        savedSeconds = seconds
        library.saveViewingPosition(for: currentID, seconds: seconds, duration: duration)
    }
}

struct DrivePlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var videoOptionsFocused: Bool
    @ObservedObject var session: DrivePlaybackSession
    @State private var fileOptions: PracticeRecording?
    @State private var showingQueue = true
    @State private var cinema = true
    @State private var showingVideoRates = false
    @State private var showingVideoOptions = false
    @State private var scrubbing = false
    @State private var headerHeight: CGFloat = 48

    var body: some View {
        GeometryReader { container in
            let pane = drivePaneMargins(in: container, includesHorizontalFold: true)
            let width = container.size.width - pane.leading - pane.trailing
            let height = container.size.height - pane.top - pane.bottom
            let hasReservedRegion = driveHasReservedRegion(container)
            if let movie = library.movies.first(where: { $0.id == session.currentID }) {
                let files = session.files(in: library)
                Group {
                    if cinema {
                        immersivePlayer(movie, files: files, width: width, height: height,
                                        extendsVideo: !hasReservedRegion)
                    } else {
                        playerWithQueue(movie, files: files, width: width, height: height,
                                        allowsColumns: typeSize < .xxLarge && !hasReservedRegion)
                    }
                }
                .padding(pane)
            }
        }
        .glamoScreenBackground(cinema ? .black : GlamoStyle.background)
        .foregroundStyle(GlamoStyle.ink)
        .preferredColorScheme(cinema ? .dark : .light)
        .presentationBackground(cinema ? .black : GlamoStyle.background)
        .driveDialog(item: $fileOptions) { movie in
            DriveItemSheet(item: .file(movie), pausePlayback: session.pause)
        }
    }

    private func playerWithQueue(_ movie: PracticeRecording, files: [PracticeRecording],
                                 width: CGFloat, height: CGFloat, allowsColumns: Bool) -> some View {
        let controlsBesideVideo = allowsColumns && width >= 640 && height < 420
        let queueBesideVideo = allowsColumns && width >= 780 && !controlsBesideVideo && files.count > 1
        let titleInHeader = width >= 560 && typeSize < .xxLarge
        let railWidth: CGFloat? = controlsBesideVideo ? min(340, width * 0.43) : nil
        let availableHeight = max(0, height - headerHeight - 28)
        let stageHeight = controlsBesideVideo ? max(128, availableHeight)
            : max(128, min(availableHeight * 0.58, width * (queueBesideVideo ? 0.42 : 0.68)))
        let layout = queueBesideVideo ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                                      : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))

        return ScrollViewReader { scroll in
            let locateCurrent = { scroll.scrollTo(movie.id) }
            let locateInHeader = files.count > 1 && showingQueue && width >= 260

            VStack(spacing: 0) {
                playerHeader(movie, showsFileTitle: titleInHeader, locateCurrent: locateInHeader ? locateCurrent : nil)
                    .pageHorizontalMargins().padding(.vertical, 6)
                    .frame(maxWidth: 1100).frame(maxWidth: .infinity)
                    .background(GlamoStyle.background, ignoresSafeAreaEdges: [.horizontal, .top])
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !titleInHeader { fileTitle(movie) }
                        layout {
                            playbackPanel(movie, files: files, height: stageHeight, railWidth: railWidth)
                            if files.count > 1 {
                                DrivePlayerQueue(playback: session.playback, isExpanded: $showingQueue,
                                                 files: files, current: movie, select: session.select,
                                                 locateCurrent: locateCurrent)
                                    .frame(maxWidth: queueBesideVideo ? 300 : .infinity, alignment: .leading)
                            }
                        }
                    }
                    .pageHorizontalMargins()
                    .padding(.top, 8).padding(.bottom, 20)
                    .frame(maxWidth: 1100).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func playbackPanel(_ movie: PracticeRecording, files: [PracticeRecording], height: CGFloat,
                               railWidth: CGFloat?) -> some View {
        let next = session.neighbor(1, in: files)
        let layout = railWidth != nil ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                                      : AnyLayout(VStackLayout(spacing: 12))
        return layout {
            ZStack {
                DrivePlayerPicture(playback: session.playback, isAudio: movie.isAudio)
                    .frame(height: height)
                playbackFeedback(movie, next: next)
                    .padding(12)
            }
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 20))

            DriveTransport(playback: session.playback, scrubbing: $scrubbing,
                           previous: session.neighbor(-1, in: files), next: next,
                           open: session.select, cinema: false, toggleCinema: { cinema.toggle() },
                           compactRail: railWidth != nil)
                .frame(maxWidth: railWidth ?? .infinity)
                .glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.paper, mediaBackdrop: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func immersivePlayer(_ movie: PracticeRecording, files: [PracticeRecording],
                                 width: CGFloat, height: CGFloat, extendsVideo: Bool) -> some View {
        let next = session.neighbor(1, in: files)
        let short = height < 400
        let compactControls = short || width < 280 || typeSize.isAccessibilitySize
        let showingOverlay = showingVideoOptions || showingVideoRates

        return VStack(spacing: 4) {
            immersiveHeader(movie)
                .pageHorizontalMargins()
                .padding(.top, short ? 4 : 10)

            GeometryReader { space in
                ScrollView {
                    playbackFeedback(movie, next: next, overVideo: true, compact: compactControls)
                        .pageHorizontalMargins()
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: space.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            DriveTransport(playback: session.playback, scrubbing: $scrubbing,
                           previous: session.neighbor(-1, in: files), next: next,
                           open: session.select, cinema: true, toggleCinema: { cinema.toggle() },
                           compactRail: short && width >= 580,
                           stacksVideoActions: width < 350 && typeSize.isAccessibilitySize,
                           showingVideoRates: $showingVideoRates)
                .frame(maxWidth: 840)
                .pageHorizontalMargins()
                .padding(.bottom, short ? 4 : 0)
        }
        .background {
            DrivePlayerPicture(playback: session.playback, isAudio: movie.isAudio, immersive: true)
                .overlay {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.20), location: 0),
                        .init(color: .clear, location: 0.13),
                        .init(color: .clear, location: 0.27),
                        .init(color: .clear, location: 0.73),
                        .init(color: .black.opacity(0.30), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea(.container, edges: extendsVideo ? .all : [])
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .allowsHitTesting(!showingOverlay)
        .accessibilityHidden(showingOverlay)
        .overlay {
            if showingVideoOptions {
                DriveItemSheet(item: .file(movie), pausePlayback: session.pause,
                               closeVideoOptions: { showingVideoOptions = false })
                    .transition(.opacity)
            } else if showingVideoRates {
                DriveVideoSpeedOverlay(playback: session.playback) { showingVideoRates = false }
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showingOverlay)
    }

    private func playbackFeedback(_ movie: PracticeRecording, next: PracticeRecording?,
                                  overVideo: Bool = false, compact: Bool = false) -> some View {
        DrivePlaybackFeedback(playback: session.playback, movie: movie,
                              hasFinished: session.hasFinished,
                              playNext: next.map { file in { session.select(file) } },
                              retry: { session.retry(movie) },
                              overVideo: overVideo, compact: compact)
    }

    private func immersiveHeader(_ movie: PracticeRecording) -> some View {
        HStack(spacing: 10) {
            minimizeButton(overVideo: true)

            Text(verbatim: movie.displayName)
                .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(1).truncationMode(.middle)
                .shadow(color: .black.opacity(0.68), radius: 3, y: 1)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            Button { showingVideoOptions = true } label: {
                Glyph(symbol: .driveMore, size: 17, tint: .white)
            }
            .buttonStyle(DriveVideoButtonStyle())
            .accessibilityLabel("File options")
            .accessibilityFocused($videoOptionsFocused)
            .onChange(of: showingVideoOptions) { wasShowing, isShowing in
                if wasShowing && !isShowing { videoOptionsFocused = true }
            }
        }
    }

    private func playerHeader(_ movie: PracticeRecording, showsFileTitle: Bool,
                              locateCurrent: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            minimizeButton().layoutPriority(1)
            if showsFileTitle {
                fileTitle(movie)
            } else {
                Spacer(minLength: 0)
            }
            if let locateCurrent {
                IconButton(symbol: .driveList, label: "Locate current file", glass: true, action: locateCurrent)
                    .fixedSize()
            }
            IconButton(symbol: .driveMore, label: "File options", glass: true) { fileOptions = movie }
                .fixedSize()
        }
    }

    @ViewBuilder
    private func minimizeButton(overVideo: Bool = false) -> some View {
        if overVideo {
            Button(action: minimizePlayer) {
                Glyph(symbol: .back, size: 16, tint: .white)
            }
            .buttonStyle(DriveVideoButtonStyle())
            .accessibilityLabel("Back to mini player")
        } else {
            labeledMinimizeButton
        }
    }

    private func minimizePlayer() {
        session.checkpoint()
        session.expanded = false
    }

    private var labeledMinimizeButton: some View {
        let arrow = Glyph(symbol: .back, size: 16, tint: GlamoStyle.accent)
            .rotationEffect(.degrees(layoutDirection == .leftToRight ? 0 : 180))
            .accessibilityHidden(true)
        return Button(action: minimizePlayer) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    arrow
                    LocalizedText("Back to mini player")
                        .font(.glam(.footnote, weight: .semibold))
                        .fixedSize()
                }
                .padding(.horizontal, 12)
                arrow
            }
            .foregroundStyle(GlamoStyle.accent)
            .padding(.vertical, 4)
            .frame(minWidth: 44, minHeight: 44)
            .glamoGlass(in: Capsule(), tint: GlamoStyle.paperMuted, interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Back to mini player")
    }

    private func fileTitle(_ movie: PracticeRecording) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: movie.displayName)
                .font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let folder = library.folders.first(where: { $0.id == movie.folderID }) {
                Text(verbatim: folder.name)
            } else {
                LocalizedText("On this device")
            }
        }
        .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DrivePlayerQueue: View {
    @ObservedObject var playback: PlaybackController
    @Binding var isExpanded: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    let files: [PracticeRecording]
    let current: PracticeRecording
    let select: (PracticeRecording) -> Void
    let locateCurrent: () -> Void

    private var currentStatus: String {
        if playback.error != nil { return "Playback failed" }
        if playback.isLoading { return "Loading…" }
        return playback.isPlaying ? "Now playing" : "Current file"
    }

    var body: some View {
        let status = currentStatus
        let summary = VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: current.displayName)
                .font(.glam(.subheadline, weight: .medium)).foregroundStyle(GlamoStyle.ink)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2).truncationMode(.middle)
            LocalizedText(status)
                .font(.glam(.footnote, weight: .semibold)).foregroundStyle(GlamoStyle.accent)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        let locateButton = Button(action: locateCurrent) {
            LocalizedText("Locate current file")
        }
        .buttonStyle(CompactActionStyle())

        return VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        LocalizedText("Play queue").font(.glam(.headline))
                        if !isExpanded {
                            summary
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Glyph(symbol: .back, size: 13, tint: GlamoStyle.accent)
                        .rotationEffect(.degrees(isExpanded ? 90 : -90))
                        .accessibilityHidden(true)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityValue(Text(LocalizedStringKey(isExpanded ? "Expanded" : "Collapsed")))
            if isExpanded {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        summary
                        locateButton
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        summary
                        locateButton
                    }
                }
                Divider().overlay(GlamoStyle.line).allowsHitTesting(false)
                LazyVStack(spacing: 4) {
                    ForEach(files) { file in
                        let active = file.id == current.id
                        Button { select(file) } label: {
                            DriveQueueRow(file: file, currentStatus: active ? status : nil)
                        }
                        .buttonStyle(PressStyle()).accessibilityAddTraits(active ? .isSelected : [])
                        .id(file.id)
                    }
                }
            }
        }
        .padding(12)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.surface)
    }
}

private struct DriveQueueRow: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var measuredDuration: Double?
    let file: PracticeRecording
    let currentStatus: String?

    private var storedDuration: Double? {
        [file.duration, file.viewing?.duration].compactMap { $0 }.first { $0.isFinite && $0 > 0 }
    }

    var body: some View {
        let active = currentStatus != nil
        let duration = (storedDuration ?? measuredDuration).map(durationLabel)
            ?? L10n.text("Unavailable", language: AppLanguage.from(locale))
        HStack(alignment: .top, spacing: 10) {
            if !typeSize.isAccessibilitySize {
                DriveThumbnail(movie: file).frame(width: 56, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                if let currentStatus {
                    LocalizedText(currentStatus)
                        .font(.glam(.footnote, weight: .semibold)).foregroundStyle(GlamoStyle.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: file.displayName)
                    .font(.glam(.subheadline, weight: active ? .semibold : .regular))
                    .foregroundStyle(GlamoStyle.ink)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                LocalizedText("Duration · %@", duration)
                    .font(.glam(.footnote)).monospacedDigit().foregroundStyle(GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(minHeight: 48, alignment: .leading)
        .background(active ? GlamoStyle.paperMuted : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .task(id: file.id) {
            measuredDuration = nil
            guard storedDuration == nil else { return }
            let asset = AVURLAsset(url: library.url(for: file))
            guard let seconds = try? await asset.load(.duration).seconds,
                  !Task.isCancelled, seconds.isFinite, seconds > 0 else { return }
            measuredDuration = seconds
        }
    }
}

private struct DrivePlayerPicture: View {
    @ObservedObject var playback: PlaybackController
    let isAudio: Bool
    var immersive = false

    var body: some View {
        Color.black.overlay {
            if isAudio {
                Glyph(symbol: .sound, size: 50, tint: GlamoStyle.paperMuted)
            } else {
                GeometryReader { canvas in
                    VideoSurface(player: playback.player, fill: false, preferredGravity: gravity(in: canvas.size))
                }
            }
        }
        .clipped()
    }

    private func gravity(in canvas: CGSize) -> AVLayerVideoGravity? {
        guard immersive, canvas.width > 0, canvas.height > 0 else { return nil }
        return .resizeAspectFill
    }
}

private struct DrivePlaybackFeedback: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    let movie: PracticeRecording
    let hasFinished: Bool
    let playNext: (() -> Void)?
    let retry: () -> Void
    let overVideo: Bool
    let compact: Bool

    var body: some View {
        if let error = playback.error {
            errorNotice(error)
        } else if !playback.isLoading && hasFinished && !playback.intendsPlayback {
            completionNotice
        } else {
            VStack(spacing: 8) {
                if overVideo { DrivePlaybackControls(playback: playback, overVideo: true, compact: compact) }
                if playback.isLoading { loadingNotice }
            }
        }
    }

    private var completionNotice: some View {
        let replayButton = Button {
            playback.seek(0)
            playback.play()
        } label: {
            LocalizedText("Play again")
        }
        .buttonStyle(GlamoActionStyle(primary: playNext == nil))

        return VStack(alignment: .leading, spacing: 12) {
            LocalizedText("Playback finished")
                .font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let playNext {
                let nextButton = Button(action: playNext) {
                    LocalizedText("Next")
                }
                .buttonStyle(GlamoActionStyle())
                .accessibilityLabel("Next file")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        nextButton
                        replayButton
                    }
                    VStack(spacing: 8) {
                        nextButton
                        replayButton
                    }
                }
            } else {
                replayButton
            }
        }
        .frame(maxWidth: 400, alignment: .leading)
        .padding(14)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: GlamoStyle.surface, mediaBackdrop: true)
    }

    private var loadingNotice: some View {
        let animates = !reduceMotion && phase == .active
        return VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: movie.displayName)
                .font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 2).truncationMode(.middle)
            HStack(spacing: 6) {
                AssetMask(name: "GlamoLoadingMark", tint: GlamoStyle.accent)
                    .frame(width: 22, height: 22)
                    .phaseAnimator([false, true]) { content, dimmed in
                        content.opacity(animates && dimmed ? 0.45 : 1)
                    } animation: { _ in
                        animates ? .easeInOut(duration: 0.6) : nil
                    }
                    .accessibilityHidden(true)
                LocalizedText("Loading…")
                    .font(.glam(.footnote, weight: .semibold))
                    .foregroundStyle(GlamoStyle.secondary)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 340, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 14), tint: GlamoStyle.paper, mediaBackdrop: true)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func errorNotice(_ error: String) -> some View {
        let details = VStack(alignment: .leading, spacing: 5) {
            LocalizedText("Playback failed")
                .font(.glam(.headline)).foregroundStyle(GlamoStyle.danger)
                .accessibilityAddTraits(.isHeader)
            LocalizedText(error)
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

        let retryButton = Button(action: retry) {
            LocalizedText("Retry")
        }
        .buttonStyle(GlamoActionStyle(fillsWidth: false))

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                details
                Spacer(minLength: 0)
                retryButton
            }
            VStack(alignment: .leading, spacing: 12) {
                details
                retryButton
            }
        }
        .frame(maxWidth: 400, alignment: .leading)
        .padding(14)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: GlamoStyle.surface, mediaBackdrop: true)
    }
}

private struct DriveTransport: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Binding var scrubbing: Bool
    let previous: PracticeRecording?
    let next: PracticeRecording?
    let open: (PracticeRecording) -> Void
    let cinema: Bool
    let toggleCinema: () -> Void
    let compactRail: Bool
    var stacksVideoActions = false
    var showingVideoRates: Binding<Bool>?

    var body: some View {
        if cinema {
            let layout = compactRail ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                videoActions.layoutPriority(1)
                progressPanel
            }
        } else {
            VStack(spacing: compactRail ? 8 : 12) {
                progressPanel
                DrivePlaybackControls(playback: playback)
                fileNavigation
                displayControls
            }
            .padding(.horizontal, compactRail ? 10 : 14).padding(.vertical, compactRail ? 8 : 12)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var progressPanel: some View {
        let control = PlayerProgressControl(playback: playback, timeline: playback.timeline, enabled: !playback.isLoading,
                                            canResume: phase == .active, scrubbing: $scrubbing,
                                            tint: cinema ? Color(red: 0.15, green: 0.55, blue: 1) : GlamoStyle.playbackProgress,
                                            showsInlineTimes: true, overVideo: cinema)
        if cinema {
            control.padding(.horizontal, 14)
                .modifier(DriveVideoGlass(shape: RoundedRectangle(cornerRadius: 22).inset(by: 4)))
        } else {
            control.padding(.horizontal, 10).padding(.top, 8)
                .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var videoActions: some View {
        let layout = stacksVideoActions ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 0))
                                        : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            if previous != nil || next != nil {
                HStack(spacing: 4) {
                    fileButton(previous, forward: false).fixedSize()
                    fileButton(next, forward: true).fixedSize()
                }
            }
            if !compactRail && !stacksVideoActions { Spacer(minLength: 0) }
            HStack(spacing: 4) {
                DriveSpeedButton(playback: playback, compact: true, showingVideoRates: showingVideoRates).fixedSize()
                Button(action: toggleCinema) {
                    Glyph(symbol: .driveExpand, size: 17, tint: .white)
                }
                .buttonStyle(DriveVideoButtonStyle())
                .accessibilityLabel("Exit full screen")
            }
        }
        .frame(maxWidth: compactRail ? nil : .infinity, alignment: .trailing)
    }

    private var fileNavigation: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                fileButton(previous, forward: false)
                fileButton(next, forward: true)
            }
            VStack(spacing: 8) {
                fileButton(previous, forward: false)
                fileButton(next, forward: true)
            }
        }
    }

    private func fileButton(_ file: PracticeRecording?, forward: Bool) -> some View {
        let pointsRight = forward ? layoutDirection == .leftToRight : layoutDirection == .rightToLeft
        let tint = cinema ? Color.white : (file == nil ? GlamoStyle.secondary : GlamoStyle.accent)
        let arrow = Glyph(symbol: .back, size: 13, tint: tint)
            .rotationEffect(.degrees((cinema ? forward : pointsRight) ? 180 : 0))
        let button = Button {
            if let file { open(file) }
        } label: {
            if cinema {
                arrow
            } else {
                HStack(spacing: 6) {
                    if !forward { arrow }
                    LocalizedText(forward ? "Next" : "Previous")
                        .font(.glam(.footnote, weight: .semibold))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    if forward { arrow }
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .background(file == nil ? GlamoStyle.surface : GlamoStyle.paperMuted,
                            in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
        }
        return Group {
            if cinema { button.buttonStyle(DriveVideoButtonStyle()) }
            else { button.buttonStyle(PressStyle()) }
        }
        .disabled(file == nil)
        .accessibilityLabel(Text(LocalizedStringKey(forward ? "Next file" : "Previous file")))
    }

    private var displayControls: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                          : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            DriveSpeedButton(playback: playback, compact: compactRail)
            fullScreenButton
        }
    }

    private var fullScreenButton: some View {
        Button(action: toggleCinema) {
            HStack(spacing: 6) {
                Glyph(symbol: .driveExpand, size: 15, tint: GlamoStyle.accent)
                LocalizedText("Full screen").font(.glam(.footnote, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(GlamoStyle.accent)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .frame(minWidth: 44, minHeight: 44)
            .background(GlamoStyle.paperMuted, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct DrivePlaybackControls: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.layoutDirection) private var layoutDirection
    var overVideo = false
    var compact = false

    init(playback: PlaybackController, overVideo: Bool = false, compact: Bool = false) {
        _playback = ObservedObject(wrappedValue: playback)
        self.overVideo = overVideo
        self.compact = compact
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(skipSize: overVideo ? (compact ? 46 : 56) : nil,
                playSize: overVideo ? (compact ? 60 : 72) : nil,
                spacing: overVideo && !compact ? 16 : 10)
            VStack(spacing: 6) {
                DrivePlayButton(playback: playback, videoDiameter: overVideo ? 56 : nil).fixedSize()
                HStack(spacing: 8) {
                    skip(-10, diameter: overVideo ? 44 : nil)
                    skip(10, diameter: overVideo ? 44 : nil)
                }
            }
        }
        .environment(\.layoutDirection, overVideo ? .leftToRight : layoutDirection)
    }

    private func row(skipSize: CGFloat?, playSize: CGFloat?, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            skip(-10, diameter: skipSize)
            DrivePlayButton(playback: playback, videoDiameter: playSize).fixedSize()
            skip(10, diameter: skipSize)
        }
    }

    private func skip(_ seconds: Double, diameter: CGFloat?) -> some View {
        let button = Button { playback.seek(playback.timeline.elapsed + seconds) } label: {
            Group {
                if overVideo {
                    AssetMask(name: "PlayerRewind", tint: .white)
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(seconds > 0 ? 180 : 0))
                } else {
                    Text(verbatim: seconds < 0 ? "−10" : "+10")
                        .font(.glam(.caption, weight: .semibold)).monospacedDigit().fixedSize()
                }
            }
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .foregroundStyle(overVideo ? .white : GlamoStyle.secondary)
        }
        return Group {
            if let diameter { button.buttonStyle(DriveVideoButtonStyle(diameter: diameter)) }
            else { button.buttonStyle(PressStyle()) }
        }
        .disabled(playback.isLoading || playback.error != nil)
        .accessibilityLabel(Text(LocalizedStringKey(seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds")))
    }

}

private struct DrivePlayButton: View {
    @ObservedObject var playback: PlaybackController
    var videoDiameter: CGFloat? = nil

    var body: some View {
        let symbol: GlamoGlyph = playback.intendsPlayback ? .pause : .play
        let label = playback.intendsPlayback ? "Pause" : "Play"
        Group {
            if let videoDiameter {
                Button { playback.toggle() } label: {
                    Glyph(symbol: symbol, size: 26, tint: .white)
                }
                .buttonStyle(DriveVideoButtonStyle(diameter: videoDiameter, prominent: true))
                .accessibilityLabel(LocalizedStringKey(label))
            } else {
                IconButton(symbol: symbol, label: label, tint: GlamoStyle.onAccent) { playback.toggle() }
                    .background(playback.error == nil ? GlamoStyle.accent : GlamoStyle.controlLine, in: Circle())
            }
        }
        .disabled(playback.error != nil)
    }
}

struct DriveVideoButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var diameter: CGFloat = 40
    var prominent = false

    init(diameter: CGFloat = 40, prominent: Bool = false) {
        self.diameter = diameter
        self.prominent = prominent
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: diameter, minHeight: diameter)
            .modifier(DriveVideoGlass(shape: Capsule(), prominent: prominent))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.76 : 1))
    }
}

struct DriveVideoGlass<Surface: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: Surface
    var prominent = false
    var shade = 0.08

    init(shape: Surface, prominent: Bool = false, shade: Double = 0.08) {
        self.shape = shape
        self.prominent = prominent
        self.shade = shade
    }

    func body(content: Content) -> some View {
        content.background {
            shape.fill(.ultraThinMaterial)
                .overlay { shape.fill(.black.opacity(reduceTransparency ? 1 : shade)) }
                .overlay { shape.fill(.white.opacity(prominent ? 0.24 : 0.12)) }
                .environment(\.colorScheme, .light)
                .overlay { shape.strokeBorder(.white.opacity(prominent ? 0.36 : 0.24), lineWidth: 1) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct DriveSpeedButton: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @AccessibilityFocusState private var speedFocused: Bool
    @State private var showingRates = false
    let compact: Bool
    var showingVideoRates: Binding<Bool>?
    private var overVideo: Bool { showingVideoRates != nil }
    private var usesSingleColumn: Bool { typeSize >= .xxLarge }

    init(playback: PlaybackController, compact: Bool, showingVideoRates: Binding<Bool>? = nil) {
        _playback = ObservedObject(wrappedValue: playback)
        self.compact = compact
        self.showingVideoRates = showingVideoRates
    }

    var body: some View {
        let button = Button {
            if let showingVideoRates {
                showingVideoRates.wrappedValue = true
            } else {
                showingRates.toggle()
            }
        } label: {
            if overVideo {
                rateLabel.padding(.horizontal, 10).padding(.vertical, 4)
            } else {
                HStack(spacing: 6) {
                    if !compact {
                        LocalizedText("Playback speed")
                            .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    rateLabel
                }
                .padding(.horizontal, compact ? 6 : 11).padding(.vertical, 6)
                .frame(minWidth: 44, minHeight: 44)
                .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
        }
        return Group {
            if overVideo {
                button.buttonStyle(DriveVideoButtonStyle())
            } else {
                button.buttonStyle(PressStyle())
                    .driveDialog(isPresented: $showingRates) { speedPicker }

            }
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(Text(verbatim: driveRateText(playback.speed, locale: locale)))
        .accessibilityFocused($speedFocused)
        .onChange(of: showingVideoRates?.wrappedValue) { wasShowing, isShowing in
            if wasShowing == true && isShowing == false { speedFocused = true }
        }
    }

    private var rateLabel: some View {
        Text(verbatim: driveRateText(playback.speed, locale: locale))
            .font(.glam(overVideo ? .caption : .footnote, weight: .semibold)).monospacedDigit()
            .foregroundStyle(overVideo ? .white : GlamoStyle.accent)
            .environment(\.layoutDirection, .leftToRight)
            .fixedSize()
    }

    private var speedPicker: some View {
        ViewThatFits(in: .vertical) {
            speedPickerContent
            ScrollView { speedPickerContent }
                .scrollBounceBehavior(.basedOnSize)
        }
        .padding(14)
        .frame(idealWidth: usesSingleColumn ? 312 : 270, maxWidth: 320)
        .foregroundStyle(GlamoStyle.ink)
    }

    private var speedPickerContent: some View {
        let columns = [GridItem(usesSingleColumn ? .flexible() : .adaptive(minimum: 104), spacing: 8)]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    LocalizedText("Playback speed")
                        .font(.glam(.headline)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: driveRateText(playback.speed, locale: locale))
                        .font(.glam(.title2, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(GlamoStyle.accent)
                        .environment(\.layoutDirection, .leftToRight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                IconButton(symbol: .close, label: "Close", tint: GlamoStyle.secondary, glass: true) { showingRates = false }
            }
            Divider().overlay(GlamoStyle.line).allowsHitTesting(false)
            DriveSpeedChoices(playback: playback, columns: columns) { showingRates = false }
        }
    }
}

struct DriveVideoSpeedOverlay: View {
    @ObservedObject var playback: PlaybackController
    @ScaledMetric(relativeTo: .subheadline) private var columnWidth: CGFloat = 116
    let close: () -> Void

    init(playback: PlaybackController, close: @escaping () -> Void) {
        _playback = ObservedObject(wrappedValue: playback)
        self.close = close
    }

    var body: some View {
        DriveVideoBottomOverlay(title: "Playback speed", columnWidth: columnWidth, close: close) { columns in
            let choices = DriveSpeedChoices(playback: playback, columns: columns, overVideo: true, close: close)
            return ViewThatFits(in: .vertical) {
                choices.fixedSize(horizontal: false, vertical: true)
                ScrollViewReader { scroll in
                    ScrollView { choices }
                        .scrollBounceBehavior(.basedOnSize)
                        .onAppear { scroll.scrollTo(playback.speed, anchor: .center) }
                }
            }
        }
    }
}

struct DriveVideoBottomOverlay<Content: View>: View {
    @AccessibilityFocusState private var headingFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let columnWidth: CGFloat
    let close: () -> Void
    let content: ([GridItem]) -> Content

    var body: some View {
        GeometryReader { canvas in
            let short = canvas.size.height < 420
            let width: CGFloat = short ? 460 : 360
            let fitsColumns = short && !typeSize.isAccessibilitySize && min(width, canvas.size.width - 32) >= 2 * columnWidth + 32
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: fitsColumns ? 2 : 1)
            DriveFloatingDialog(maxWidth: width, overVideo: true, close: close) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        LocalizedText(title).driveFont(17, relativeTo: .headline, weight: .semibold)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                        IconButton(symbol: .close, label: "Close", tint: DriveStyle.ink, glyphSize: 14, action: close)
                            .keyboardShortcut(.cancelAction)
                    }
                    content(columns)
                }.padding(14).foregroundStyle(DriveStyle.ink).preferredColorScheme(.light)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .onAppear { headingFocused = true }
    }
}

private struct DriveSpeedChoices: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.locale) private var locale
    let columns: [GridItem]
    var overVideo = false
    let close: () -> Void
    private let rates = PlaybackPreferences.rates

    var body: some View {
        LazyVGrid(columns: columns, spacing: overVideo ? 2 : 8) {
            ForEach(rates, id: \.self) { speed in
                let selected = speed == playback.speed
                let title = driveRateText(speed, locale: locale)
                Button {
                    playback.setSpeed(speed)
                    close()
                } label: {
                    if overVideo {
                        videoChoice(title, selected: selected)
                    } else {
                        standardChoice(title, selected: selected)
                    }
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
                .id(speed)
            }
        }
    }

    private func standardChoice(_ title: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.glam(.subheadline, weight: .semibold)).monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
            if selected {
                LocalizedText("Selected").font(.glam(.caption, weight: .medium))
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        .foregroundStyle(selected ? GlamoStyle.onAccent : GlamoStyle.ink)
        .background(selected ? GlamoStyle.accent : GlamoStyle.paper,
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private func videoChoice(_ title: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: title).driveFont(16, relativeTo: .subheadline, weight: selected ? .semibold : .regular)
                .monospacedDigit().environment(\.layoutDirection, .leftToRight)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Circle().fill(selected ? DriveStyle.accent : .clear)
                .overlay { Circle().strokeBorder(selected ? DriveStyle.accent : DriveStyle.secondary.opacity(0.35)) }
                .frame(width: 18, height: 18).accessibilityHidden(true)
        }
        .foregroundStyle(selected ? DriveStyle.accent : DriveStyle.ink)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(selected ? DriveStyle.accent.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

}

func driveRateText(_ speed: Float, locale: Locale) -> String {
    speed.formatted(.number.precision(.fractionLength(0...2)).locale(locale)) + "×"
}

struct DrivePlayerTimes: View {
    @ObservedObject var timeline: PlaybackTimeline
    var compact = false

    var body: some View {
        let elapsed = durationLabel(timeline.elapsed)
        let total = durationLabel(timeline.duration)
        Group {
            if compact {
                Text(verbatim: "\(elapsed) / \(total)")
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .font(.glam(.caption2, weight: .medium))
            } else {
                HStack(spacing: 8) {
                    Text(verbatim: elapsed).foregroundStyle(GlamoStyle.ink)
                    Spacer(minLength: 0)
                    Text(verbatim: total)
                }
                .font(.glam(.footnote, weight: .medium))
            }
        }
        .monospacedDigit().foregroundStyle(GlamoStyle.secondary)
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct DriveMiniPlayer: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var inlineWidth: CGFloat = 408
    @ScaledMetric(relativeTo: .footnote) private var rateLabelWidth: CGFloat = 42
    @State private var width: CGFloat = 0
    let movie: PracticeRecording
    let expand: () -> Void
    let close: () -> Void

    var body: some View {
        let inline = width >= inlineWidth && typeSize < .xxLarge
        let showsPreview = !typeSize.isAccessibilitySize && width >= (inline ? 480 : 272)
        let showsExpandTitle = !inline && width >= 300 && typeSize < .xxLarge
        let layout = inline ? AnyLayout(HStackLayout(spacing: 12))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return layout {
            VStack(alignment: .leading, spacing: 5) {
                expandButton(showsPreview: showsPreview, showsTitle: showsExpandTitle)
                DriveMiniProgress(timeline: playback.timeline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls(inline: inline).layoutPriority(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: 560)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.paper, mediaBackdrop: true)
    }

    private func expandButton(showsPreview: Bool, showsTitle: Bool) -> some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                if showsPreview { preview }
                Text(verbatim: movie.displayName)
                    .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 3) {
                    Glyph(symbol: .driveExpand, size: 18, tint: GlamoStyle.accent)
                    if showsTitle {
                        LocalizedText("Full screen").font(.glam(.caption2, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 84)
                    }
                }
                .foregroundStyle(GlamoStyle.accent)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .frame(minWidth: 44, minHeight: 44)
                .background(GlamoStyle.paperMuted, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(Text(verbatim: movie.displayName))
        .accessibilityHint("Open player")
    }

    private var preview: some View {
        Group {
            if movie.isAudio {
                Glyph(symbol: .sound, size: 18, tint: GlamoStyle.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GlamoStyle.paperMuted)
            } else {
                VideoSurface(player: playback.player, fill: false).background(.black)
            }
        }
        .frame(width: 48, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func controls(inline: Bool) -> some View {
        // Reserve the two fixed icon targets, the rate label and the card insets.
        let fitsHorizontally = width == 0 || width >= 142 + rateLabelWidth
        let layout = fitsHorizontally ? AnyLayout(HStackLayout(spacing: 6))
                                     : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        return layout {
            DrivePlayButton(playback: playback).fixedSize()
            DriveSpeedButton(playback: playback, compact: true).fixedSize()
            if !inline && fitsHorizontally { Spacer(minLength: 0) }
            IconButton(symbol: .close, label: "Close player", tint: GlamoStyle.secondary, action: close).fixedSize()
        }
        .frame(maxWidth: inline ? nil : .infinity, alignment: .leading)
    }
}

private struct DriveMiniProgress: View {
    @ObservedObject var timeline: PlaybackTimeline

    var body: some View {
        let position = "\(durationLabel(timeline.elapsed)) / \(durationLabel(timeline.duration))"
        return VStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                DrivePlayerTimes(timeline: timeline)
                Text(verbatim: position)
                    .font(.glam(.footnote, weight: .medium)).monospacedDigit()
                    .foregroundStyle(GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DriveMeter(value: timeline.duration > 0 ? timeline.elapsed / timeline.duration : 0,
                       tint: GlamoStyle.playbackProgress, thickness: 4)
                .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text(verbatim: position))
    }
}

func driveHasReservedRegion(_ container: GeometryProxy) -> Bool {
    guard #available(iOS 27.1, *) else { return false }
    let bounds = CGRect(origin: .zero, size: container.size)
    let regions = container.reservedRegions(kind: .division) + container.reservedRegions(kind: .occlusion)
    return regions.contains { $0.isActive && $0.frame.intersects(bounds) }
}

func drivePaneMargins(in container: GeometryProxy, includesHorizontalFold: Bool = false) -> EdgeInsets {
    guard #available(iOS 27.1, *) else { return EdgeInsets() }
    let bounds = CGRect(origin: .zero, size: container.size)
    let divisions = container.reservedRegions(kind: .division).lazy.filter(\.isActive)
        .map { $0.frame.intersection(bounds) }.filter { !$0.isNull }
    var margins = EdgeInsets()
    if let fold = divisions.first(where: { $0.height > $0.width && $0.minX > 0 && $0.maxX < bounds.maxX }) {
        let leadingWidth = fold.minX
        let trailingWidth = bounds.maxX - fold.maxX
        if leadingWidth >= trailingWidth { margins.trailing = bounds.maxX - fold.minX }
        else { margins.leading = fold.maxX }
    }
    if includesHorizontalFold,
       let fold = divisions.first(where: { $0.width > $0.height && $0.minY > 0 && $0.maxY < bounds.maxY }) {
        let upperHeight = fold.minY
        let lowerHeight = bounds.maxY - fold.maxY
        if upperHeight >= lowerHeight { margins.bottom = bounds.maxY - fold.minY }
        else { margins.top = fold.maxY }
    }
    return margins
}
