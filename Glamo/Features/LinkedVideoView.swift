import SwiftUI
import UIKit

private struct BrowserLessonSearch: Identifiable, Equatable {
    let id = UUID()
    let query: String
    var url: URL? {
        var address = URLComponents(string: "https://www.google.com/search")
        address?.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search engines treat an unescaped plus sign as a space.
        if let encoded = address?.percentEncodedQuery {
            address?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        return address?.url
    }
}

@MainActor
private final class FeedStore: ObservableObject {
    @Published private(set) var entries: [PlaybackQueueEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var hasMore = true
    @Published var error: String?
    @Published private(set) var emptySearch: BrowserLessonSearch?
    private var feedID: String?
    private var cursor: String?
    private var roundVideoIDs = Set<String>()
    private var requestQuery = ""
    private(set) var query = ""
    private var generation = UUID()

    func invalidatePendingLoad() {
        generation = UUID()
        loading = false
    }

    func isNearEnd(_ id: String?) -> Bool {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        return index >= entries.count - 3
    }

    func load(api: APIClient, search: String? = nil) async {
        if let search {
            generation = UUID()
            entries = []; feedID = nil; cursor = nil; hasMore = true; loading = false
            query = search; requestQuery = search; roundVideoIDs = []
            emptySearch = nil
        }
        guard !loading else { return }
        let current = generation
        loading = true
        error = nil
        defer { if generation == current { loading = false } }
        do {
            // Skip a few duplicate/invalid pages, but never spin on an empty service.
            for _ in 0..<3 {
                if !hasMore {
                    // Do not replace an unmatched explicit query with recommendations.
                    if entries.isEmpty, requestQuery.nilIfBlank != nil { break }
                    feedID = nil; cursor = nil; roundVideoIDs = []
                    requestQuery = "" // Finished search -> fresh recommendation round.
                    hasMore = true
                }
                let previousCursor = cursor
                let response = try await api.feed(query: requestQuery, feedID: feedID, cursor: cursor)
                try Task.checkCancellation()
                guard current == generation else { return }
                let additions = response.list.compactMap(\.clip).filter { roundVideoIDs.insert($0.id).inserted }
                    .map { PlaybackQueueEntry(id: UUID().uuidString, clip: $0) }
                feedID = response.feedId?.nilIfBlank
                cursor = response.nextCursor?.nilIfBlank
                hasMore = response.hasMore && cursor != nil && cursor != previousCursor
                if !additions.isEmpty { entries += additions; return }
                if response.list.isEmpty {
                    hasMore = false
                    if entries.isEmpty, requestQuery.nilIfBlank != nil {
                        emptySearch = BrowserLessonSearch(query: requestQuery)
                    }
                    break
                }
            }
            if entries.isEmpty, requestQuery.nilIfBlank != nil {
                emptySearch = BrowserLessonSearch(query: requestQuery)
            }
            if !entries.isEmpty { error = "No more videos are available right now. Try again." }
        } catch is CancellationError {
            // Leaving a screen/search is not a service failure.
        } catch {
            if current == generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

private enum PlayerPalette {
    static let overlay = Color(red: 0.169, green: 0.090, blue: 0.133)  // #2B1722
    static let highlight = Color(red: 1, green: 0.722, blue: 0.792)    // #FFB8CA
}

struct LinkedVideoView: View {
    @Environment(\.dismiss) private var dismiss
    private let morePageID = "recommendation-tail"
    @EnvironmentObject private var api: APIClient
    @StateObject private var feed = FeedStore()
    @StateObject private var players = PlaybackPool()
    @Environment(\.scenePhase) private var scenePhase
    let search: String
    let onSearchResult: (String, LessonClip) -> Void
    @State private var visible = false
    @State private var loadedFeedOwner: String?
    @State private var watchOptionsPresented = false
    @State private var activeID: String?
    @State private var recordedQuery: String?
    @State private var openedBrowserSearchID: UUID?
    @State private var browserSearch: PolicyDocument?
    var body: some View {
        let showingClips = api.session != nil && !feed.entries.isEmpty
        ZStack(alignment: .top) {
            if api.session == nil {
                VStack(spacing: 0) {
                    feedHeader
                    ScrollView { ConnectionPanel().glamoPage() }
                }
            } else if !showingClips {
                VStack(spacing: 0) {
                    feedHeader
                    ScrollView { feedStatus.glamoPage() }
                }
            } else {
                GeometryReader { container in
                    GeometryReader { geometry in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(feed.entries) { entry in
                                    let clip = entry.clip
                                    Group {
                                        if let playback = players.controllers[entry.id] {
                                            ClipPage(clip: clip, active: activeID == entry.id,
                                                     controlInsets: container.safeAreaInsets, playback: playback,
                                                     didStartPlaying: { players.prepareNext(after: entry.id) },
                                                     didStopPlaying: { if activeID == entry.id { players.suspend() } },
                                                     showWatchOptions: { watchOptionsPresented = true },
                                                     onSwipeExit: exitPlayer)
                                        } else {
                                            PlayerPoster(url: clip.coverURL)
                                        }
                                    }.frame(width: geometry.size.width, height: geometry.size.height).clipped().id(entry.id)
                                }
                                if !feed.entries.isEmpty {
                                    VStack(spacing: 16) {
                                        if let error = feed.error { LocalizedText(error).foregroundStyle(.white) }
                                        ActionButton(title: feed.loading ? "Loading videos…" : feed.error == nil ? "Load more videos" : "Try again",
                                                     primary: false) { Task { await feed.load(api: api) } }
                                            .disabled(feed.loading)
                                    }.padding(28).padding(container.safeAreaInsets)
                                        .frame(width: geometry.size.width, height: geometry.size.height).id(morePageID)
                                }
                            }.scrollTargetLayout()
                        }.scrollTargetBehavior(.paging).scrollPosition(id: $activeID, anchor: .top).scrollIndicators(.hidden)
                            .onChange(of: activeID) { _, id in
                                players.update(entries: feed.entries, selectedID: id)
                            }
                    }.ignoresSafeArea(.container, edges: .all)
                }
            }
            if showingClips {
                feedHeader
            }
        }.glamoScreenBackground(showingClips ? .black : GlamoStyle.background)
            .foregroundStyle(showingClips ? .white : GlamoStyle.ink)
            .preferredColorScheme(showingClips ? .dark : .light)
            .modifier(PlayerPagingAccess(entries: feed.entries, selectedID: $activeID,
                                         watchOptionsPresented: $watchOptionsPresented, tailID: morePageID, players: players))
            .onAppear { visible = true; players.update(entries: feed.entries, selectedID: activeID) }
            .task(id: api.session?.userId.value) {
                guard let owner = api.session?.userId.value else {
                    loadedFeedOwner = nil
                    return
                }
                guard loadedFeedOwner != owner else { return }
                loadedFeedOwner = nil
                await feed.load(api: api, search: search)
                guard !Task.isCancelled, api.session?.userId.value == owner else { return }
                activeID = feed.entries.first?.id
                loadedFeedOwner = owner
            }
            .onChange(of: activeID) { _, id in
                guard visible, api.session != nil,
                      id == morePageID || feed.isNearEnd(id) else { return }
                Task { guard visible else { return }; await feed.load(api: api) }
            }
            .onChange(of: feed.entries) { previous, entries in
                guard visible else { return }
                if activeID == morePageID, entries.count > previous.count {
                    activeID = entries[previous.count].id
                } else if !entries.contains(where: { $0.id == activeID }) { activeID = entries.first?.id }
                players.update(entries: feed.entries, selectedID: activeID)
                if let first = entries.first?.clip, recordedQuery != feed.query {
                    recordedQuery = feed.query
                    onSearchResult(feed.query, first)
                }
            }
            .onDisappear {
                // A rewarded ad or the Plus page can temporarily cover the active player.
                if watchOptionsPresented {
                    players.suspend()
                    return
                }
                visible = false
                loadedFeedOwner = nil
                feed.invalidatePendingLoad()
                players.releaseAll()
            }
            .fullScreenCover(item: $browserSearch) { document in
                PolicyBrowser(document: document, webSearch: true)
            }
            .onChange(of: feed.emptySearch) { _, _ in openPendingBrowserSearch() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { players.suspend() }
                else { openPendingBrowserSearch() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in players.trimMemory() }
    }
    @ViewBuilder private var feedStatus: some View {
        if loadedFeedOwner != api.session?.userId.value || feed.loading {
            AccountLoadingIndicator(title: "Opening link…")
                .frame(maxWidth: .infinity)
        } else if let request = feed.emptySearch {
            GlamoEmptyState(title: "No match found",
                            message: "Check the URL with the person who shared it.", art: "DriveShelf") {
                ActionButton(title: "Search the web") { openBrowserSearch(request) }
            }
        } else if let error = feed.error {
            MessagePanel(title: "Couldn’t load videos", message: error, actionTitle: "Try again") {
                Task { await feed.load(api: api, search: search) }
            }
        } else {
            GlamoEmptyState(title: "No videos available",
                            message: "Paste a shared video URL on the Files page.", art: "DriveShelf") {
                ActionButton(title: "Try again") { Task { await feed.load(api: api, search: search) } }
            }
        }
    }

    private func openPendingBrowserSearch() {
        guard visible, scenePhase == .active, let request = feed.emptySearch,
              openedBrowserSearchID != request.id else { return }
        openBrowserSearch(request)
    }
    private func openBrowserSearch(_ request: BrowserLessonSearch) {
        guard let url = request.url else { return }
        openedBrowserSearchID = request.id
        players.suspend()
        browserSearch = PolicyDocument(title: "Web search", url: url)
    }
    private var feedHeader: some View {
        HStack {
            Spacer(minLength: 0)
            PlayerExitButton(action: exitPlayer)
        }.environment(\.layoutDirection, .leftToRight)
            .padding(.horizontal, 12).padding(.top, 8)
    }
    private func exitPlayer() {
        players.releaseAll()
        dismiss()
    }
}

private struct PlaybackGateKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var playbackGatePresented: Bool {
        get { self[PlaybackGateKey.self] }
        set { self[PlaybackGateKey.self] = newValue }
    }
}

// Enforce admission at the paging boundary, so denied pages cannot strand the
// user on a succession of unplayable videos. Returning to admitted clips is free.
private struct PlayerPagingAccess: ViewModifier {
    let entries: [PlaybackQueueEntry]
    @Binding var selectedID: String?
    @Binding var watchOptionsPresented: Bool
    let tailID: String
    @ObservedObject var players: PlaybackPool
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var admittedID: String?
    @State private var requestedID: String?
    @State private var showingMembership = false
    @State private var swipeOrigin: String?
    @State private var trackingSwipe = false
    @State private var swipeEnded: UUID?
    @AppStorage("glamo.player.completedSwipeHint.v6") private var completedHint = false

    func body(content: Content) -> some View {
        content
            .environment(\.playbackGatePresented, watchOptionsPresented)
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
                guard !watchOptionsPresented, abs(value.translation.height) > abs(value.translation.width) else { return }
                if !trackingSwipe { trackingSwipe = true; swipeOrigin = admittedID; swipeEnded = nil }
            }.onEnded { _ in swipeEnded = UUID() })
            .task(id: swipeEnded) {
                guard swipeEnded != nil else { return }
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                trackingSwipe = false; swipeOrigin = nil
            }
            .onAppear { admit(selectedID) }
            .onChange(of: selectedID) { _, value in admit(value) }
            .allowsHitTesting(!watchOptionsPresented)
            .accessibilityHidden(watchOptionsPresented)
            .overlay {
                if watchOptionsPresented {
                    WatchLimitPrompt(showingMembership: $showingMembership, finish: finishWatchOptions)
                }
            }
            .fullScreenCover(isPresented: $showingMembership, onDismiss: {
                if commerce.premium { finishWatchOptions() }
            }) {
                MembershipView(requiredBenefit: .unlimitedViewing)
            }
    }
    private func canWatch(_ id: String) -> Bool {
        guard let clip = entries.first(where: { $0.id == id })?.clip else { return false }
        return clip.playbackURL.isFileURL || quota.mayWatch(clip.id, premium: commerce.premium)
    }
    private func admit(_ id: String?) {
        guard !watchOptionsPresented, let id else { return }
        if let admittedID, !entries.contains(where: { $0.id == admittedID }) { self.admittedID = nil }
        let isTail = id == tailID
        if canWatch(id) || (isTail && !quota.canRequestReward(for: .watch, premium: commerce.premium)) {
            if !isTail {
                if trackingSwipe, let swipeOrigin, swipeOrigin != id, admittedID != id {
                    completedHint = true
                }
                admittedID = id
            }
            return
        }
        guard isTail || entries.contains(where: { $0.id == id }) else { return }
        requestedID = id
        players.controllers.values.forEach { $0.pause() }
        players.suspend()
        if let admittedID, admittedID != id {
            // A new deliberate swipe may prompt again; dismissal itself never does.
            watchOptionsPresented = true
            selectedID = admittedID
        } else {
            admittedID = id
            if quota.claimWatchLimitPrompt(premium: commerce.premium) { watchOptionsPresented = true }
        }
    }
    private func finishWatchOptions() {
        if let requestedID, canWatch(requestedID) { selectedID = requestedID }
        requestedID = nil
        watchOptionsPresented = false
    }
}

// Count the cue only after an uninterrupted presentation. The old flag could
// be consumed by buffering or a sheet before the user had time to read it.
private struct PlayerSwipeHint: View {
    let eligible: Bool
    @AppStorage("glamo.player.completedSwipeHint.v6") private var alreadyShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var showing = false
    var body: some View {
        // A persistent host is essential: a task on an empty conditional Group
        // has no rendered child to start it. Buffering must not gate this cue.
        GeometryReader { container in
            // The parent reserves the exit, action rail and bottom captions.
            // Size the artwork from the remaining viewport, not a device model.
            let width = max(0, container.size.width)
            let height = max(0, container.size.height)
            let artworkHeight = min(width * 1.18, height * 0.64, 520)
            ZStack {
                Color.clear
                if showing && eligible && !alreadyShown && phase == .active {
                    VStack(spacing: min(24, height * 0.04)) {
                        Color.clear.frame(width: width, height: artworkHeight)
                            .phaseAnimator([0, 1, 2, 3, 4]) { host, step in
                                host.overlay {
                                    let resting = step == 0 || step == 4
                                    ZStack {
                                        Image("PlayerSwipeTrail").resizable().scaledToFit()
                                            .frame(width: artworkHeight * 0.56, height: artworkHeight)
                                            .offset(x: -artworkHeight * 0.12)
                                            .opacity(reduceMotion ? 0.7 : (resting ? 0.25 : 0.9))
                                            .scaleEffect(reduceMotion || resting ? 0.94 : 1)
                                        Image("PlayerSwipeGesture").resizable().scaledToFit()
                                            .frame(width: artworkHeight * 0.48, height: artworkHeight * 0.48)
                                            .shadow(color: PlayerPalette.highlight.opacity(0.25), radius: 6)
                                            .rotationEffect(.degrees(reduceMotion ? 0 : (step == 2 ? -5 : 3)))
                                            .offset(x: artworkHeight * 0.1,
                                                    y: reduceMotion ? 0 : (step == 2 ? -1 : 1) * artworkHeight * 0.22)
                                            .opacity(reduceMotion ? 1 : (resting ? 0.15 : 1))
                                    }
                                }
                            } animation: { step in
                                reduceMotion ? nil : .easeInOut(duration: step == 2 || step == 3 ? 0.85 : 0.3)
                            }
                        LocalizedText("Swipe up or down for another video")
                            .font(.glam(.title3, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .shadow(color: .black.opacity(0.8), radius: 4, y: 1)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
            }.frame(width: width, height: height)
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showing)
        .task(id: eligible && phase == .active) {
            showing = false
            guard eligible, phase == .active, !alreadyShown else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                showing = true
                try await Task.sleep(for: .seconds(6))
                try Task.checkCancellation()
                alreadyShown = true
            } catch { }
            showing = false
        }
    }
}

private struct ClipPage: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @Environment(\.scenePhase) private var phase
    @Environment(\.playbackGatePresented) private var pagingGate
    let clip: LessonClip
    let active: Bool
    // Read from the enclosing safe container; video fills the expanded viewport.
    var controlInsets = EdgeInsets()
    @ObservedObject var playback: PlaybackController
    var didStartPlaying: () -> Void = {}
    var didStopPlaying: () -> Void = {}
    let showWatchOptions: () -> Void
    var onSwipeExit: () -> Void = {}
    @State private var visible = false
    @State private var firstFrameReady = false
    @State private var accessChecked = false
    @State private var resumeAfterSheet = false
    @State private var resumeAfterInterruption = false
    @State private var options = false
    @State private var editor = false
    @State private var recorded = false
    @State private var allowed = false
    @State private var scrubbing = false
    @State private var favoriteError: String?
    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: playback.player, onReadyForDisplay: { firstFrameReady = $0 })
                .clipped().allowsHitTesting(false)
            if !firstFrameReady {
                PlayerPoster(url: clip.coverURL)
                    .allowsHitTesting(false)
            }
            Color.clear.contentShape(Rectangle()).onTapGesture {
                guard active, phase == .active, !ads.isPresenting else { return }
                if allowed, firstFrameReady { playback.toggle() }
            }
            // Only the video backdrop owns this gesture; controls and the
            // scrubber above it keep their own touches. Vertical paging wins
            // unless the completed gesture is decisively leftward.
            .simultaneousGesture(DragGesture(minimumDistance: 32).onEnded { value in
                guard active, visible, phase == .active, !ads.isPresenting,
                      !pagingGate, !options, !editor, !scrubbing,
                      value.translation.width < -90,
                      abs(value.translation.width) > abs(value.translation.height) * 1.7 else { return }
                onSwipeExit()
            })
            // Preserve contrast for captions and playback actions over moving footage.
            LinearGradient(stops: [.init(color: .black.opacity(0.38), location: 0),
                                   .init(color: .clear, location: 0.2),
                                   .init(color: .clear, location: 0.53),
                                   .init(color: .black.opacity(0.68), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false).accessibilityHidden(true)
            playerControls
            if active, let favoriteError {
                VStack {
                    HStack(spacing: 10) {
                        LocalizedText(favoriteError).font(.glam(.caption))
                        IconButton(symbol: .close, label: "Dismiss message") { self.favoriteError = nil }
                    }.padding(12).foregroundStyle(GlamoStyle.ink)
                        .glamoCard(radius: 20)
                    Spacer()
                }.padding(.top, controlInsets.top + 60).padding(.horizontal, 16)
            }
            PlayerSwipeHint(eligible: active && visible && playback.error == nil &&
                            !pagingGate && !options && !editor && !ads.isPresenting)
                .padding(.top, controlInsets.top + 64)
                .padding(.bottom, controlInsets.bottom + 150)
                .padding(.leading, controlInsets.leading + 20)
                .padding(.trailing, controlInsets.trailing + 72)
            if active, visible, !pagingGate, !options, !editor {
                if accessChecked, !allowed {
                    VStack(spacing: 16) {
                        LocalizedText(quota.canRequestReward(for: .watch, premium: commerce.premium)
                                      ? "Daily viewing limit reached" : "Playback unavailable")
                            .font(.glam(.title3, weight: .semibold, editorial: true))
                        ActionButton(title: "Get more views", action: showWatchOptions)
                    }.padding(20).frame(maxWidth: 320)
                        .foregroundStyle(GlamoStyle.ink)
                        .glamoCard(radius: 24, fill: GlamoStyle.paper).padding(24)
                } else if let error = playback.error {
                    MessagePanel(title: "Couldn’t play this video", message: error, actionTitle: "Retry") { activate(reload: true) }.padding(24)
                } else if allowed, playback.isLoading || (!firstFrameReady && playback.intendsPlayback) {
                    PlayerLoadingFeedback(buffering: firstFrameReady)
                        .allowsHitTesting(false)
                } else if allowed, firstFrameReady, !playback.intendsPlayback, !scrubbing {
                    IconButton(symbol: .play, label: "Play video", tint: .white) { playback.play() }
                        .shadow(color: .black.opacity(0.65), radius: 3, y: 1)
                }
            }
        }.foregroundStyle(.white).clipped()
            .onAppear { visible = true; if active { activate() } }
            .onChange(of: active) { _, active in
                resumeAfterInterruption = false
                if active { activate() } else { favoriteError = nil; resumeAfterSheet = false; playback.pause() }
            }
            .onChange(of: playback.isPlaying) { _, playing in
                if playing, active, visible, !recorded {
                    recorded = clip.playbackURL.isFileURL || quota.recordWatch(clip.id, premium: commerce.premium)
                    if !recorded { playback.pause(); allowed = false }
                }
                if playing, active, recorded { didStartPlaying() }
                if !playing, active { didStopPlaying() }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                guard active, visible, playback.isPlaying, !clip.playbackURL.isFileURL else { return }
                if !quota.recordWatch(clip.id, premium: commerce.premium) { playback.pause(); allowed = false }
            }
            .onChange(of: phase) { _, state in
                if state != .active { interruptPlayback() } else { resumeIfNeeded() }
            }
            .onChange(of: ads.isPresenting) { _, presenting in
                if presenting { interruptPlayback() } else { resumeIfNeeded() }
            }
            .onDisappear { visible = false; resumeAfterInterruption = false; playback.pause() }
            .onChange(of: pagingGate) { _, presented in
                if presented { playback.pause() } else if active { activate() }
            }
            .sheet(isPresented: $options, onDismiss: resumeAfterControls) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SheetHeading(inset: false) { options = false }
                        LocalizedText("Speed").font(.glam(.headline))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { speed in
                                    Button("\(speed, specifier: "%g")×") { playback.setSpeed(speed) }
                                        .font(.glam(.subheadline, weight: .semibold))
                                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 16).frame(minHeight: 44)
                                        .foregroundStyle(playback.speed == speed ? GlamoStyle.accent : GlamoStyle.ink)
                                        .background(playback.speed == speed ? GlamoStyle.paperMuted : GlamoStyle.surface, in: Capsule())
                                        .overlay {
                                            Capsule().strokeBorder(playback.speed == speed ? GlamoStyle.accent : GlamoStyle.line)
                                                .allowsHitTesting(false)
                                        }
                                        .accessibilityAddTraits(playback.speed == speed ? .isSelected : [])
                                }
                            }
                        }.buttonStyle(PressStyle())
                        LocalizedText("Video quality adjusts to your connection on supported streams.")
                            .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                        ActionButton(title: "Open video editor", primary: false) { options = false; editor = true }
                    }.glamoPage()
                }.glamoScreenBackground().presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $editor, onDismiss: resumeAfterControls) { EditorSheet() }
    }
    private var playerControls: some View {
        GeometryReader { viewport in
            let insets = resolvedControlInsets(in: viewport)
            let height = viewport.size.height - insets.top - insets.bottom
            playerControlContent(compact: height < 270)
                .padding(insets)
        }
    }
    private func playerControlContent(compact: Bool) -> some View {
        let row = compact
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 16))
        let rail = compact
            ? AnyLayout(HStackLayout(spacing: 8))
            : AnyLayout(VStackLayout(spacing: 8))
        return VStack(spacing: 0) {
            Spacer(minLength: 16)
            row {
                VStack(alignment: .leading, spacing: 7) {
                    if !clip.channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(verbatim: clip.channel).font(.glam(.subheadline, weight: .bold)).lineLimit(2)
                    }
                    Text(verbatim: clip.title).font(.glam(.subheadline)).lineLimit(2)
                        .accessibilityLabel(clip.title)
                }
                .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
                rail {
                    PlayerRailButton(artwork: library.isSaved(clip) ? .saved : .save,
                                     title: library.isSaved(clip) ? "Saved" : "Save",
                                     accessibilityTitle: library.isSaved(clip) ? "Remove saved video" : "Save video",
                                     selected: library.isSaved(clip), action: save)
                    PlayerRailButton(artwork: .more, title: "More", accessibilityTitle: "Playback options") {
                        resumeAfterSheet = playback.intendsPlayback
                        playback.pause(); options = true
                    }
                }.padding(.bottom, 8)
            }.padding(.leading, 4)
            PlayerProgressControl(playback: playback, timeline: playback.timeline,
                                  enabled: allowed && firstFrameReady,
                                  canResume: active && allowed && phase == .active && !ads.isPresenting,
                                  scrubbing: $scrubbing)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }
    private func resolvedControlInsets(in viewport: GeometryProxy) -> EdgeInsets {
        guard #available(iOS 27.1, *) else { return controlInsets }
        let size = viewport.size
        var insets = controlInsets
        func usableBounds() -> CGRect {
            CGRect(x: insets.leading, y: insets.top,
                   width: max(0, size.width - insets.leading - insets.trailing),
                   height: max(0, size.height - insets.top - insets.bottom))
        }
        // The default query returns frames in the layout's logical direction,
        // matching the leading and trailing padding used by the controls.
        for region in viewport.reservedRegions(kind: .division) where region.isActive {
            let bounds = usableBounds()
            let split = region.frame.intersection(bounds)
            guard !split.isNull, !split.isEmpty else { continue }
            if split.height >= split.width {
                let leadingWidth = split.minX - bounds.minX
                let trailingWidth = bounds.maxX - split.maxX
                if trailingWidth >= 242 || trailingWidth >= leadingWidth {
                    insets.leading = split.maxX
                } else {
                    insets.trailing = size.width - split.minX
                }
            } else {
                let upperHeight = split.minY - bounds.minY
                let lowerHeight = bounds.maxY - split.maxY
                if lowerHeight >= 150 || lowerHeight >= upperHeight {
                    insets.top = split.maxY
                } else {
                    insets.bottom = size.height - split.minY
                }
            }
        }
        for region in viewport.reservedRegions(kind: .occlusion) where region.isActive {
            let bounds = usableBounds()
            let obstruction = region.frame.intersection(bounds)
            guard !obstruction.isNull, !obstruction.isEmpty,
                  obstruction.maxY > bounds.maxY - 144 else { continue }
            if obstruction.midX < bounds.midX, bounds.maxX - obstruction.maxX >= 242 {
                insets.leading = obstruction.maxX
            } else if obstruction.midX >= bounds.midX, obstruction.minX - bounds.minX >= 242 {
                insets.trailing = size.width - obstruction.minX
            } else {
                insets.bottom = size.height - obstruction.minY
            }
        }
        return insets
    }
    private func activate(reload: Bool = false) {
        guard active, visible, phase == .active, !ads.isPresenting, !pagingGate,
              !options, !editor else { return }
        recorded = false
        accessChecked = true
        allowed = clip.playbackURL.isFileURL || quota.mayWatch(clip.id, premium: commerce.premium)
        if !allowed {
            playback.pause()
            // Paging owns automatic prompts; this page retains the explicit reward action.
            return
        }
        if playback.loadedURL != clip.playbackURL || reload {
            firstFrameReady = false
            playback.load(clip.playbackURL, autoplay: true)
        }
        else { playback.play() }
    }
    private func resumeAfterControls() {
        guard resumeAfterSheet, active, visible, phase == .active,
              !ads.isPresenting, !pagingGate, !options, !editor else { return }
        resumeAfterSheet = false
        activate()
    }
    private func interruptPlayback() {
        if active, visible, playback.intendsPlayback { resumeAfterInterruption = true }
        playback.pause()
    }
    private func resumeIfNeeded() {
        guard resumeAfterInterruption || resumeAfterSheet, active, visible, phase == .active,
              !ads.isPresenting, !pagingGate, !options, !editor else { return }
        resumeAfterInterruption = false
        resumeAfterSheet = false
        activate()
    }
    private func save() {
        favoriteError = nil
        if !library.toggle(clip) {
            favoriteError = "Favorites could not be updated. Please try again."
            library.error = nil // This full-screen surface owns the feedback.
        }
    }
}
private struct PlayerExitButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                AssetMask(name: "PlayerExit", tint: .white)
                    .frame(width: 14, height: 14)
                LocalizedText("Exit").font(.glam(.caption, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glamoGlass(in: Capsule(), tint: PlayerPalette.overlay, interactive: true, mediaBackdrop: true)
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(PressStyle()).accessibilityLabel(LocalizedStringKey("Exit"))
            .accessibilityIdentifier("player.exit")
    }
}

