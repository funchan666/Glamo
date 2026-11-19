import SwiftUI
import UIKit
import AVFoundation
import CryptoKit

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

struct SearchPlaybackContinuation {
    let query: String
    let feedID: String?
    let cursor: String?
    let hasMore: Bool
}

@MainActor
private final class FeedStore: ObservableObject {
    @Published private(set) var entries: [PlaybackQueueEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var hasMore = true
    @Published var error: String?
    @Published private(set) var emptySearch: BrowserLessonSearch?
    @Published private(set) var resolvedFolder: DriveCollection?
    private var feedID: String?
    private var cursor: String?
    private var roundVideoIDs = Set<String>()
    private var requestQuery = ""
    private(set) var query = ""
    private var generation = UUID()
    private var resultsRequest = UUID()
    private var collectionPage = 1

    var playbackContinuation: SearchPlaybackContinuation? {
        guard resolvedFolder == nil, !entries.contains(where: { $0.clip.isDirect == true }) else { return nil }
        return SearchPlaybackContinuation(query: query, feedID: feedID, cursor: cursor, hasMore: hasMore)
    }

    func configureSearch(_ continuation: SearchPlaybackContinuation) {
        query = continuation.query
        requestQuery = continuation.query
        feedID = continuation.feedID
        cursor = continuation.cursor
        hasMore = continuation.hasMore
        roundVideoIDs = Set(entries.map { $0.clip.id })
    }

    func loadResults(api: APIClient, search: String, refresh: Bool) async {
        guard refresh || !loading else { return }
        let request = UUID()
        resultsRequest = request
        let owner = api.session?.userId.value
        await load(api: api, search: refresh ? search : nil, allowsNewRounds: false)
        guard refresh, resultsRequest == request, !Task.isCancelled, api.session?.userId.value == owner,
              entries.isEmpty, let link = sharedLinkID(search) else { return }
        let token = generation
        loading = true
        defer { if generation == token { loading = false } }
        do {
            let resource = try await api.sharedResource(link: link)
            try Task.checkCancellation()
            guard generation == token, api.session?.userId.value == owner else { return }
            if resource.isFolder {
                resolvedFolder = resource
                hasMore = false
            } else if let clip = resource.clip {
                install([clip])
            }
            emptySearch = nil
            error = nil
        } catch is CancellationError { }
        catch {
            // An unmatched share keeps the search response and its existing
            // recovery action; a fallback must not erase a useful search error.
        }
    }

    private func sharedLinkID(_ search: String) -> String? {
        let input = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: input), let id = DriveCollection.incomingLinkID(url) { return id }
        if WebAddress.media(input) != nil { return DriveCollection.linkID(input).nilIfBlank }
        if input.range(of: #"^[A-Za-z0-9]{6}$"#, options: .regularExpression) != nil { return input }
        return nil
    }

    func install(_ clips: [LessonClip]) {
        invalidatePendingLoad()
        var seen = Set<String>()
        entries = clips.filter { seen.insert($0.id).inserted }.map { .init(id: UUID().uuidString, clip: $0) }
        hasMore = false
        error = nil
    }
    func configureCollection(nextPage: Int, hasMore: Bool) {
        collectionPage = nextPage
        self.hasMore = hasMore
    }
    func loadCollection(_ collection: DriveCollection, api: APIClient) async {
        guard !loading, hasMore else { return }
        let token = generation
        loading = true; error = nil
        defer { if token == generation { loading = false } }
        do {
            let response = try await api.collectionPage(link: collection.id, page: collectionPage)
            try Task.checkCancellation()
            guard token == generation else { return }
            var seen = Set(entries.map { $0.clip.id })
            entries += response.list.compactMap { $0.collection()?.clip }.filter { seen.insert($0.id).inserted }
                .map { .init(id: UUID().uuidString, clip: $0) }
            hasMore = !response.list.isEmpty && (response.total.flatMap { Int($0.value) }.map { collectionPage * 10 < $0 } ?? (response.list.count >= 10))
            collectionPage += 1
        } catch is CancellationError { }
        catch { if token == generation { self.error = error.localizedDescription } }
    }

    func invalidatePendingLoad() {
        generation = UUID()
        resultsRequest = UUID()
        loading = false
    }

    func isNearEnd(_ id: String?) -> Bool {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        return index >= entries.count - 3
    }

    func load(api: APIClient, search: String? = nil, allowsNewRounds: Bool = true) async {
        if let search {
            generation = UUID()
            entries = []; feedID = nil; cursor = nil; hasMore = true; loading = false
            query = search; requestQuery = search; roundVideoIDs = []
            emptySearch = nil
            resolvedFolder = nil
            if let url = WebAddress.media(search.trimmingCharacters(in: .whitespacesAndNewlines)),
               ["mp4", "mov", "m4v", "m3u8"].contains(url.pathExtension.lowercased()) {
                let id = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
                var clip = LessonClip(id: "url-" + id, title: url.deletingPathExtension().lastPathComponent,
                                      playbackURL: url, coverURL: nil, shortLink: nil, channel: "", duration: nil)
                clip.isDirect = true
                install([clip])
                return
            }
        }
        guard !loading, allowsNewRounds || hasMore else { return }
        let current = generation
        loading = true
        error = nil
        defer { if generation == current { loading = false } }
        do {
            // Skip a few duplicate/invalid pages, but never spin on an empty service.
            for _ in 0..<3 {
                if !hasMore {
                    guard allowsNewRounds else { break }
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
            if !entries.isEmpty, allowsNewRounds || hasMore {
                error = "No more videos are available right now. Try again."
            }
        } catch is CancellationError {
            // Leaving a screen/search is not a service failure.
        } catch {
            if current == generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct VideoSearchResultsView: View {
    let search: String
    var onSearchResult: (String, LessonClip) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var results = FeedStore()
    @State private var loadedOwner: String?
    @State private var recordedResult = false
    @State private var browserSearch: PolicyDocument?

    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, DriveStyle.pageInset).padding(.vertical, 8)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if api.session == nil {
                            ConnectionPanel()
                        } else if results.entries.isEmpty, results.resolvedFolder == nil {
                            emptyResults
                        } else {
                            if let folder = results.resolvedFolder {
                                DriveCollectionRows(collections: [folder], fileListStyle: true)
                            }
                            if !results.entries.isEmpty {
                                DriveRemoteVideoRows(clips: results.entries.map(\.clip),
                                                     searchContinuation: results.playbackContinuation, fileListStyle: true)
                            }
                            if let error = results.error {
                                ErrorNote(message: error)
                                ActionButton(title: "Try again", primary: false) { loadMore() }
                            } else if results.loading {
                                AccountLoadingIndicator(title: "Loading videos…").frame(maxWidth: .infinity)
                            } else if results.hasMore {
                                ActionButton(title: "Load more", primary: false) { loadMore() }
                            }
                        }
                    }
                    .padding(.horizontal, DriveStyle.pageInset).padding(.top, 12).padding(.bottom, 24)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable {
                    guard api.session != nil else { return }
                    await results.loadResults(api: api, search: search, refresh: true)
                }
            }
            .padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }
        .driveScreenBackground()
        .task(id: api.session?.userId.value) {
            guard let owner = api.session?.userId.value, loadedOwner != owner else { return }
            await results.loadResults(api: api, search: search, refresh: true)
            guard !Task.isCancelled, api.session?.userId.value == owner else { return }
            loadedOwner = owner
        }
        .onChange(of: results.entries) { _, entries in
            guard !recordedResult, let clip = entries.first?.clip else { return }
            recordedResult = true
            onSearchResult(search, clip)
        }
        .onChange(of: results.resolvedFolder) { _, folder in
            guard !recordedResult, let folder else { return }
            recordedResult = true
            library.record(link: search, title: folder.title)
        }
        .onDisappear { results.invalidatePendingLoad() }
        .fullScreenCover(item: $browserSearch) { PolicyBrowser(document: $0, webSearch: true) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            IconButton(symbol: .back, label: "Back", tint: DriveStyle.ink, glass: true) { dismiss() }
            VStack(alignment: .leading, spacing: 5) {
                if !results.entries.isEmpty || results.resolvedFolder != nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { resultTitle.fixedSize(); Spacer(minLength: 0); resultCount.fixedSize() }
                        VStack(alignment: .leading, spacing: 4) { resultTitle; resultCount }
                    }
                } else {
                    resultTitle
                }
                Text(verbatim: search).font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(DriveStyle.ink)
    }

    private var resultTitle: some View {
        LocalizedText("Search results").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var resultCount: some View {
        let count = results.entries.count + (results.resolvedFolder == nil ? 0 : 1)
        return LocalizedText(count == 1 ? "%@ item" : "%@ items", count.formatted(.number.locale(locale)))
            .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary).monospacedDigit()
    }

    @ViewBuilder private var emptyResults: some View {
        if loadedOwner != api.session?.userId.value || results.loading {
            AccountLoadingIndicator(title: "Loading videos…").frame(maxWidth: .infinity)
        } else if let error = results.error {
            MessagePanel(title: "Couldn’t load videos", message: error, actionTitle: "Try again", action: refresh)
        } else {
            GlamoEmptyState(title: "No match found", message: "Check the URL with the person who shared it.", art: "DriveShelf") {
                ActionButton(title: "Try again", primary: false, action: refresh)
                ActionButton(title: "Search the web") {
                    if let url = BrowserLessonSearch(query: search).url { browserSearch = PolicyDocument(title: "Web search", url: url) }
                }
            }
        }
    }

    private func refresh() { Task { await results.loadResults(api: api, search: search, refresh: true) } }
    private func loadMore() { Task { await results.loadResults(api: api, search: search, refresh: false) } }
}

struct LinkedVideoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pauseLocalPlayback) private var pauseLocalPlayback
    private let morePageID = "recommendation-tail"
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var feed = FeedStore()
    @StateObject private var players = PlaybackPool()
    @Environment(\.scenePhase) private var scenePhase
    let search: String
    var initialClips: [LessonClip]? = nil
    var selectedClipID: String? = nil
    var initialCollection: DriveCollection? = nil
    var collectionNextPage = 1
    var collectionHasMore = false
    var initialSearchPage: SearchPlaybackContinuation? = nil
    var onSearchResult: (String, LessonClip) -> Void = { _, _ in }
    @State private var visible = false
    @State private var loadedFeedOwner: String?
    @State private var watchOptionsPresented = false
    @State private var nestedPresentationActive = false
    @State private var activeID: String?
    @State private var recordedQuery: String?
    @State private var openedBrowserSearchID: UUID?
    @State private var browserSearch: PolicyDocument?
    var body: some View {
        let showingClips = (initialClips != nil || api.session != nil) && !feed.entries.isEmpty
        ZStack(alignment: .top) {
            if api.session == nil && initialClips == nil {
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
                                                     purchasePresentation: { nestedPresentationActive = $0 },
                                                     onSwipeExit: exitPlayer)
                                        } else {
                                            PlayerPoster(url: clip.coverURL)
                                                .overlay(alignment: .topLeading) {
                                                    PlayerExitButton(action: exitPlayer)
                                                        .padding(.horizontal, 16).padding(.top, 8)
                                                        .padding(container.safeAreaInsets)
                                                }
                                        }
                                    }.frame(width: geometry.size.width, height: geometry.size.height).clipped().id(entry.id)
                                }
                                if !feed.entries.isEmpty, initialClips == nil || initialSearchPage != nil || (initialCollection != nil && feed.hasMore) {
                                    VStack(spacing: 16) {
                                        HStack {
                                            PlayerExitButton(action: exitPlayer)
                                            Spacer(minLength: 0)
                                        }
                                        Spacer(minLength: 0)
                                        if let error = feed.error { LocalizedText(error).foregroundStyle(.white) }
                                        ActionButton(title: feed.loading ? "Loading videos…" : feed.error == nil ? "Load more videos" : "Try again",
                                                     primary: false) { Task { await loadMore() } }
                                            .disabled(feed.loading)
                                        Spacer(minLength: 0)
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
        }.glamoScreenBackground(showingClips ? .black : GlamoStyle.background)
            .foregroundStyle(showingClips ? .white : GlamoStyle.ink)
            .preferredColorScheme(showingClips ? .dark : .light)
            .modifier(PlayerPagingAccess(entries: feed.entries, selectedID: $activeID,
                                         watchOptionsPresented: $watchOptionsPresented, tailID: morePageID, players: players))
            .onAppear {
                visible = true
                pauseLocalPlayback()
                players.resolveURL = { library.playbackURL(for: $0) }
                players.checkpoint = { clip, player in
                    library.recordRemotePlayback(clip, seconds: player.timeline.elapsed, duration: player.timeline.duration)
                }
                players.update(entries: feed.entries, selectedID: activeID)
            }
            .task(id: api.session?.userId.value) {
                if let initialClips {
                    guard feed.entries.isEmpty else { return }
                    feed.install(initialClips)
                    if initialCollection != nil { feed.configureCollection(nextPage: collectionNextPage, hasMore: collectionHasMore) }
                    if let initialSearchPage { feed.configureSearch(initialSearchPage) }
                    activeID = feed.entries.first(where: { $0.clip.id == selectedClipID })?.id ?? feed.entries.first?.id
                    return
                }
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
                guard initialClips == nil || initialCollection != nil || initialSearchPage != nil, visible, api.session != nil,
                      id == morePageID || feed.isNearEnd(id) else { return }
                Task { guard visible else { return }; await loadMore() }
            }
            .onChange(of: feed.hasMore) { _, hasMore in
                if initialCollection != nil, !hasMore, activeID == morePageID { activeID = feed.entries.last?.id }
            }
            .onChange(of: feed.entries) { previous, entries in
                guard visible else { return }
                if activeID == morePageID, entries.count > previous.count {
                    activeID = entries[previous.count].id
                } else if !entries.contains(where: { $0.id == activeID }) { activeID = entries.first?.id }
                players.update(entries: feed.entries, selectedID: activeID)
                if initialClips == nil, let first = entries.first?.clip, recordedQuery != feed.query {
                    recordedQuery = feed.query
                    onSearchResult(feed.query, first)
                }
            }
            .onDisappear {
                // A rewarded ad or the Plus page can temporarily cover the active player.
                if watchOptionsPresented || nestedPresentationActive {
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
            PlayerExitButton(overVideo: false, action: exitPlayer)
        }.environment(\.layoutDirection, .leftToRight)
            .padding(.horizontal, 12).padding(.top, 8)
    }
    private func exitPlayer() {
        players.releaseAll()
        dismiss()
    }
    private func loadMore() async {
        if let initialCollection { await feed.loadCollection(initialCollection, api: api) }
        else { await feed.load(api: api) }
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
    @EnvironmentObject private var library: LibraryStore
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
        return !library.requiresWatchAllowance(clip) || quota.mayWatch(clip.id, premium: commerce.premium)
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
        // Keep the task mounted while the short, noninteractive cue is hidden.
        Color.clear.frame(height: 0)
            .overlay(alignment: .bottom) {
                if showing && eligible && !alreadyShown && phase == .active {
                    HStack(spacing: 10) {
                        Image("PlayerSwipeGesture").resizable().scaledToFit()
                            .frame(width: 28, height: 28).accessibilityHidden(true)
                        LocalizedText("Swipe up or down for another video")
                            .font(.glam(.caption, weight: .medium))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: 320)
                    .modifier(DriveVideoGlass(shape: RoundedRectangle(cornerRadius: 16), shade: 0.54))
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
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
    private enum OptionsPage: Equatable { case actions, speed, quality }
    private enum FocusedAction: Hashable { case more, quality }
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var ads: RewardedAds
    @Environment(\.scenePhase) private var phase
    @Environment(\.playbackGatePresented) private var pagingGate
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    let clip: LessonClip
    let active: Bool
    // Read from the enclosing safe container; video fills the expanded viewport.
    var controlInsets = EdgeInsets()
    @ObservedObject var playback: PlaybackController
    var didStartPlaying: () -> Void = {}
    var didStopPlaying: () -> Void = {}
    let showWatchOptions: () -> Void
    var purchasePresentation: (Bool) -> Void = { _ in }
    var onSwipeExit: () -> Void = {}
    @State private var visible = false
    @State private var firstFrameReady = false
    @State private var accessChecked = false
    @State private var resumeAfterSheet = false
    @State private var resumeAfterInterruption = false
    @State private var options = false
    @State private var optionsPage = OptionsPage.actions
    @State private var fitsVideo = false
    @State private var preferredResolution = CGSize.zero
    @State private var editor = false
    @State private var fileManagement = false
    @State private var recorded = false
    @State private var allowed = false
    @State private var scrubbing = false
    @State private var favoriteError: String?
    @State private var collectOptions = false
    @State private var collectMembership = false
    @State private var resumedURL: URL?
    @State private var resumeAfterCollection = false
    private var currentClip: LessonClip { library.favorites.first { $0.id == clip.id } ?? clip }
    @AccessibilityFocusState private var focusedAction: FocusedAction?
    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: playback.player, onReadyForDisplay: { firstFrameReady = $0 },
                         preferredGravity: fitsVideo ? .resizeAspect : .resizeAspectFill)
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
        }.foregroundStyle(.white).clipped()
            .onAppear { visible = true; if active { activate() } }
            .onChange(of: active) { _, active in
                resumeAfterInterruption = false
                if active { activate() } else {
                    checkpoint()
                    favoriteError = nil
                    resumeAfterSheet = false
                    options = false
                    playback.pause()
                }
            }
            .onChange(of: playback.isPlaying) { _, playing in
                if playing, active, visible, !recorded {
                    recorded = !library.requiresWatchAllowance(clip) || quota.recordWatch(clip.id, premium: commerce.premium)
                    if !recorded { playback.pause(); allowed = false }
                }
                if playing, active, recorded { didStartPlaying() }
                if !playing, active { checkpoint(); didStopPlaying() }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                guard active, visible, playback.isPlaying, library.requiresWatchAllowance(clip) else { return }
                if !quota.recordWatch(clip.id, premium: commerce.premium) { playback.pause(); allowed = false }
            }
            .onChange(of: phase) { _, state in
                if state != .active { interruptPlayback() } else { resumeIfNeeded() }
            }
            .onChange(of: ads.isPresenting) { _, presenting in
                if presenting { interruptPlayback() } else { resumeIfNeeded() }
            }
            .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { _ in
                if active, visible, playback.isPlaying { checkpoint() }
            }
            .onChange(of: playback.error) { _, error in
                if let error, let record = library.savedVideo(clip.id), record.state == .ready,
                   playback.loadedURL == library.offlineURL(for: record) { library.offline.invalidate(clip.id, message: error) }
                if error != nil, recorded, library.requiresWatchAllowance(clip) {
                    quota.refundFailedWatch(clip.id)
                    recorded = false
                }
            }
            .onDisappear { checkpoint(); visible = false; resumeAfterInterruption = false; playback.pause() }
            .onChange(of: pagingGate) { _, presented in
                if presented { playback.pause() } else if active { activate() }
            }
            .fullScreenCover(isPresented: $editor, onDismiss: resumeAfterControls) { RemoteVideoExportView(clip: currentClip) }
            .driveDialog(isPresented: $fileManagement, onDismiss: resumeAfterControls) { DriveRemoteVideoActions(clip: currentClip) }
            .overlay {
                if collectOptions {
                    WatchLimitPrompt(showingMembership: $collectMembership, kind: .collect, finish: finishCollection)
                }
            }
            .fullScreenCover(isPresented: $collectMembership, onDismiss: {
                if commerce.premium { finishCollection() }
            }) { MembershipView() }
            .onChange(of: editor || fileManagement || collectMembership || collectOptions) { _, presented in purchasePresentation(presented) }
    }

    private var playerControls: some View {
        GeometryReader { viewport in
            let insets = resolvedControlInsets(in: viewport)
            let width = max(0, viewport.size.width - insets.leading - insets.trailing)
            let height = max(0, viewport.size.height - insets.top - insets.bottom)
            let compact = height < 400 || width < 320 || typeSize.isAccessibilitySize
            let scrollControls = height < 220 || (typeSize >= .xxxLarge && height < 360)
                || (typeSize.isAccessibilitySize && height < 520)

            VStack(spacing: compact ? 4 : 10) {
                playerHeader
                if active, let favoriteError {
                    saveFeedback(favoriteError)
                }

                ZStack {
                    Group {
                        if scrollControls {
                            ScrollView {
                                VStack(spacing: 16) {
                                    playerCenter(compact: true).padding(.vertical, 12)
                                    playerFooter
                                }
                            }
                            .scrollBounceBehavior(.basedOnSize)
                        } else {
                            VStack(spacing: 6) {
                                GeometryReader { _ in
                                    ViewThatFits(in: .vertical) {
                                        playerCenter(compact: compact).fixedSize(horizontal: false, vertical: true)
                                        ScrollView { playerCenter(compact: compact) }
                                            .scrollBounceBehavior(.basedOnSize)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .overlay(alignment: .bottom) {
                                        PlayerSwipeHint(eligible: active && visible && firstFrameReady &&
                                                        playback.error == nil && !playback.isLoading &&
                                                        !pagingGate && !options && !editor && !ads.isPresenting)
                                            .padding(.bottom, 8)
                                    }
                                }
                                playerFooter
                            }
                        }
                    }
                    .disabled(options)
                    .accessibilityHidden(options)

                    if options { playerOptions }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, compact ? 4 : 8).padding(.bottom, 4)
            .padding(insets)
        }
    }

    private var playerHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            PlayerExitButton(action: onSwipeExit)
            Text(verbatim: currentClip.title)
                .font(.glam(.footnote, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.65), radius: 3, y: 1)
                .accessibilityLabel(currentClip.title)
            Button {
                if options {
                    closeOptions()
                } else {
                    resumeAfterSheet = playback.intendsPlayback
                    playback.pause()
                    fileManagement = true
                }
            } label: {
                Glyph(symbol: .driveMore, size: 19, tint: .white)
            }
            .buttonStyle(DriveVideoButtonStyle())
            .accessibilityLabel("Playback options")
            .accessibilityFocused($focusedAction, equals: .more)
            .accessibilityIdentifier("player.options")
        }
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func playerCenter(compact: Bool) -> some View {
        if active, visible, !pagingGate, !editor {
            VStack(spacing: 16) {
                if accessChecked, !allowed {
                    playerNotice(title: quota.canRequestReward(for: .watch, premium: commerce.premium)
                                 ? "Daily viewing limit reached" : "Playback unavailable",
                                 actionTitle: "Get more views", action: showWatchOptions)
                } else {
                    if let error = playback.error {
                        playerNotice(title: "Couldn’t play this video", message: error, actionTitle: "Retry") {
                            activate(reload: true)
                        }
                    } else if allowed, playback.isLoading || (!firstFrameReady && playback.intendsPlayback) {
                        PlayerLoadingFeedback(buffering: firstFrameReady).allowsHitTesting(false)
                    }
                    DrivePlaybackControls(playback: playback, overVideo: true, compact: compact)
                        .disabled(!canControlPlayback || !firstFrameReady)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var playerFooter: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { openOptions(.actions) } label: {
                    Glyph(symbol: .driveSettings, size: 17, tint: .white)
                }
                .buttonStyle(DriveVideoButtonStyle())
                .accessibilityLabel("Playback options")
                .accessibilityFocused($focusedAction, equals: .quality)
                .accessibilityValue(Text(verbatim: driveRateText(playback.speed, locale: locale)))
                fitButton
            }
            PlayerProgressControl(playback: playback, timeline: playback.timeline,
                                  enabled: allowed && firstFrameReady,
                                  canResume: canControlPlayback,
                                  scrubbing: $scrubbing, tint: DriveStyle.accent,
                                  showsInlineTimes: true, overVideo: true)
                .padding(.horizontal, 12)
                .modifier(DriveVideoGlass(shape: RoundedRectangle(cornerRadius: 22)))
        }
        .frame(maxWidth: 840).frame(maxWidth: .infinity)
    }

    private var saveButton: some View {
        let saved = library.isSaved(clip)
        return Button(action: save) {
            HStack(spacing: 6) {
                AssetMask(name: saved ? "PlayerSaved" : "PlayerSave", tint: .white)
                    .frame(width: 16, height: 16)
                LocalizedText(saved ? "Saved" : "Save")
                    .font(.glam(.caption, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(DriveVideoButtonStyle(prominent: saved))
        .accessibilityLabel(LocalizedStringKey(saved ? "Remove saved video" : "Save video"))
        .accessibilityAddTraits(saved ? .isSelected : [])
        .accessibilityIdentifier("player.save")
    }

    private var playbackSettings: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { speedButton; qualityButton; fitButton }
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) { speedButton; fitButton }
                qualityButton
            }
        }
    }

    private var speedButton: some View {
        DriveSpeedButton(playback: playback, compact: true, showingVideoRates: Binding(
            get: { options && optionsPage == .speed },
            set: { if $0 { openOptions(.speed) } else { closeOptions() } }
        ))
    }

    private var qualityButton: some View {
        Button { openOptions(.quality) } label: {
            HStack(spacing: 6) {
                Glyph(symbol: .driveSettings, size: 15, tint: .white)
                LocalizedText("Resolution")
                    .font(.glam(.caption, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(DriveVideoButtonStyle())
        .accessibilityFocused($focusedAction, equals: .quality)
        .accessibilityIdentifier("player.quality")
    }

    private var fitButton: some View {
        Button { fitsVideo.toggle() } label: {
            Glyph(symbol: .driveExpand, size: 17, tint: .white)
        }
        .buttonStyle(DriveVideoButtonStyle())
        .accessibilityLabel(LocalizedStringKey(fitsVideo ? "Fill screen" : "Fit video"))
        .accessibilityAddTraits(fitsVideo ? .isSelected : [])
    }

    @ViewBuilder
    private var playerOptions: some View {
        switch optionsPage {
        case .speed:
            DriveVideoSpeedOverlay(playback: playback, close: closeOptions)
        case .quality:
            LinkedVideoQualityPicker(playback: playback, selected: $preferredResolution, close: closeOptions)
        case .actions:
            DriveVideoBottomOverlay(title: "Playback options", columnWidth: 164, close: closeOptions) { columns in
                ViewThatFits(in: .vertical) {
                    optionItems(columns: columns).fixedSize(horizontal: false, vertical: true)
                    ScrollView { optionItems(columns: columns) }.scrollBounceBehavior(.basedOnSize)
                }
            }
        }
    }

    private func optionItems(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 4) {
            optionButton("Playback speed") { openOptions(.speed) }
            optionButton("Resolution") { openOptions(.quality) }
        }
    }

    private func optionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LocalizedText(title).font(.glam(.subheadline, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func playerNotice(title: String, message: String? = nil, actionTitle: String,
                              action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LocalizedText(title).font(.glam(.headline))
                .accessibilityAddTraits(.isHeader)
            if let message {
                LocalizedText(message).font(.glam(.subheadline)).foregroundStyle(.white.opacity(0.86))
            }
            Button(action: action) {
                LocalizedText(actionTitle).font(.glam(.subheadline, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(DriveStyle.link, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
            }.buttonStyle(PressStyle())
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16).frame(maxWidth: 360)
        .modifier(DriveVideoGlass(shape: RoundedRectangle(cornerRadius: 22), shade: 0.66))
    }

    private func saveFeedback(_ message: String) -> some View {
        HStack(spacing: 10) {
            LocalizedText(message).font(.glam(.caption))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { favoriteError = nil } label: {
                Glyph(symbol: .close, size: 14, tint: .white)
            }
            .buttonStyle(DriveVideoButtonStyle())
            .accessibilityLabel("Dismiss message")
        }
        .padding(10)
        .modifier(DriveVideoGlass(shape: RoundedRectangle(cornerRadius: 18), shade: 0.66))
    }

    private var canControlPlayback: Bool {
        active && visible && allowed && phase == .active && !ads.isPresenting &&
            !pagingGate && !options && !editor
    }

    private func openOptions(_ page: OptionsPage) {
        if !options {
            resumeAfterSheet = playback.intendsPlayback
            playback.pause()
        }
        optionsPage = page
        options = true
    }

    private func closeOptions() {
        options = false
        focusedAction = .quality
        resumeAfterControls()
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
              !options, !editor, !fileManagement, !collectOptions else { return }
        recorded = false
        accessChecked = true
        allowed = !library.requiresWatchAllowance(clip) || quota.mayWatch(clip.id, premium: commerce.premium)
        if !allowed {
            playback.pause()
            // Paging owns automatic prompts; this page retains the explicit reward action.
            return
        }
        let source = library.playbackURL(for: clip)
        if playback.loadedURL != source || reload {
            firstFrameReady = false
            preferredResolution = .zero
            playback.load(source, autoplay: false)
        }
        if resumedURL != source || reload {
            resumedURL = source
            playback.setSpeed(PlaybackPreferences.shared.speed)
            if PlaybackPreferences.shared.resume,
               let position = library.remotePlayback.first(where: { $0.id == clip.id })?.viewing,
               position.seconds > 0, position.seconds < position.duration - 1 { playback.seek(position.seconds) }
        }
        playback.play()
    }
    private func resumeAfterControls() {
        guard resumeAfterSheet, active, visible, phase == .active,
              !ads.isPresenting, !pagingGate, !options, !editor, !fileManagement, !collectOptions else { return }
        resumeAfterSheet = false
        activate()
    }
    private func interruptPlayback() {
        if active, visible, playback.intendsPlayback { resumeAfterInterruption = true }
        playback.pause()
    }
    private func resumeIfNeeded() {
        guard resumeAfterInterruption || resumeAfterSheet, active, visible, phase == .active,
              !ads.isPresenting, !pagingGate, !options, !editor, !fileManagement, !collectOptions else { return }
        resumeAfterInterruption = false
        resumeAfterSheet = false
        activate()
    }
    private func save() {
        favoriteError = nil
        if !library.isSaved(clip), !quota.mayCollect(premium: commerce.premium) {
            resumeAfterCollection = playback.intendsPlayback || resumeAfterSheet
            playback.pause()
            collectOptions = true
            return
        }
        var charged = false
        do {
            if library.isSaved(clip) { try library.removeSavedVideo(clip.id) }
            else {
                try quota.recordCollection(premium: commerce.premium)
                charged = !commerce.premium
                try library.saveVideo(clip)
            }
        } catch {
            if charged { quota.refundCollection() }
            favoriteError = error.localizedDescription
        }
    }
    private func finishCollection() {
        collectOptions = false
        if !library.isSaved(clip), quota.mayCollect(premium: commerce.premium) { save() }
        if resumeAfterCollection {
            resumeAfterCollection = false
            resumeAfterSheet = false
            activate()
        }
    }
    private func checkpoint() {
        guard recorded, playback.error == nil else { return }
        library.recordRemotePlayback(clip, seconds: playback.timeline.elapsed, duration: playback.timeline.duration)
    }
}

private struct LinkedVideoQualityPicker: View {
    private struct Resolution: Identifiable {
        let size: CGSize
        var id: String { "\(size.width)×\(size.height)" }
        var label: String { "\(Int(min(size.width, size.height).rounded()))p" }
    }

    @ObservedObject var playback: PlaybackController
    @Binding var selected: CGSize
    let close: () -> Void
    @State private var resolutions: [Resolution] = []
    @State private var checking = true
    @State private var loadError: String?
    @State private var refreshID = UUID()
    @ScaledMetric(relativeTo: .subheadline) private var columnWidth: CGFloat = 144

    var body: some View {
        DriveVideoBottomOverlay(title: "Resolution", columnWidth: columnWidth, close: close) { columns in
            ViewThatFits(in: .vertical) {
                choices(columns: columns).fixedSize(horizontal: false, vertical: true)
                ScrollView { choices(columns: columns) }.scrollBounceBehavior(.basedOnSize)
            }
        }
        .task(id: refreshID) { await inspectVideo() }
    }

    @ViewBuilder
    private func choices(columns: [GridItem]) -> some View {
        if checking {
            LocalizedText("Checking video quality…")
                .font(.glam(.subheadline)).padding(12)
        } else if let loadError {
            VStack(alignment: .leading, spacing: 8) {
                LocalizedText("Couldn’t load video quality.").font(.glam(.subheadline, weight: .semibold))
                Text(verbatim: loadError).font(.glam(.caption)).foregroundStyle(DriveStyle.secondary)
                Button { refreshID = UUID() } label: {
                    LocalizedText("Retry").font(.glam(.subheadline, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }.buttonStyle(DriveVideoButtonStyle(prominent: true))
            }
            .fixedSize(horizontal: false, vertical: true).padding(8)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: columns, spacing: 4) {
                    choice(resolutions.count > 1 ? "Auto" : "Original", size: .zero)
                    if resolutions.count > 1 {
                        ForEach(resolutions) { resolution in
                            choice("Up to %@", value: resolution.label, size: resolution.size)
                        }
                    }
                }
                LocalizedText(resolutions.count > 1
                              ? "Supported streams adjust quality to your connection."
                              : "This video plays at its original resolution.")
                    .font(.glam(.caption)).foregroundStyle(DriveStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
        }
    }

    private func choice(_ title: String, value: String? = nil, size: CGSize) -> some View {
        let isSelected = selected == size
        return Button {
            guard let item = playback.player.currentItem else { return }
            // Apply a real HLS resolution ceiling without replacing or restarting the item.
            item.preferredMaximumResolution = size
            selected = size
            close()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if let value { LocalizedText(title, value) }
                else { LocalizedText(title) }
                if isSelected {
                    LocalizedText("Selected").font(.glam(.caption, weight: .semibold))
                }
            }
            .font(.glam(.subheadline, weight: isSelected ? .semibold : .medium))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .foregroundStyle(isSelected ? DriveStyle.accent : DriveStyle.ink)
            .background(isSelected ? DriveStyle.accent.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func inspectVideo() async {
        checking = true
        loadError = nil
        guard let item = playback.player.currentItem, let asset = item.asset as? AVURLAsset else {
            loadError = L10n.display("Playback unavailable")
            checking = false
            return
        }
        selected = item.preferredMaximumResolution
        do {
            let variants = try await asset.load(.variants)
            guard !Task.isCancelled, playback.player.currentItem === item else { return }
            var seen = Set<String>()
            resolutions = variants.compactMap { variant -> Resolution? in
                guard let size = variant.videoAttributes?.presentationSize,
                      size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0, max(size.width, size.height) < 100_000 else { return nil }
                let resolution = Resolution(size: size)
                return seen.insert(resolution.id).inserted ? resolution : nil
            }.sorted { min($0.size.width, $0.size.height) < min($1.size.width, $1.size.height) }
        } catch {
            guard !Task.isCancelled, playback.player.currentItem === item else { return }
            if item.status == .readyToPlay, item.presentationSize != .zero {
                resolutions = [] // A fixed-quality file has no alternate HLS variants.
            } else {
                loadError = error.localizedDescription
            }
        }
        checking = false
    }
}

private struct PlayerExitButton: View {
    @Environment(\.layoutDirection) private var layoutDirection
    var overVideo = true
    let action: () -> Void
    var body: some View {
        let button = Button(action: action) {
            Glyph(symbol: .back, size: 17, tint: overVideo ? .white : GlamoStyle.ink)
                .rotationEffect(.degrees(layoutDirection == .rightToLeft ? 180 : 0))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        return Group {
            if overVideo {
                button.buttonStyle(DriveVideoButtonStyle())
            } else {
                button.buttonStyle(PressStyle())
                    .glamoGlass(in: Capsule(), tint: GlamoStyle.paper, interactive: true)
            }
        }
        .accessibilityLabel(LocalizedStringKey("Exit"))
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
                .foregroundStyle(.white)
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
