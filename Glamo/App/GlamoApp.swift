import SwiftUI
import Combine
import OSLog

@main
struct GlamoApp: App {
    @AppStorage(AppLanguage.preferenceKey) private var languageCode = AppLanguage.systemSelection
    @Environment(\.scenePhase) private var appPhase
    @State private var systemLanguage = AppLanguage.systemLanguage()
    private var language: AppLanguage { AppLanguage(rawValue: languageCode) ?? systemLanguage }
    @StateObject private var api: APIClient
    @StateObject private var library: LibraryStore
    @StateObject private var quota: QuotaStore
    @StateObject private var commerce: CommerceStore
    @StateObject private var ads: RewardedAds
    @StateObject private var accountAccess = AccountAccessFlow()
    init() {
        let api = APIClient()
        let quota = QuotaStore()
        _api = StateObject(wrappedValue: api)
        _library = StateObject(wrappedValue: LibraryStore())
        _quota = StateObject(wrappedValue: quota)
        let commerce = CommerceStore(api: api, quota: quota)
        _commerce = StateObject(wrappedValue: commerce)
        _ads = StateObject(wrappedValue: RewardedAds())
    }
    var body: some Scene {
        WindowGroup {
            GlamoStartupHost().environmentObject(api).environmentObject(library)
                .environmentObject(quota).environmentObject(commerce).environmentObject(ads)
                .environmentObject(accountAccess)
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.direction)
                .font(.glam(.body))
                .preferredColorScheme(.light).tint(GlamoStyle.accent)
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    systemLanguage = AppLanguage.systemLanguage()
                }
                .onChange(of: appPhase) { _, phase in
                    if phase == .active { systemLanguage = AppLanguage.systemLanguage() }
                }
        }
    }
}

// Keeps the original splash visible during the bounded cold-start ad opportunity.
// Guest authentication prepares configuration and opens the app directly.
struct GlamoStartupHost: View {
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finished = false
    @State private var startupBegan = ContinuousClock.now

    var body: some View {
        ZStack {
            GlamoStyle.background.ignoresSafeArea()
            // Mount once so local content and authentication prepare while the
            // bounded app-open opportunity runs, without rebuilding navigation.
            GlamoRootView()
                .allowsHitTesting(finished)
                .accessibilityHidden(!finished)
            if !finished {
                GlamoStartupView().transition(.opacity)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, !finished else { return }
            ads.beginStartup(commerce: commerce, accountAccess: accountAccess)
        }
        .onReceive(ads.$startupFinished) { complete in
            if complete, !finished {
                Logger(subsystem: "com.glamo.video", category: "Startup")
                    .info("Home became interactive after \(startupBegan.duration(to: .now).description, privacy: .public)")
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { finished = true }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { ads.didEnterBackground() }
            if phase == .active, finished {
                ads.didBecomeActive(commerce: commerce, accountAccess: accountAccess)
            }
        }
    }
}

struct GlamoStartupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { container in
            let pane = drivePaneMargins(in: container, includesHorizontalFold: true)
            let width = max(0, container.size.width - pane.leading - pane.trailing)
            let height = max(0, container.size.height - pane.top - pane.bottom)
            let loadingSize: CGFloat = 32
            let spacing: CGFloat = 18
            let margin: CGFloat = 8
            // Match LaunchScreen's preferred icon size, center and minimum margins.
            let iconSize = max(0, min(108, width - 2 * margin, height - 2 * margin - spacing - loadingSize))
            let stackHeight = iconSize + spacing + loadingSize
            let centerY = min(height / 2 + (spacing + loadingSize) / 2, height - margin - stackHeight / 2)

            VStack(spacing: spacing) {
                Image("GlamoLaunchMark")
                    .resizable().scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                loadingMark
                    .frame(width: loadingSize, height: loadingSize)
            }
            .position(x: width / 2, y: centerY)
            .frame(width: width, height: height)
            .padding(pane)
        }
        .background(Color("LaunchBackground").ignoresSafeArea())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening Vifol…")
    }

