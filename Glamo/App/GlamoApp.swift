import SwiftUI
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
    @StateObject private var offline: OfflineStore
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
        _offline = StateObject(wrappedValue: OfflineStore(api: api, quota: quota, commerce: commerce))
        _ads = StateObject(wrappedValue: RewardedAds())
    }
    var body: some Scene {
        WindowGroup {
            GlamoStartupHost().environmentObject(api).environmentObject(library)
                .environmentObject(quota).environmentObject(commerce).environmentObject(ads).environmentObject(offline)
                .environmentObject(accountAccess)
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.direction)
                .font(.glam(.body))
                .preferredColorScheme(.dark).tint(GlamoStyle.accent)
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
            Color("LaunchBackground").ignoresSafeArea()
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
        Image("GlamoLaunchMark")
            .resizable().scaledToFit().frame(width: 108, height: 108)
            .overlay(alignment: .bottom) {
                Image("GlamoLoadingMark")
                    .resizable().scaledToFill().frame(width: 40, height: 5).clipped()
                    .phaseAnimator([false, true]) { content, dimmed in
                        content.opacity(reduceMotion || scenePhase != .active ? 1 : (dimmed ? 0.35 : 1))
                    } animation: { _ in
                        reduceMotion || scenePhase != .active ? nil : .easeInOut(duration: 0.6)
                    }
                    .offset(y: 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .all)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Glamo is starting")
            .background(Color("LaunchBackground").ignoresSafeArea())
    }
}

enum GlamoTab: Int, CaseIterable, Hashable {
    case home, discover, tools, library, me
    var name: String { ["Home", "Discover", "Tools", "Library", "Me"][rawValue] }
    // Original template artwork; the system tab bar tints selection.
    var artwork: String { ["TabHome", "TabDiscover", "TabTools", "TabLibrary", "TabMe"][rawValue] }
}

// System TabView so the bar can move to the vertical side position on iPhone Duo
// (outer display, inner display landscape) and follow every other platform rule.
struct GlamoRootView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var offline: OfflineStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: GlamoTab = .home
    @State private var editing: PracticeRecording?
    @State private var linkDraft = ""
    @State private var libraryFilter = "Saved"
    var body: some View {
        TabView(selection: $tab) {
            HomeView(openAccount: { tab = .me }, discover: { tab = .discover }, openTools: { tab = .tools }, link: $linkDraft)
                .tabItem { tabLabel(.home) }.tag(GlamoTab.home)
            DiscoverView(onExit: { tab = .home })
                .tabItem { tabLabel(.discover) }.tag(GlamoTab.discover)
            ToolsView()
                .tabItem { tabLabel(.tools) }.tag(GlamoTab.tools)
            LibraryView(edit: { editing = $0 }, filter: $libraryFilter)
                .tabItem { tabLabel(.library) }.tag(GlamoTab.library)
            AccountView()
                .tabItem { tabLabel(.me) }.tag(GlamoTab.me)
        }
        .toolbarBackground(GlamoStyle.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .foregroundStyle(.white)
            .sheet(item: $editing) { EditorSheet(initialMovie: $0) }
            .overlay(alignment: .top) {
                if tab != .discover { DownloadCompletionNotice().padding(.top, 8) }
            }
            .task(id: library.downloadsRequest) {
                guard library.downloadsRequest != nil else { return }
                // Full-screen players dismiss first; then move the underlying tab.
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                editing = nil
                libraryFilter = "Downloads"
                tab = .library
            }
            .task(id: api.session?.userId.value) {
                guard api.session != nil else { return }
                if !commerce.rightsVerified || commerce.release == nil { await commerce.refresh() }
                await offline.resumePending()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { quota.resetIfNeeded() }
            }
            .overlay(alignment: .top) {
                if let message = library.error {
                    HStack {
                        LocalizedText(message).font(.glam(.subheadline))
                        IconButton(symbol: .close, label: "Dismiss message") { library.error = nil }
                    }.padding(14).background(GlamoStyle.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).padding()
                }
            }
            .modifier(AccountBusyModifier())
    }
    // Title and original image together: the vertical bar shows the image,
    // overflow menus show both. Text-only items would not move to the side.
    private func tabLabel(_ item: GlamoTab) -> some View {
        Label { LocalizedText(item.name) } icon: { Image(item.artwork).renderingMode(.template) }
            .accessibilityIdentifier("tab.\(item.name.lowercased())")
    }
}

// A network recovery surface, not a second login or consent gate.
struct ConnectionPanel: View {
    @EnvironmentObject private var api: APIClient
    @State private var error: String?
    @State private var connecting = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 24) {
            GlamArtwork(kind: .vanity, height: 170)
            if let error {
                MessagePanel(title: "Let’s reconnect.", message: error)
                ActionButton(title: "Try again", busy: connecting) { attempt += 1 }
            } else {
                AccountLoadingIndicator(title: "Setting up your vanity…")
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
