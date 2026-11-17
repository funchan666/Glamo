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
        playback.load(library.url(for: file), autoplay: false)
        if let position = file.viewing, position.seconds > 0, position.seconds < position.duration - 1 {
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
    @ObservedObject var session: DrivePlaybackSession
    @State private var fileOptions: PracticeRecording?
    @State private var showingQueue = true
    @State private var cinema = false
    @State private var scrubbing = false
    @State private var headerHeight: CGFloat = 48
    @State private var controlsHeight: CGFloat = 152

    var body: some View {
        GeometryReader { container in
            let pane = drivePaneMargins(in: container, includesHorizontalFold: true)
            let width = container.size.width - pane.leading - pane.trailing
            let paneHeight = container.size.height - pane.top - pane.bottom
            let files = session.files(in: library)
            let allowsColumns = typeSize < .xxLarge && !driveHasReservedRegion(container)
            let controlsBesideVideo = allowsColumns && width >= 640 && paneHeight < 420
            let queueBesideVideo = allowsColumns && width >= 780 && !controlsBesideVideo && !cinema && files.count > 1
            let titleInHeader = width >= 560 && typeSize < .xxLarge
            let railWidth: CGFloat? = controlsBesideVideo ? min(340, width * 0.43) : nil
            let topPadding: CGFloat = 8
            let bottomPadding: CGFloat = cinema ? 8 : 20
            let availableHeight = max(0, paneHeight - headerHeight - topPadding - bottomPadding)
            let layout = queueBesideVideo ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            let stageHeight = if controlsBesideVideo {
                max(128, availableHeight)
            } else if cinema {
                max(128, availableHeight - controlsHeight - 12)
            } else {
                max(128, min(availableHeight * 0.58, width * (queueBesideVideo ? 0.42 : 0.68)))
            }
            if let movie = library.movies.first(where: { $0.id == session.currentID }) {
                let showsQueue = !cinema && files.count > 1
                ScrollViewReader { scroll in
                    let locateCurrent = { scroll.scrollTo(movie.id) }
                    let locateInHeader = showsQueue && showingQueue && width >= 260

                    VStack(spacing: 0) {
                        playerHeader(movie, showsFileTitle: titleInHeader, locateCurrent: locateInHeader ? locateCurrent : nil)
                            .pageHorizontalMargins().padding(.vertical, 6)
                            .frame(maxWidth: 1100).frame(maxWidth: .infinity)
                            .background(GlamoStyle.background, ignoresSafeAreaEdges: .top)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if !titleInHeader { fileTitle(movie) }
                                layout {
                                    playbackPanel(movie, files: files, height: stageHeight, railWidth: railWidth)
                                    if showsQueue {
                                        DrivePlayerQueue(playback: session.playback, isExpanded: $showingQueue,
                                                         files: files, current: movie, select: session.select,
                                                         locateCurrent: locateCurrent)
                                            .frame(maxWidth: queueBesideVideo ? 300 : .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .pageHorizontalMargins()
                            .padding(.top, topPadding).padding(.bottom, bottomPadding)
                            .frame(maxWidth: cinema && railWidth == nil ? .infinity : 1100).frame(maxWidth: .infinity)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                }
                .padding(pane)
            }
        }
        .glamoScreenBackground()
        .sheet(item: $fileOptions) { movie in
            DriveItemSheet(item: .file(movie), pausePlayback: session.pause)
        }
    }

    private func playbackPanel(_ movie: PracticeRecording, files: [PracticeRecording], height: CGFloat,
                               railWidth: CGFloat?) -> some View {
        let next = session.neighbor(1, in: files)
        let layout = railWidth == nil ? AnyLayout(VStackLayout(spacing: 12))
                                      : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            DrivePlayerStage(playback: session.playback, movie: movie, height: height, hasFinished: session.hasFinished,
                             playNext: next.map { file in { session.select(file) } }, retry: { session.retry(movie) })
                .clipShape(RoundedRectangle(cornerRadius: 20))
            DriveTransport(playback: session.playback, scrubbing: $scrubbing,
                           previous: session.neighbor(-1, in: files), next: next,
                           open: session.select, cinema: cinema, toggleCinema: { cinema.toggle() }, compactRail: railWidth != nil)
                .frame(maxWidth: railWidth ?? .infinity)
                .glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.paper, mediaBackdrop: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
        }
        .frame(maxWidth: .infinity)
    }

    private func playerHeader(_ movie: PracticeRecording, showsFileTitle: Bool,
                              locateCurrent: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            minimizeButton.layoutPriority(1)
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

    private var minimizeButton: some View {
        let arrow = Glyph(symbol: .back, size: 16, tint: GlamoStyle.accent)
            .rotationEffect(.degrees(layoutDirection == .leftToRight ? 0 : 180))
            .accessibilityHidden(true)
        return Button {
            session.checkpoint()
            session.expanded = false
        } label: {
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

private struct DrivePlayerStage: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    let movie: PracticeRecording
    let height: CGFloat
    let hasFinished: Bool
    let playNext: (() -> Void)?
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.black.overlay {
                if movie.isAudio {
                    Glyph(symbol: .sound, size: 50, tint: GlamoStyle.paperMuted)
                } else {
                    VideoSurface(player: playback.player, fill: false)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)

            if let error = playback.error {
                errorNotice(error).padding(12)
            } else if playback.isLoading {
                loadingNotice.padding(12)
            } else if hasFinished && !playback.intendsPlayback {
                completionNotice.padding(12)
            }
        }
        .background(.black)
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

    var body: some View {
        VStack(spacing: compactRail ? 8 : 12) {
            progressPanel
            playbackControls
            fileNavigation
            displayControls
        }
        .padding(.horizontal, compactRail ? 10 : 14).padding(.vertical, compactRail ? 8 : 12)
        .frame(maxWidth: .infinity)
    }

    private var progressPanel: some View {
        PlayerProgressControl(playback: playback, timeline: playback.timeline, enabled: !playback.isLoading,
                              canResume: phase == .active, scrubbing: $scrubbing, tint: GlamoStyle.playbackProgress,
                              showsInlineTimes: true)
            .padding(.horizontal, 10).padding(.top, 8)
            .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var playbackControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                skip(-10)
                DrivePlayButton(playback: playback).fixedSize()
                skip(10)
            }
            VStack(spacing: 6) {
                DrivePlayButton(playback: playback).fixedSize()
                HStack(spacing: 8) {
                    skip(-10)
                    skip(10)
                }
            }
        }
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
        let tint = file == nil ? GlamoStyle.secondary : GlamoStyle.accent
        let arrow = Glyph(symbol: .back, size: 13, tint: tint)
            .rotationEffect(.degrees(pointsRight ? 180 : 0))
        return Button {
            if let file { open(file) }
        } label: {
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
        .buttonStyle(PressStyle()).disabled(file == nil)
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
        let title = cinema ? "Exit full screen" : "Full screen"
        let foreground = cinema ? GlamoStyle.onAccent : GlamoStyle.accent
        return Button(action: toggleCinema) {
            HStack(spacing: 6) {
                Glyph(symbol: .driveExpand, size: 15, tint: foreground)
                LocalizedText(title).font(.glam(.footnote, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .frame(minWidth: 44, minHeight: 44)
            .background(cinema ? GlamoStyle.accent : GlamoStyle.paperMuted, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func skip(_ seconds: Double) -> some View {
        Button { playback.seek(playback.timeline.elapsed + seconds) } label: {
            Text(verbatim: seconds < 0 ? "−10" : "+10").font(.glam(.caption, weight: .semibold)).monospacedDigit()
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                .foregroundStyle(GlamoStyle.secondary)
        }.buttonStyle(PressStyle()).disabled(playback.isLoading || playback.error != nil)
            .accessibilityLabel(Text(LocalizedStringKey(seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds")))
    }
}

private struct DrivePlayButton: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        IconButton(symbol: playback.intendsPlayback ? .pause : .play,
                   label: playback.intendsPlayback ? "Pause" : "Play", tint: GlamoStyle.onAccent) { playback.toggle() }
            .disabled(playback.error != nil)
            .background(playback.error == nil ? GlamoStyle.accent : GlamoStyle.controlLine, in: Circle())
    }
}

private struct DriveSpeedButton: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @State private var showingRates = false
    let compact: Bool
    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    private var usesSingleColumn: Bool { typeSize >= .xxLarge }

    var body: some View {
        Button { showingRates.toggle() } label: {
            HStack(spacing: 6) {
                if !compact {
                    LocalizedText("Playback speed")
                        .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: rateText(playback.speed))
                    .font(.glam(.footnote, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(GlamoStyle.accent)
                    .environment(\.layoutDirection, .leftToRight)
                    .fixedSize()
            }
            .padding(.horizontal, compact ? 6 : 11).padding(.vertical, 6)
            .frame(minWidth: 44, minHeight: 44)
            .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Playback speed")
        .accessibilityValue(Text(verbatim: rateText(playback.speed)))
        .popover(isPresented: $showingRates) {
            speedPicker
                .presentationCompactAdaptation(horizontal: usesSingleColumn ? .sheet : .popover,
                                               vertical: .sheet)
                .presentationBackground(.regularMaterial)
        }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    LocalizedText("Playback speed")
                        .font(.glam(.headline)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: rateText(playback.speed))
                        .font(.glam(.title2, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(GlamoStyle.accent)
                        .environment(\.layoutDirection, .leftToRight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                IconButton(symbol: .close, label: "Close", tint: GlamoStyle.secondary, glass: true) { showingRates = false }
            }
            Divider().overlay(GlamoStyle.line).allowsHitTesting(false)
            rateChoices
        }
    }

    private var rateChoices: some View {
        let columns = [GridItem(usesSingleColumn ? .flexible() : .adaptive(minimum: 104), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(rates, id: \.self) { speed in
                let selected = speed == playback.speed
                Button {
                    playback.setSpeed(speed)
                    showingRates = false
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: rateText(speed))
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
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func rateText(_ speed: Float) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2)).locale(locale)) + "×"
    }
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