    private var loadingMark: some View {
        let artwork = Image("GlamoLaunchLoading").renderingMode(.template).resizable().scaledToFit()

        return artwork.foregroundStyle(Color("LaunchLoadingTint"))
            .overlay {
                if !reduceMotion && scenePhase == .active {
                    Color.clear.phaseAnimator([false, true]) { content, passed in
                        content.overlay {
                            LinearGradient(colors: [.clear, GlamoStyle.accent, .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 14)
                                .offset(y: passed ? 24 : -24)
                        }
                    } animation: { _ in .easeInOut(duration: 0.72) }
                    .mask { artwork }
                }
            }
    }
}

enum GlamoTab: Int, CaseIterable, Hashable {
    case recent, files, profile

    var name: String {
        switch self {
        case .files: "Files"
        case .recent: "Home"
        case .profile: "Profile"
        }
    }

    var symbol: GlamoGlyph {
        switch self {
        case .files: .driveFolder
        case .recent: .driveRecent
        case .profile: .driveSettings
        }
    }
}

struct GlamoRootView: View {
    private enum Destination: Hashable {
        case search
        case activity
        case history(DriveRecentView.History)
    }

    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var phase
    @SceneStorage("drive.mainTab") private var tab: GlamoTab = .recent
    @StateObject private var player = DrivePlaybackSession()
    @State private var destinations: [Destination] = []
    @State private var searching = false
    @State private var folderOpen = false
    @State private var activityFilter = DriveActivityFilter.all

    var body: some View {
        GeometryReader { container in
            let pane = drivePaneMargins(in: container, includesHorizontalFold: true)
            let dockedMovie = player.expanded ? nil : library.movies.first { $0.id == player.currentID }
            let isMainPage = destinations.isEmpty && (tab != .files || !folderOpen)
            let hidesMiniPlayer = destinations.last == .search && searching
            NavigationStack(path: $destinations) {
                tabs
                    .navigationDestination(for: Destination.self) { destination in
                        destinationView(destination)
                            .toolbar(.hidden, for: .navigationBar)
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isMainPage || (dockedMovie != nil && !hidesMiniPlayer) {
                    VStack(spacing: 5) {
                        if let movie = dockedMovie, !hidesMiniPlayer {
                            DriveMiniPlayer(playback: player.playback, movie: movie,
                                            expand: { player.expanded = true }, close: player.stop)
                                .pageHorizontalMargins()
                        }
                        if isMainPage {
                            GlamoTabDock(selection: $tab,
                                         compact: container.size.height - pane.top - pane.bottom < 420)
                                .padding(.horizontal, DriveStyle.pageInset)
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.bottom, dockClearance(in: container, pane: pane, includesPlayer: dockedMovie != nil))
                }
            }
            .padding(pane)
        }
        .driveScreenBackground()
        .fullScreenCover(isPresented: $player.expanded) { DrivePlayerView(session: player) }
        .onReceive(player.playback.$isPlaying.removeDuplicates()) { playing in
            if playing { player.markStarted() }
        }
        .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { _ in
            player.checkpoint()
        }
        .task(id: api.session?.userId.value) {
            guard api.session != nil else { return }
            if !commerce.rightsVerified || commerce.release == nil { await commerce.refresh() }
        }
        .onChange(of: phase) { _, value in
            if value == .active { quota.resetIfNeeded() }
            else { player.pause() }
        }
        .onChange(of: library.movies.map(\.id)) { _, ids in
            if let current = player.currentID, !ids.contains(current) { player.stop() }
        }
        .overlay(alignment: .top) {
            if let message = library.error {
                HStack(spacing: 8) {
                    ErrorNote(message: message)
                    IconButton(symbol: .close, label: "Dismiss message") { library.error = nil }
                }.padding(.horizontal, 12).glamoCard(radius: 14)
                    .pageHorizontalMargins().padding(.top, 8)
            }
        }
        .modifier(AccountBusyModifier())
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            recentPage()
                .toolbar(.hidden, for: .tabBar)
                .tabItem { tabLabel(.recent) }.tag(GlamoTab.recent)
            DriveBrowser(surface: .files(search: openFileSearch, profile: { tab = .profile }),
                         isSearching: .constant(false), play: open, pausePlayback: player.pause,
                         showActivity: { openActivity(.imports) }, folderVisibility: { folderOpen = $0 })
                .toolbar(.hidden, for: .tabBar)
                .tabItem { tabLabel(.files) }.tag(GlamoTab.files)
            AccountView(browse: openFiles, showActivity: { openActivity(.all) })
                .toolbar(.hidden, for: .tabBar)
                .tabItem { tabLabel(.profile) }.tag(GlamoTab.profile)
        }
        .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .search:
            DriveBrowser(surface: .search(close: closeDestination), isSearching: $searching,
                         play: open, pausePlayback: player.pause, showActivity: { openActivity(.imports) })
        case .activity:
            DriveActivityView(filter: $activityFilter, play: open, browse: openFiles, back: closeDestination)
        case .history(let history):
            recentPage(history)
        }
    }

