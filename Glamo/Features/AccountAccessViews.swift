import SwiftUI
import WebKit

@MainActor
final class AccountAccessFlow: ObservableObject {
    @Published private(set) var busyMessage: String?
    var isBusy: Bool { busyMessage != nil }

    func perform(_ message: String, operation: () async throws -> Void) async throws {
        guard !isBusy else { throw CancellationError() }
        busyMessage = message
        defer { busyMessage = nil }
        await Task.yield()
        try await operation()
    }
}

struct AccountLoadingIndicator: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 20) {
            Image("GlamoLoadingMark").resizable().scaledToFill()
                .frame(width: 48, height: 6).clipped()
                .phaseAnimator([false, true]) { content, dimmed in
                    content.opacity(reduceMotion || scenePhase != .active ? 1 : (dimmed ? 0.3 : 1))
                } animation: { _ in
                    reduceMotion || scenePhase != .active ? nil : .easeInOut(duration: 0.6)
                }
                .accessibilityHidden(true)
            LocalizedText(title).font(.glam(.subheadline, weight: .semibold)).multilineTextAlignment(.center)
        }.padding(22).frame(maxWidth: 250)
            .foregroundStyle(GlamoStyle.ink)
            .glamoCard(radius: 22, fill: GlamoStyle.paper)
            .accessibilityElement(children: .combine)
    }
}

struct AccountBusyModifier: ViewModifier {
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    func body(content: Content) -> some View {
        content.allowsHitTesting(!accountAccess.isBusy)
            .accessibilityHidden(accountAccess.isBusy)
            .overlay {
                if let message = accountAccess.busyMessage {
                    ZStack {
                        Color.black.opacity(0.18).ignoresSafeArea(.container, edges: .all)
                        AccountLoadingIndicator(title: message).padding(24)
                    }.accessibilityAddTraits(.isModal)
                }
            }
    }
}

// Native text/layout over the app's existing surfaces; no rendered text artwork.
struct AccountDecisionDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    var showsPolicies = false
    var destructive = false
    var cancel: (() -> Void)? = nil
    let confirm: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool
    var body: some View {
        DriveFloatingDialog {
            VStack(alignment: .leading, spacing: 12) {
                LocalizedText(title).driveFont(17, relativeTo: .headline, weight: .semibold)
                    .foregroundStyle(DriveStyle.ink)
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                LocalizedText(message).driveFont(14, relativeTo: .subheadline)
                    .foregroundStyle(DriveStyle.secondary).fixedSize(horizontal: false, vertical: true)
                if showsPolicies { PolicyLinks() }
                DriveDialogActions {
                    if let cancel {
                        Button(action: cancel) { LocalizedText("Cancel") }.buttonStyle(DriveDialogButtonStyle())
                    }
                    Button(action: confirm) { LocalizedText(confirmTitle) }
                        .buttonStyle(DriveDialogButtonStyle(primary: !destructive, destructive: destructive))
                }
            }.padding(18)
        }
        .interactiveDismissDisabled()
        .onAppear { titleFocused = true }
    }

}

struct PolicyDocument: Identifiable {
    let title: String
    let url: URL
    var id: String { url.absoluteString }
}

struct PolicyLinks: View {
    var compact = false
    @EnvironmentObject private var api: APIClient
    @State private var document: PolicyDocument?
    var body: some View {
        Group {
            if compact { linkLayout.buttonStyle(PressStyle()) }
            else { linkLayout.buttonStyle(CompactActionStyle()) }
        }.fullScreenCover(item: $document) { PolicyBrowser(document: $0) }
    }
    private var linkLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: compact ? 16 : 10) { links }
            VStack(alignment: .leading, spacing: compact ? 0 : 10) { links }
        }.font(.glam(.footnote, weight: .medium)).foregroundStyle(GlamoStyle.accent)
    }
    @ViewBuilder private var links: some View {
        if let url = api.configuration.termsURL {
            Button("Terms of Use") { document = PolicyDocument(title: "Terms of Use", url: url) }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 44, minHeight: 44)
        }
        if let url = api.configuration.privacyURL {
            Button("Privacy Policy") { document = PolicyDocument(title: "Privacy Policy", url: url) }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 44, minHeight: 44)
        }
    }
}