struct PlayerProgressControl: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var timeline: PlaybackTimeline
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    let enabled: Bool
    let canResume: Bool
    @Binding var scrubbing: Bool
    var tint: Color = .white
    var showsInlineTimes = false
    var overVideo = false
    @State private var scrubPosition: Double = 0
    @State private var resumeAfterScrub = false

    var body: some View {
        if overVideo {
            videoTimeline
        } else if showsInlineTimes {
            VStack(spacing: 0) {
                inlineTimes
                scrubber
            }
        } else {
            scrubber.overlay(alignment: .top) {
                if scrubbing {
                    Text(verbatim: "\(durationLabel(scrubPosition)) / \(durationLabel(timeline.duration))")
                        .environment(\.layoutDirection, .leftToRight)
                        .font(.caption.monospacedDigit()).foregroundStyle(tint).offset(y: -8)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var videoTimeline: some View {
        let total = durationLabel(timeline.duration)
        let position = durationLabel(scrubbing ? scrubPosition : timeline.elapsed)
        let elapsedTime = ZStack(alignment: .leading) {
            Text(verbatim: total).hidden()
            Text(verbatim: position)
        }
        .accessibilityHidden(true)
        let totalTime = Text(verbatim: total)
            .accessibilityLabel(Text(verbatim: L10n.format("Duration · %@", [total], language: AppLanguage.from(locale))))
        let stacksTimes = typeSize.isAccessibilitySize
        let layout = stacksTimes ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            if stacksTimes {
                HStack(spacing: 6) {
                    elapsedTime
                    Spacer(minLength: 0)
                    totalTime
                }
            } else {
                elapsedTime
            }
            scrubber.frame(minWidth: 56)
            if !stacksTimes { totalTime }
        }
        .font(.glam(.caption, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .environment(\.layoutDirection, .leftToRight)
        .padding(.top, stacksTimes ? 6 : 0)
    }

    private var scrubber: some View {
        GlamoScrubber(value: Binding(
                get: { scrubbing ? scrubPosition : timeline.elapsed },
                set: {
                    scrubPosition = $0
                    // During a drag, move the UI only. Seek once on release.
                    if !scrubbing { playback.seek($0) }
                }
            ), range: 0...max(1, timeline.duration), label: "Playback position",
                         tint: tint, trackTint: overVideo ? Color.white.opacity(0.42) : tint.opacity(0.3),
                         trackHeight: scrubbing ? 5 : 2,
                         onEditingChanged: { editing in
                if editing {
                    scrubPosition = timeline.elapsed
                    resumeAfterScrub = playback.isPlaying
                    scrubbing = true
                    playback.pause()
                } else {
                    playback.seek(scrubPosition)
                    scrubbing = false
                    if resumeAfterScrub && canResume {
                        playback.play()
                    }
                    resumeAfterScrub = false
                }
            })
            .disabled(!enabled || timeline.duration <= 0 || playback.error != nil)
    }

    private var inlineTimes: some View {
        let total = durationLabel(timeline.duration)
        let position = durationLabel(scrubbing ? scrubPosition : timeline.elapsed)
        let positionTime = ZStack(alignment: .leading) {
            // Reserve the width of the longest timestamp so dragging keeps the layout steady.
            Text(verbatim: total).hidden()
            Text(verbatim: position)
        }
        .font(.glam(.subheadline, weight: .semibold).monospacedDigit())
        .foregroundStyle(scrubbing ? tint : GlamoStyle.ink)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true) // The slider already announces this value.

        let totalTime = LocalizedText("Duration · %@", total)
            .font(.glam(.caption, weight: .medium).monospacedDigit())
            .foregroundStyle(GlamoStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                positionTime
                Spacer(minLength: 0)
                totalTime
            }
            VStack(alignment: .leading, spacing: 4) {
                positionTime
                totalTime
            }
        }
        .padding(.horizontal, 2)
        .allowsHitTesting(false)
    }
}

private struct PlayerPoster: View {
    let url: URL?
    var body: some View {
        Color.black.overlay {
            GeometryReader { geometry in
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        }
                    }
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct PlayerLoadingFeedback: View {
    let buffering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var revealed = false
    var body: some View {
        VStack(spacing: 10) {
            Image("GlamoLoadingMark").renderingMode(.template).resizable().scaledToFit()
                .foregroundStyle(PlayerPalette.highlight)
                .frame(width: 36, height: 5)
                .phaseAnimator([false, true]) { content, dimmed in
                    content.opacity(reduceMotion || phase != .active ? 1 : (dimmed ? 0.3 : 1))
                } animation: { _ in
                    reduceMotion || phase != .active ? nil : .easeInOut(duration: 0.6)
                }.accessibilityHidden(true)
            LocalizedText(buffering ? "Buffering…" : "Loading…")
                .font(.glam(.caption)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
        }.opacity(revealed ? 1 : 0).accessibilityHidden(!revealed)
            .task {
                do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation(); revealed = true }
                catch { }
            }
            .onDisappear { revealed = false }
    }
}

struct GlamoScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var tint: Color = GlamoStyle.ink
    var trackTint: Color = GlamoStyle.controlLine
    var trackHeight: CGFloat = 4
    var onEditingChanged: (Bool) -> Void = { _ in }
    @GestureState private var dragging = false
    @State private var editing = false
    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard value.isFinite, range.lowerBound.isFinite, span.isFinite, span > 0 else { return 0 }
        return CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(trackTint).frame(height: trackHeight)
                Capsule().fill(tint).frame(width: geometry.size.width * fraction, height: trackHeight)
            }.frame(height: 44).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).updating($dragging) { _, state, _ in state = true }.onChanged { gesture in
                    if !editing { editing = true; onEditingChanged(true) }
                    value = range.lowerBound + min(1, max(0, gesture.location.x / max(1, geometry.size.width))) * (range.upperBound - range.lowerBound)
                }.onEnded { _ in finishEditing() })
        }.frame(height: 44).environment(\.layoutDirection, .leftToRight)
            .accessibilityElement().accessibilityLabel(LocalizedStringKey(label))
            .onChange(of: dragging) { _, dragging in if !dragging { finishEditing() } }
            .accessibilityValue(durationLabel(value)).accessibilityAdjustableAction { direction in
                value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? 1 : -1)))
            }
    }
    private func finishEditing() {
        guard editing else { return }
        editing = false
        onEditingChanged(false)
    }
}

