import SwiftUI
import AVFoundation

@MainActor
final class DrivePlaybackSession: ObservableObject {
    let playback = PlaybackController()
    @Published private(set) var currentID: UUID?
    @Published var expanded = false
    private(set) var queue: [UUID] = []
    private weak var library: LibraryStore?
    private var started = false
    private var savedSeconds: Double?

    init() {
        playback.onEnd = { [weak self] in self?.finishFile() }
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
    @ObservedObject var session: DrivePlaybackSession
    @State private var fileOptions: PracticeRecording?
    @State private var showingQueue = true
    @State private var cinema = false
    @State private var scrubbing = false
    @State private var headerHeight: CGFloat = 48
    @State private var controlsHeight: CGFloat = 152

    var body: some View {
        GeometryReader { container in
            let pane = drivePaneMargins(in: container)
            let width = container.size.width - pane.leading - pane.trailing
            let wide = width >= 780 && !typeSize.isAccessibilitySize && !driveHasReservedRegion(container)
            let headerSpacing: CGFloat = 12
            let topPadding: CGFloat = 8
            let bottomPadding: CGFloat = cinema ? 4 : 24
            let layout = wide && !cinema ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                                         : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            let verticalGaps = headerSpacing + topPadding + bottomPadding
            let height = cinema
                ? max(128, container.size.height - headerHeight - controlsHeight - verticalGaps)
                : max(128, min(container.size.height * 0.55, width * (wide ? 0.42 : 0.68)))
            let files = session.files(in: library)
            if let movie = library.movies.first(where: { $0.id == session.currentID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: headerSpacing) {
                        playerHeader(movie)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                        layout {
                            playbackPanel(movie, files: files, height: height)
                            if !cinema, files.count > 1 {
                                queue(files).frame(maxWidth: wide ? 300 : .infinity, alignment: .leading)
                            }
                        }
                    }
                    .pageHorizontalMargins()
                    .padding(.top, topPadding).padding(.bottom, bottomPadding)
                    .frame(maxWidth: cinema ? .infinity : 1100).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(pane)
            }
        }
        .glamoScreenBackground()
        .sheet(item: $fileOptions) { movie in
            DriveItemSheet(item: .file(movie), pausePlayback: session.pause)
        }
    }

    private func playbackPanel(_ movie: PracticeRecording, files: [PracticeRecording], height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22)
        return VStack(spacing: 0) {
            DrivePlayerStage(playback: session.playback, movie: movie, height: height, retry: { session.retry(movie) })
            DriveTransport(playback: session.playback, scrubbing: $scrubbing,
                           previous: session.neighbor(-1, in: files), next: session.neighbor(1, in: files),
                           open: session.select, cinema: cinema, toggleCinema: { cinema.toggle() })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
        }
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .glamoGlass(in: shape, tint: GlamoStyle.paper, mediaBackdrop: true)
    }