@MainActor
final class PolicyBrowserState: ObservableObject {
    @Published var loading = true
    @Published var error: String?
    @Published var requestID = 0
    @Published var canGoBack = false
    @Published var currentURL: URL?
    var retryURL: URL?
    weak var webView: WKWebView?
    func retry() { error = nil; loading = true; requestID += 1 }
    func goBack() { webView?.goBack() }
}

struct PolicyBrowser: View {
    let document: PolicyDocument
    var webSearch = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = PolicyBrowserState()
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading { dismiss() }
            if webSearch {
                HStack(spacing: 12) {
                    IconButton(symbol: .back, label: "Back", glass: true) { state.goBack() }
                        .disabled(!state.canGoBack)
                    Text(verbatim: state.currentURL?.host ?? document.url.host ?? "")
                        .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            ZStack {
                PolicyWebView(url: document.url, state: state, webSearch: webSearch)
                    .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                    .accessibilityHidden(state.loading || state.error != nil)
                if let error = state.error {
                    GlamoStyle.background.ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                    ScrollView {
                        MessagePanel(title: "Couldn’t open this page", message: error,
                                     actionTitle: "Try again", action: { state.retry() }).padding(24)
                    }
                } else if state.loading {
                    GlamoStyle.background.ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                    AccountLoadingIndicator(title: webSearch ? "Opening page…" : "Opening document…").padding(24)
                }
            }
        }.glamoScreenBackground()
    }
}

struct PolicyWebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var state: PolicyBrowserState
    var webSearch = false
    func makeCoordinator() -> Coordinator { Coordinator(state: state, webSearch: webSearch) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = !webSearch
        view.isOpaque = false
        // The web canvas reaches the edges; UIKit keeps scroll content and
        // indicators clear of the home indicator and asymmetric side insets.
        view.scrollView.contentInsetAdjustmentBehavior = .automatic
        view.scrollView.automaticallyAdjustsScrollIndicatorInsets = true
        state.webView = view
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.requestID != state.requestID else { return }
        context.coordinator.requestID = state.requestID
        context.coordinator.load(URLRequest(url: state.retryURL ?? url, timeoutInterval: 30), in: view)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        coordinator.state.webView = nil
    }
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let state: PolicyBrowserState
        let webSearch: Bool
        var requestID: Int?
        private var appNavigationURL: URL?
        init(state: PolicyBrowserState, webSearch: Bool) { self.state = state; self.webSearch = webSearch }
        func load(_ request: URLRequest, in webView: WKWebView) {
            appNavigationURL = request.url
            state.retryURL = request.url
            webView.load(request)
        }
        // Documents and search results have no camera or microphone use case.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.loading = true
            state.error = nil
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            state.currentURL = webView.url
            state.canGoBack = webView.canGoBack
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.loading = false
            state.currentURL = webView.url
            state.canGoBack = webView.canGoBack
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            state.loading = false
            state.error = "The document was interrupted. Please try again."
        }
        private func fail(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            state.loading = false
            state.error = "Check your connection and try again."
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if !webSearch, url.scheme == "mailto", navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else if url.scheme == "https" || (webSearch && url.scheme == "http") || url.absoluteString == "about:blank" {
                if navigationAction.targetFrame?.isMainFrame != false { state.retryURL = url }
                if webSearch, navigationAction.targetFrame?.isMainFrame != false {
                    // Reissue page navigations as app loads so web links stay in this view.
                    if navigationAction.navigationType == .backForward ||
                        (navigationAction.targetFrame != nil && appNavigationURL == url) {
                        appNavigationURL = nil
                        decisionHandler(.allow)
                    } else {
                        decisionHandler(.cancel)
                        load(navigationAction.request, in: webView)
                    }
                    return
                }
                if navigationAction.targetFrame == nil {
                    webView.load(navigationAction.request)
                    decisionHandler(.cancel)
                } else { decisionHandler(.allow) }
            } else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
                state.loading = false
                state.error = "This document is temporarily unavailable. Please try again."
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}