    private func recentPage(_ history: DriveRecentView.History? = nil) -> some View {
        DriveRecentView(history: history, play: open, pausePlayback: player.pause, browse: openFiles,
                        search: openFileSearch, showActivity: { openActivity(.all) },
                        showProfile: { tab = .profile }, showHistory: { destinations.append(.history($0)) },
                        back: closeDestination)
    }

    private func dockClearance(in container: GeometryProxy, pane: EdgeInsets, includesPlayer: Bool) -> CGFloat {
        guard #available(iOS 27.1, *) else { return 0 }
        let width = max(0, container.size.width - pane.leading - pane.trailing)
        let bottom = container.size.height - pane.bottom
        let dockWidth = min(width, includesPlayer ? 560 : DriveStyle.tabWidth)
        let dockHeight = min(max(0, bottom - pane.top), includesPlayer ? 144 : 84)
        let band = CGRect(x: pane.leading + (width - dockWidth) / 2, y: bottom - dockHeight,
                          width: dockWidth, height: dockHeight)
        return container.reservedRegions(kind: .occlusion)
            .filter { $0.isActive && $0.frame.intersects(band) }
            .map { bottom - $0.frame.minY + 6 }
            .max() ?? 0
    }

    private func open(_ file: PracticeRecording, _ files: [PracticeRecording]) {
        player.open(file, among: files, library: library)
    }

    private func openFileSearch() {
        if destinations.last != .search { destinations.append(.search) }
    }

    private func openActivity(_ filter: DriveActivityFilter) {
        activityFilter = filter
        if destinations.last != .activity { destinations.append(.activity) }
    }

    private func closeDestination() {
        if !destinations.isEmpty { destinations.removeLast() }
    }

    private func openFiles() {
        tab = .files
        destinations.removeAll()
    }

    private func tabLabel(_ item: GlamoTab) -> some View {
        Label { LocalizedText(item.name) } icon: { Image(item.symbol.assetName).renderingMode(.template) }
            .accessibilityIdentifier("tab.\(item.name.lowercased())")
    }
}

private struct GlamoTabDock: View {
    @Binding var selection: GlamoTab
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    var body: some View {
        let labelLayout = compact ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 2))
        HStack(spacing: 3) {
            ForEach(GlamoTab.allCases, id: \.self) { item in
                let selected = selection == item
                Button { selection = item } label: {
                    labelLayout {
                        Image(item.symbol.assetName).renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        LocalizedText(item.name).driveFont(10, relativeTo: .caption2, weight: .medium)
                            .multilineTextAlignment(.center)
                            .lineLimit(2).minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: compact ? 44 : 56)
                    .foregroundStyle(selected ? DriveStyle.accent : DriveStyle.ink)
                    .background {
                        if selected {
                            Capsule().fill(DriveStyle.selectedTab)
                                .matchedGeometryEffect(id: "selected", in: indicator)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(LocalizedStringKey(item.name))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("tab.\(item.name.lowercased())")
            }
        }
        .padding(4)
        .frame(maxWidth: DriveStyle.tabWidth)
        .glamoGlass(in: Capsule(), tint: .white)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selection)
    }
}

// A network recovery surface, not a second login or consent gate.
struct ConnectionPanel: View {
    @EnvironmentObject private var api: APIClient
    @State private var error: String?
    @State private var connecting = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 16) {
            if let error {
                MessagePanel(title: "Couldn’t connect to Vifol", message: error)
                ActionButton(title: "Try again", busy: connecting) { attempt += 1 }
            } else {
                AccountLoadingIndicator(title: "Connecting to Vifol…")
            }
            PolicyLinks()
        }
        .frame(maxWidth: 440).frame(maxWidth: .infinity)
        .task(id: attempt) {
            guard api.session == nil else { return }
            connecting = true
            error = nil
            defer { connecting = false }
            do { try await api.prepareVisitor() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
