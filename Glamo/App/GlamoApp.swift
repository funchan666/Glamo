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
        .accessibilityLabel("Opening Glamo…")
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
    case files, recent, activity, settings

    var name: String {
        switch self {
        case .files: "Files"
        case .recent: "Recent"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    var symbol: GlamoGlyph {
        switch self {
        case .files: .driveFolder
        case .recent: .driveRecent
        case .activity: .driveActivity
        case .settings: .driveSettings
        }
    }
}

struct GlamoRootView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.self) private var environment
    @SceneStorage("drive.tab") private var tab: GlamoTab = .files
    @StateObject private var player = DrivePlaybackSession()
    @State private var searching = false
    @State private var searchRequested = false
    @State private var activityFilter = DriveActivityFilter.all

    var body: some View {
        GeometryReader { container in
            let floating = usesFloatingTabs(in: container)
            let visibility: Visibility = floating ? .hidden : .automatic
            let pane = drivePaneMargins(in: container)
            let dockedMovie = player.expanded ? nil : library.movies.first { $0.id == player.currentID }
            TabView(selection: $tab) {
                DriveBrowser(isSearching: $searching, searchRequested: $searchRequested,
                             play: open, pausePlayback: player.pause,
                             showActivity: {
                                 activityFilter = .imports
                                 tab = .activity
                             })
                    .toolbar(visibility, for: .tabBar)
                    .tabItem { tabLabel(.files) }.tag(GlamoTab.files)
                DriveRecentView(play: open, browse: { tab = .files }, search: openFileSearch, showActivity: openActivity)
                    .padding(pane)
                    .toolbar(visibility, for: .tabBar)
                    .tabItem { tabLabel(.recent) }.tag(GlamoTab.recent)
                DriveActivityView(filter: $activityFilter, play: open, browse: { tab = .files })
                    .padding(pane)
                    .toolbar(visibility, for: .tabBar)
                    .tabItem { tabLabel(.activity) }.tag(GlamoTab.activity)
                AccountView(browse: { tab = .files }, showActivity: openActivity)
                    .padding(pane)
                    .toolbar(visibility, for: .tabBar)
                    .tabItem { tabLabel(.settings) }.tag(GlamoTab.settings)
            }
            .modifier(GlamoTabBarAppearance())
            .toolbarColorScheme(.light, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if (!searching || tab != .files), floating || dockedMovie != nil {
                    VStack(spacing: 5) {
                        if let movie = dockedMovie {
                            DriveMiniPlayer(playback: player.playback, movie: movie,
                                            expand: { player.expanded = true }, close: player.stop)
                                .pageHorizontalMargins()
                                .padding(pane)
                        }
                        if floating {
                            GlamoTabDock(selection: $tab).padding(.horizontal, 16)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .glamoScreenBackground(GlamoStyle.background)
        .foregroundStyle(GlamoStyle.ink)
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

    private func usesFloatingTabs(in container: GeometryProxy) -> Bool {
        guard environment.horizontalSizeClass == .compact,
              environment.verticalSizeClass == .regular,
              environment.dynamicTypeSize <= .xxLarge,
              container.size.width >= 300 else { return false }
        if #available(iOS 27.1, *) {
            if environment.toolbarVerticalEdge != nil { return false }
            let bounds = CGRect(origin: .zero, size: container.size)
            if container.reservedRegions(kind: .division).contains(where: { $0.isActive && bounds.intersects($0.frame) }) {
                return false
            }
            let dockBand = CGRect(x: 0, y: max(0, bounds.height - 135), width: bounds.width, height: 135)
            if container.reservedRegions(kind: .occlusion).contains(where: { $0.isActive && dockBand.intersects($0.frame) }) {
                return false
            }
        }
        return true
    }

    private func open(_ file: PracticeRecording, _ files: [PracticeRecording]) {
        player.open(file, among: files, library: library)
    }

    private func openFileSearch() {
        tab = .files
        searchRequested = true
    }

    private func openActivity() {
        activityFilter = .all
        tab = .activity
    }

    private func tabLabel(_ item: GlamoTab) -> some View {
        Label { LocalizedText(item.name) } icon: { Image(item.symbol.assetName).renderingMode(.template) }
            .accessibilityIdentifier("tab.\(item.name.lowercased())")
    }
}

private struct GlamoTabDock: View {
    @Binding var selection: GlamoTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 3) {
            ForEach(GlamoTab.allCases, id: \.self) { item in
                let selected = selection == item
                Button { selection = item } label: {
                    VStack(spacing: 3) {
                        Image(item.symbol.assetName).renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 22, height: 22)
                            .accessibilityHidden(true)
                        LocalizedText(item.name).font(.glam(.caption, weight: selected ? .semibold : .medium))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(selected ? GlamoStyle.accent : GlamoStyle.secondary)
                    .background {
                        if selected {
                            let shape = RoundedRectangle(cornerRadius: 14)
                            shape.fill(GlamoStyle.paperMuted)
                                .overlay { shape.strokeBorder(GlamoStyle.accent.opacity(0.22)) }
                                .matchedGeometryEffect(id: "selected", in: indicator)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("tab.\(item.name.lowercased())")
            }
        }
        .padding(4)
        .frame(maxWidth: 400)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.surface)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selection)
    }
}

private struct GlamoTabBarAppearance: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.toolbarBackground(.regularMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
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
                MessagePanel(title: "Couldn’t connect to Glamo", message: error)
                ActionButton(title: "Try again", busy: connecting) { attempt += 1 }
            } else {
                AccountLoadingIndicator(title: "Connecting to Glamo…")
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