struct AccountSettingsSection: View {
    let showActivity: () -> Void
    @Environment(\.locale) private var locale
    @State private var helpPresented = false
    @State private var agreementsPresented = false
    @State private var cacheBytes: Int64 = 0
    @State private var clearingCache = false
    @State private var cacheMessage: String?
    @State private var cacheError: String?
    @State private var cacheRequestID = UUID()
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    private var unavailable: Bool { accountAccess.isBusy || commerce.busy || commerce.preparingPurchase || ads.busy || ads.isPreparingAppOpen || ads.isPresenting }
    private var hasAgreements: Bool {
        api.configuration.privacyURL != nil || api.configuration.termsURL != nil || ads.privacyOptionsRequired
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                Button(action: showActivity) {
                    AccountMenuRow(title: "Transfers", detail: library.importingVideo ? "Importing videos…" : nil,
                                   symbol: .driveActivity,
                                   tint: Color(red: 0.15, green: 0.71, blue: 0.90))
                }.accessibilityIdentifier("account.transfers")
                rowDivider
                Button { Task { await clearCache() } } label: {
                    AccountMenuRow(title: clearingCache ? "Clearing cache…" : "Clear cache",
                                   detail: cacheBytes.formatted(.byteCount(style: .file).locale(locale)), symbol: .folder)
                }
                .disabled(clearingCache || unavailable || library.importingVideo)
                .accessibilityIdentifier("account.clearCache")
                rowDivider
                Button { helpPresented = true } label: {
                    AccountMenuRow(title: "Help & feedback", symbol: .driveList,
                                   tint: Color(red: 0.18, green: 0.67, blue: 0.40))
                }.accessibilityIdentifier("account.help")
                rowDivider
                Button { agreementsPresented = true } label: {
                    AccountMenuRow(title: "User Agreement", symbol: .driveList,
                                   tint: Color(red: 0.90, green: 0.24, blue: 0.29))
                }
                .disabled(!hasAgreements)
                .accessibilityIdentifier("account.agreements")
            }
            .driveGlassCard()

            if let cacheMessage {
                LocalizedText(cacheMessage).driveFont(13, relativeTo: .footnote)
                    .foregroundStyle(GlamoStyle.accent).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            if let cacheError { ErrorNote(message: cacheError) }
        }
        .buttonStyle(PressStyle())
        .task { await refreshCache() }
        .driveDialog(isPresented: $helpPresented, maxWidth: 460, height: 560) { AccountHelpView() }
        .driveDialog(isPresented: $agreementsPresented, maxWidth: 460, height: 400) { AccountAgreementView() }
    }

    private func refreshCache() async {
        let request = UUID()
        cacheRequestID = request
        do {
            let scan = try await Task.detached(priority: .utility) { try ProfileCache.scan() }.value
            guard !Task.isCancelled, cacheRequestID == request else { return }
            cacheBytes = scan.bytes + Int64(URLCache.shared.currentDiskUsage) + Int64(URLCache.shared.currentMemoryUsage)
        } catch {
            if cacheRequestID == request { cacheError = error.localizedDescription }
        }
    }

    private func clearCache() async {
        guard !clearingCache, !unavailable, !library.importingVideo else { return }
        clearingCache = true
        cacheMessage = nil
        cacheError = nil
        defer { clearingCache = false }
        URLCache.shared.removeAllCachedResponses()
        do {
            try await Task.detached(priority: .utility) { try ProfileCache.clearExpiredCopies() }.value
            await refreshCache()
            if cacheError == nil { cacheMessage = "Cache cleared. Your videos and folders are unchanged." }
        } catch {
            await refreshCache()
            cacheError = error.localizedDescription
        }
    }

    private var rowDivider: some View {
        Divider().overlay(DriveStyle.separator).padding(.leading, 60).padding(.trailing, 16)
    }
}

