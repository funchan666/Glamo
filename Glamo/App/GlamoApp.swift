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
            .accessibilityLabel("Opening Glamo…")
            .background(Color("LaunchBackground").ignoresSafeArea())
    }
}

enum GlamoTab: Int, CaseIterable, Hashable {
    case home = 0, tools = 1, library = 2, account = 3
    var name: String { ["Videos", "Tools", "Files", "Me"][rawValue] }
    // Original artwork shared by the floating dock and the system tab bar.
    var artwork: String { ["GlyphFeed", "TabDiscover", "GlyphFolder", "GlyphSettings"][rawValue] }
}

// Keep the selected tab and its content mounted when switching between bars.
struct GlamoRootView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @EnvironmentObject private var offline: OfflineStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.self) private var environment
    @SceneStorage("root.tab") private var tab: GlamoTab = .home
    @State private var editing: PracticeRecording?
    @State private var previewing: PracticeRecording?
    @SceneStorage("home.linkDraft") private var linkDraft = ""
    @State private var libraryFilter = "All"
    @State private var showingLessons = false
    @State private var lessonsDownloadRequest: UUID?
    var body: some View {
        GeometryReader { container in
            let floating = usesFloatingTabs(in: container)
            let visibility: Visibility = floating ? .hidden : .automatic
            TabView(selection: $tab) {
                HomeView(edit: { if tab == .home { editing = $0 } }, preview: { previewing = $0 },
                         showFiles: { libraryFilter = "All"; tab = .library }, showLessons: {
                             lessonsDownloadRequest = nil
                             showingLessons = true
                         }, link: $linkDraft)
                    .toolbar(visibility, for: .tabBar)
                    .tabItem { tabLabel(.home) }.tag(GlamoTab.home)
                ToolsView()
                    .toolbar(visibility, for: .tabBar)
                    .tabItem { tabLabel(.tools) }.tag(GlamoTab.tools)
                LibraryView(filter: $libraryFilter, edit: { if tab == .library { editing = $0 } },
                            preview: { previewing = $0 }, openHome: { tab = .home })
                    .toolbar(visibility, for: .tabBar)
                    .tabItem { tabLabel(.library) }.tag(GlamoTab.library)
                AccountView()
                    .toolbar(visibility, for: .tabBar)
                    .tabItem { tabLabel(.account) }.tag(GlamoTab.account)
            }
            .modifier(GlamoTabBarAppearance())
            .toolbarColorScheme(.light, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if floating {
                    GlamoTabDock(selection: $tab)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
            }
        }
        .glamoScreenBackground(GlamoStyle.background)
        .foregroundStyle(GlamoStyle.ink)
        .sheet(item: $editing) { EditorSheet(initialMovie: $0) }
        .sheet(item: $previewing) { LocalMediaPreview(movie: $0) }
        .sheet(isPresented: $showingLessons) {
            LessonsView(downloadsRequest: lessonsDownloadRequest)
        }
        .overlay(alignment: .top) {
            if !showingLessons { DownloadCompletionNotice().padding(.top, 8) }
        }
        .task(id: library.downloadsRequest) {
            guard let request = library.downloadsRequest else { return }
            // The full-screen lesson player dismisses before revealing its downloads.
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            lessonsDownloadRequest = request
            showingLessons = true
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
                }.padding(14).glamoCard(radius: 18).padding()
            }
        }
        .modifier(AccountBusyModifier())
    }

    private func usesFloatingTabs(in container: GeometryProxy) -> Bool {
        guard environment.horizontalSizeClass == .compact,
              environment.verticalSizeClass == .regular,
              !environment.dynamicTypeSize.isAccessibilitySize,
              container.size.width >= 300 else { return false }
        if #available(iOS 27.1, *) {
            let bounds = CGRect(origin: .zero, size: container.size)
            let divisions = container.reservedRegions(kind: .division)
            if environment.toolbarVerticalEdge != nil ||
                divisions.contains(where: { $0.isActive && bounds.intersects($0.frame) }) { return false }
            let dockBand = CGRect(x: 0, y: max(0, bounds.height - 104), width: bounds.width, height: 104)
            if container.reservedRegions(kind: .occlusion).contains(where: { $0.isActive && dockBand.intersects($0.frame) }) {
                return false
            }
        }
        return true
    }

    // Title and original image together: the vertical bar shows the image,
    // overflow menus show both. Text-only items would not move to the side.
    private func tabLabel(_ item: GlamoTab) -> some View {
        Label { LocalizedText(item.name) } icon: { Image(item.artwork).renderingMode(.template) }
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
                        Image(item.artwork).renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        LocalizedText(item.name).font(.glam(.caption, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 7)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(selected ? GlamoStyle.onAccent : GlamoStyle.ink)
                    .background {
                        if selected {
                            Capsule().fill(GlamoStyle.accent)
                                .matchedGeometryEffect(id: "selected", in: indicator)
                        }
                    }
                    .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("tab.\(item.name.lowercased())")
            }
        }
        .padding(5)
        .frame(maxWidth: 400)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 33), tint: GlamoStyle.surface)
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