    private func playerHeader(_ movie: PracticeRecording) -> some View {
        HStack(alignment: .center, spacing: 12) {
            IconButton(symbol: .back, label: "Minimize player", glass: true) {
                session.checkpoint()
                session.expanded = false
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: movie.displayName)
                    .font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let folder = library.folders.first(where: { $0.id == movie.folderID }) {
                    Text(verbatim: folder.name)
                } else {
                    LocalizedText("On this device")
                }
            }
            .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: .driveMore, label: "File options", glass: true) { fileOptions = movie }
        }
    }

    private func queue(_ files: [PracticeRecording]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showingQueue.toggle() } label: {
                HStack(spacing: 10) {
                    LocalizedText("Play queue").font(.glam(.headline))
                    Spacer(minLength: 0)
                    Glyph(symbol: .driveList, size: 17, tint: GlamoStyle.secondary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityValue(Text(LocalizedStringKey(showingQueue ? "Expanded" : "Collapsed")))
            if showingQueue {
                LazyVStack(spacing: 0) {
                    ForEach(files) { file in
                        let active = file.id == session.currentID
                        Button { session.select(file) } label: {
                            HStack(spacing: 11) {
                                DriveThumbnail(movie: file).frame(width: 60, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                Text(verbatim: file.displayName)
                                    .font(.glam(.subheadline, weight: active ? .semibold : .regular))
                                    .foregroundStyle(active ? GlamoStyle.accent : GlamoStyle.ink).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if active { Glyph(symbol: .play, size: 12, tint: GlamoStyle.accent) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(active ? GlamoStyle.paperMuted : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }.buttonStyle(PressStyle()).accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
        }
        .padding(12)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.surface)
    }
}

private struct DrivePlayerStage: View {
    @ObservedObject var playback: PlaybackController
    let movie: PracticeRecording
    let height: CGFloat
    let retry: () -> Void

    var body: some View {
        Color.black.overlay {
            if movie.isAudio {
                Glyph(symbol: .sound, size: 50, tint: GlamoStyle.paperMuted)
            } else {
                VideoSurface(player: playback.player, fill: false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .overlay {
            if let error = playback.error {
                ViewThatFits(in: .vertical) {
                    errorNotice(error)
                    ScrollView { errorNotice(error) }
                        .scrollBounceBehavior(.basedOnSize)
                }
                .padding(8)
            } else if playback.isLoading {
                LocalizedText("Loading…").font(.glam(.subheadline, weight: .medium))
                    .padding(12).glamoGlass(in: Capsule(), tint: GlamoStyle.paper, mediaBackdrop: true)
            }
        }
    }

    private func errorNotice(_ error: String) -> some View {
        VStack(spacing: 8) {
            LocalizedText(error).font(.glam(.subheadline)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: retry).buttonStyle(CompactActionStyle())
        }
        .padding(12)
        .frame(maxWidth: 360)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 14), tint: GlamoStyle.surface, mediaBackdrop: true)
    }
}

private struct DriveTransport: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.scenePhase) private var phase
    @Binding var scrubbing: Bool
    let previous: PracticeRecording?
    let next: PracticeRecording?
    let open: (PracticeRecording) -> Void
    let cinema: Bool
    let toggleCinema: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                PlayerProgressControl(playback: playback, timeline: playback.timeline, enabled: !playback.isLoading,
                                      canResume: phase == .active, scrubbing: $scrubbing, tint: GlamoStyle.accent)
                DrivePlayerTimes(timeline: playback.timeline)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    transport
                    Spacer(minLength: 0)
                    displayControls
                }
                VStack(spacing: 6) {
                    transport
                    displayControls
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
    }

    private var transport: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                previousFile
                skip(-10)
                DrivePlayButton(playback: playback)
                skip(10)
                nextFile
            }
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    skip(-10)
                    DrivePlayButton(playback: playback)
                    skip(10)
                }
                HStack(spacing: 8) {
                    previousFile
                    nextFile
                }
            }
        }
    }

    private var previousFile: some View {
        IconButton(symbol: .back, label: "Previous file") {
            if let previous { open(previous) }
        }.disabled(previous == nil)
    }

    private var nextFile: some View {
        Button {
            if let next { open(next) }
        } label: {
            Glyph(symbol: .back, size: 20).rotationEffect(.degrees(180))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(PressStyle()).disabled(next == nil).accessibilityLabel("Next file")
    }

    private var displayControls: some View {
        HStack(spacing: 8) {
            DriveSpeedButton(playback: playback, compact: false)
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
    @State private var showingRates = false
    let compact: Bool
    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

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
                .presentationCompactAdaptation(horizontal: typeSize.isAccessibilitySize ? .sheet : .popover,
                                               vertical: .sheet)
                .presentationBackground(GlamoStyle.surface)
        }
    }

    private var speedPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LocalizedText("Playback speed")
                    .font(.glam(.headline)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                IconButton(symbol: .close, label: "Close", tint: GlamoStyle.secondary) { showingRates = false }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 105 : 62), spacing: 6)],
                      spacing: 6) {
                ForEach(rates, id: \.self) { speed in
                    let selected = speed == playback.speed
                    Button {
                        playback.setSpeed(speed)
                        showingRates = false
                    } label: {
                        Text(verbatim: rateText(speed))
                            .font(.glam(.footnote, weight: .semibold)).monospacedDigit()
                            .padding(.horizontal, 4).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selected ? GlamoStyle.onAccent : GlamoStyle.ink)
                            .background(selected ? GlamoStyle.accent : GlamoStyle.paper,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .frame(idealWidth: typeSize.isAccessibilitySize ? 272 : 238, maxWidth: 306)
        .foregroundStyle(GlamoStyle.ink)
    }

    private func rateText(_ speed: Float) -> String { String(format: "%g×", speed) }
}

private struct DrivePlayerTimes: View {
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
    @ScaledMetric(relativeTo: .footnote) private var inlineWidth: CGFloat = 330
    @State private var width: CGFloat = 560
    let movie: PracticeRecording
    let expand: () -> Void
    let close: () -> Void

    var body: some View {
        let inline = width >= inlineWidth && !typeSize.isAccessibilitySize
        let layout = inline ? AnyLayout(HStackLayout(spacing: 6))
                            : AnyLayout(VStackLayout(alignment: .trailing, spacing: 4))
        return VStack(spacing: 3) {
            layout {
                expandButton
                controls
            }
            DriveMiniProgress(timeline: playback.timeline)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: 560)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.paper, mediaBackdrop: true)
    }

    private var expandButton: some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                Group {
                    if movie.isAudio {
                        Glyph(symbol: .sound, size: 18, tint: GlamoStyle.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(GlamoStyle.paperMuted)
                    } else {
                        VideoSurface(player: playback.player, fill: false)
                            .background(.black).allowsHitTesting(false)
                    }
                }
                .frame(width: 52, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: movie.displayName)
                        .font(.glam(.caption, weight: .semibold)).foregroundStyle(GlamoStyle.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    DrivePlayerTimes(timeline: playback.timeline, compact: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Glyph(symbol: .driveExpand, size: 16, tint: GlamoStyle.accent)
                    .frame(width: 32, height: 32)
                    .background(GlamoStyle.paperMuted, in: RoundedRectangle(cornerRadius: 9))
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityHint("Open player")
    }

    private var controls: some View {
        HStack(spacing: 2) {
            DrivePlayButton(playback: playback)
            DriveSpeedButton(playback: playback, compact: true)
            IconButton(symbol: .close, label: "Close player", tint: GlamoStyle.secondary, action: close)
        }
    }
}

private struct DriveMiniProgress: View {
    @ObservedObject var timeline: PlaybackTimeline

    var body: some View {
        DriveMeter(value: timeline.duration > 0 ? timeline.elapsed / timeline.duration : 0)
            .environment(\.layoutDirection, .leftToRight)
    }
}

func driveHasReservedRegion(_ container: GeometryProxy) -> Bool {
    guard #available(iOS 27.1, *) else { return false }
    let bounds = CGRect(origin: .zero, size: container.size)
    let regions = container.reservedRegions(kind: .division) + container.reservedRegions(kind: .occlusion)
    return regions.contains { $0.isActive && $0.frame.intersects(bounds) }
}

func drivePaneMargins(in container: GeometryProxy) -> EdgeInsets {
    guard #available(iOS 27.1, *) else { return EdgeInsets() }
    let bounds = CGRect(origin: .zero, size: container.size)
    let fold = container.reservedRegions(kind: .division).first { region in
        let frame = region.frame.intersection(bounds)
        return region.isActive && !frame.isNull && frame.height > frame.width
            && frame.minX > 0 && frame.maxX < bounds.maxX
    }
    guard let fold else { return EdgeInsets() }
    let leadingWidth = fold.frame.minX
    let trailingWidth = bounds.width - fold.frame.maxX
    return leadingWidth >= trailingWidth
        ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: bounds.width - leadingWidth)
        : EdgeInsets(top: 0, leading: fold.frame.maxX, bottom: 0, trailing: 0)
}