private struct AccountAgreementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    @State private var document: PolicyDocument?
    private var unavailable: Bool { accountAccess.isBusy || commerce.busy || commerce.preparingPurchase || ads.busy || ads.isPreparingAppOpen || ads.isPresenting }

    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                SheetHeading(title: "User Agreement", inset: false) { dismiss() }
                    .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(spacing: 0) { policyRows }
                            .driveGlassCard()
                            .disabled(unavailable)
                        if let error = ads.error { ErrorNote(message: error) }
                    }
                    .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }
        .buttonStyle(PressStyle())
        .driveScreenBackground()
        .fullScreenCover(item: $document) { PolicyBrowser(document: $0) }
    }

    @ViewBuilder private var policyRows: some View {
        if let url = api.configuration.privacyURL {
            Button { document = PolicyDocument(title: "Privacy Policy", url: url) } label: {
                AccountMenuRow(title: "Privacy Policy", symbol: .driveList,
                               tint: Color(red: 0.18, green: 0.67, blue: 0.40))
            }
        }
        if let url = api.configuration.termsURL {
            if api.configuration.privacyURL != nil { rowDivider }
            Button { document = PolicyDocument(title: "Terms of Use", url: url) } label: {
                AccountMenuRow(title: "Terms of Use", symbol: .driveList,
                               tint: Color(red: 0.90, green: 0.24, blue: 0.29))
            }
        }
        if ads.privacyOptionsRequired {
            if api.configuration.privacyURL != nil || api.configuration.termsURL != nil { rowDivider }
            Button { Task { await ads.privacyOptions() } } label: {
                AccountMenuRow(title: "Ad privacy choices", symbol: .driveSettings)
            }.disabled(!ads.canOpenPrivacyOptions)
                .accessibilityIdentifier("account.adPrivacyChoices")
        }
    }

    private var rowDivider: some View {
        Divider().overlay(DriveStyle.separator).padding(.leading, 60).padding(.trailing, 16)
    }
}

private enum ProfileCache {
    struct Scan: Sendable {
        let bytes: Int64
        let expiredCopies: [URL]
    }

    static func scan() throws -> Scan {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("GlamoSharedVideos", isDirectory: true)
        guard files.fileExists(atPath: root.path) else { return Scan(bytes: 0, expiredCopies: []) }
        let rootMetadata = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootMetadata.isDirectory == true, rootMetadata.isSymbolicLink != true else {
            return Scan(bytes: 0, expiredCopies: [])
        }
        let entries = try files.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        var expired: [URL] = []
        var bytes: Int64 = 0
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let created = values.creationDate, created < cutoff else { continue }
            expired.append(entry)
            if let children = files.enumerator(at: entry,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey]) {
                for case let file as URL in children {
                    let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey])
                    if metadata.isSymbolicLink == true { children.skipDescendants(); continue }
                    if metadata.isRegularFile == true { bytes += Int64(metadata.fileAllocatedSize ?? 0) }
                }
            }
        }
        return Scan(bytes: bytes, expiredCopies: expired)
    }

    static func clearExpiredCopies() throws {
        // Match the library's existing seven-day staging lifetime. Recent copies
        // may still be used by a receiving app or an in-flight share.
        for copy in try scan().expiredCopies {
            if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
        }
    }
}