private enum PlayerArtwork: String, CaseIterable, Hashable {
    // Individual original assets (template rendering, tinted for state).
    case save = "PlayerSave", saved = "PlayerSaved", more = "PlayerMore"
}

// Shared geometry for every rail action, including the changing cache status.
private struct PlayerRailLabel<Label: View>: View {
    let artwork: PlayerArtwork
    let selected: Bool
    private let label: Label
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 16
    init(artwork: PlayerArtwork, selected: Bool, @ViewBuilder label: () -> Label) {
        self.artwork = artwork
        self.selected = selected
        self.label = label()
    }
    var body: some View {
        VStack(spacing: 4) {
            AssetMask(name: artwork.rawValue, tint: GlamoStyle.ink)
                .frame(width: 20, height: 20)
                .frame(width: 30, height: 30)
                .background(selected ? PlayerPalette.highlight : GlamoStyle.paper, in: Capsule())
            label.font(.glam(.caption2, weight: .medium))
                .foregroundStyle(selected ? PlayerPalette.highlight : .white)
                .lineLimit(1).minimumScaleFactor(0.65).multilineTextAlignment(.center)
                .frame(width: 48, height: labelHeight)
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
        }.frame(width: 48, height: max(52, 34 + labelHeight))
            .contentShape(.interaction, Rectangle())
    }
}

private struct PlayerRailButton: View {
    let artwork: PlayerArtwork
    let title: String
    let accessibilityTitle: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            PlayerRailLabel(artwork: artwork, selected: selected) {
                LocalizedText(title)
            }
        }.buttonStyle(PressStyle())
            .accessibilityLabel(LocalizedStringKey(accessibilityTitle))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