private struct AccountHelpView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var expanded: String? = "Import videos"
    @State private var websiteError: String?
    @AppStorage(AppLanguage.preferenceKey) private var languageCode = AppLanguage.systemSelection
    @State private var languagePicker = false
    @State private var playbackSettings = false
    private let topics: [(String, String)] = [
        ("Import videos", "In Files, tap Add files and choose Files or Photos. Videos are copied into the folder you have open."),
        ("Clear cache", "Clears cached responses and expired sharing copies. Your library videos, folders and recent sharing copies are kept."),
        ("Vifol Plus", "Plus includes unlimited online viewing, no launch ads, MP4 and M4A export, and file sharing. Local video playback remains available.")
    ]

    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                SheetHeading(title: "Help & feedback", inset: false) { dismiss() }
                    .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 10)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(topics, id: \.0) { title, answer in
                            VStack(alignment: .leading, spacing: 0) {
                                Button {
                                    expanded = expanded == title ? nil : title
                                } label: {
                                    HStack(spacing: 12) {
                                        LocalizedText(title).driveFont(16, relativeTo: .subheadline, weight: .semibold)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Glyph(symbol: .back, size: 12, tint: DriveStyle.secondary)
                                            .rotationEffect(.degrees(expanded == title ? -90 : (layoutDirection == .rightToLeft ? 0 : 180)))
                                    }
                                    .padding(14).frame(minHeight: 48).contentShape(Rectangle())
                                }.buttonStyle(PressStyle())
                                if expanded == title {
                                    LocalizedText(answer).driveFont(14, relativeTo: .subheadline)
                                        .foregroundStyle(GlamoStyle.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 14).padding(.bottom, 14)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: .white)
                        }
                        LocalizedText("Settings").driveFont(17, relativeTo: .headline, weight: .semibold)
                            .padding(.top, 10).accessibilityAddTraits(.isHeader)
                        VStack(spacing: 0) {
                            Button { languagePicker = true } label: {
                                AccountMenuRow(title: "App language", detail: AppLanguage(rawValue: languageCode)?.nativeName ?? "Follow system",
                                               symbol: .driveSettings)
                            }.accessibilityIdentifier("account.language")
                            Divider().overlay(DriveStyle.separator).padding(.leading, 60).padding(.trailing, 16)
                            Button { playbackSettings = true } label: {
                                AccountMenuRow(title: "Playback settings", symbol: .play)
                            }
                        }
                        .buttonStyle(PressStyle())
                        .driveGlassCard()
                        if let website = api.configuration.websiteURL {
                            LocalizedText("Need more help?").driveFont(17, relativeTo: .headline, weight: .semibold)
                                .padding(.top, 10).accessibilityAddTraits(.isHeader)
                            ActionButton(title: "Support website", primary: false) {
                                websiteError = nil
                                openURL(website) { accepted in
                                    if !accepted { websiteError = "Couldn’t open the Vifol website. Try again." }
                                }
                            }.accessibilityIdentifier("account.officialWebsite")
                        }
                        if let websiteError { ErrorNote(message: websiteError) }
                    }
                    .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 24)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }
        .driveScreenBackground()
        .driveDialog(isPresented: $languagePicker, height: 540) { LanguagePicker() }
        .driveDialog(isPresented: $playbackSettings, maxWidth: 420, height: 560) { PlaybackSettingsSheet() }
    }
}

// Plain native rows with the original raster navigation glyph.
private struct AccountMenuRow: View {
    @Environment(\.layoutDirection) private var layoutDirection
    let title: String
    var detail: String? = nil
    let symbol: GlamoGlyph
    var tint = DriveStyle.accent
    var body: some View {
        let rowTitle = LocalizedText(title).driveFont(15, relativeTo: .subheadline, weight: .medium)
            .foregroundStyle(DriveStyle.ink)
            .fixedSize(horizontal: false, vertical: true)
        return HStack(spacing: 12) {
            Glyph(symbol: symbol, size: 17, tint: .white)
                .frame(width: 32, height: 32)
                .background(tint, in: Circle())
                .accessibilityHidden(true)
            if let detail {
                let value = LocalizedText(detail).driveFont(14, relativeTo: .footnote)
                    .foregroundStyle(DriveStyle.secondary).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        rowTitle.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        value.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        rowTitle
                        value
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                rowTitle.frame(maxWidth: .infinity, alignment: .leading)
            }
            Glyph(symbol: .back, size: 10, tint: DriveStyle.secondary)
                .rotationEffect(.degrees(layoutDirection == .rightToLeft ? 0 : 180))
                .frame(width: 20, height: 24)
                .allowsHitTesting(false).accessibilityHidden(true)
        }.padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(.interaction, Rectangle())
    }
}
