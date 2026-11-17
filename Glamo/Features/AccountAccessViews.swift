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
                        Color.black.opacity(0.58).ignoresSafeArea()
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
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LocalizedText(title).font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
                        .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                    LocalizedText(message).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsPolicies { PolicyLinks() }
                    VStack(spacing: 10) {
                        Button(action: confirm) {
                            LocalizedText(confirmTitle).font(.glam(.subheadline, weight: .semibold))
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.vertical, 12)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(destructive ? GlamoStyle.danger : GlamoStyle.onAccent)
                                .background { GlamSurface(tone: destructive ? .raised : .accent) }
                        }.buttonStyle(PressStyle())
                        if let cancel { ActionButton(title: "Cancel", primary: false, action: cancel) }
                    }
                }.padding(20).frame(maxWidth: 360)
                    .glamoCard(radius: 26)
                    .padding(24).frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }.background(Color.black.opacity(0.68).ignoresSafeArea())
            .accessibilityAddTraits(.isModal)
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
        }.sheet(item: $document) { PolicyBrowser(document: $0) }
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
                    .accessibilityHidden(state.loading || state.error != nil)
                if let error = state.error {
                    GlamoStyle.background
                    ScrollView {
                        MessagePanel(title: "Couldn’t open this page", message: error,
                                     actionTitle: "Try again", action: { state.retry() }).padding(24)
                    }
                } else if state.loading {
                    GlamoStyle.background
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
    let localItemCount: Int
    let browse: () -> Void
    let showActivity: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var websiteError: String?
    @AppStorage(AppLanguage.preferenceKey) private var languageCode = AppLanguage.systemSelection
    @State private var languagePicker = false
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var ads: RewardedAds
    @EnvironmentObject private var accountAccess: AccountAccessFlow
    @State private var document: PolicyDocument?
    private var unavailable: Bool { accountAccess.isBusy || commerce.busy || commerce.preparingPurchase || ads.busy || ads.isPreparingAppOpen || ads.isPresenting }
    private var hasPolicyLinks: Bool {
        api.configuration.privacyURL != nil || api.configuration.termsURL != nil || api.configuration.websiteURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                Button(action: browse) {
                    localLibrary
                }.buttonStyle(PressStyle())
                rowDivider
                Button(action: showActivity) {
                    AccountMenuRow(title: "Activity", symbol: .driveActivity)
                }.buttonStyle(PressStyle())
                rowDivider
                Button { languagePicker = true } label: {
                    AccountMenuRow(title: "App language", detail: AppLanguage(rawValue: languageCode)?.nativeName ?? "Follow system",
                                   symbol: .driveSettings)
                }.buttonStyle(PressStyle())
                    .accessibilityIdentifier("account.language")
            }.glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.surface)
            if hasPolicyLinks || ads.privacyOptionsRequired {
                VStack(alignment: .leading, spacing: 8) {
                    LocalizedText("Privacy & terms").font(.glam(.headline))
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        if let url = api.configuration.privacyURL {
                            Button { document = PolicyDocument(title: "Privacy Policy", url: url) } label: {
                                AccountMenuRow(title: "Privacy Policy")
                            }
                        }
                        if let url = api.configuration.termsURL {
                            if api.configuration.privacyURL != nil { rowDivider }
                            Button { document = PolicyDocument(title: "Terms of Use", url: url) } label: {
                                AccountMenuRow(title: "Terms of Use")
                            }
                        }
                        if let website = api.configuration.websiteURL {
                            if api.configuration.privacyURL != nil || api.configuration.termsURL != nil { rowDivider }
                            Button {
                                websiteError = nil
                                openURL(website) { accepted in
                                    if !accepted { websiteError = "Couldn’t open the Glamo website. Try again." }
                                }
                            } label: {
                                AccountMenuRow(title: "Official website")
                            }.accessibilityIdentifier("account.officialWebsite")
                        }
                        if ads.privacyOptionsRequired {
                            if hasPolicyLinks { rowDivider }
                            Button { Task { await ads.privacyOptions() } } label: {
                                AccountMenuRow(title: "Ad privacy choices")
                            }.disabled(!ads.canOpenPrivacyOptions)
                                .accessibilityIdentifier("account.adPrivacyChoices")
                        }
                    }.glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.surface)
                        .buttonStyle(PressStyle()).disabled(unavailable)
                }
            }
            if let websiteError { ErrorNote(message: websiteError) }
            if let error = ads.error { ErrorNote(message: error) }
        }
            .sheet(item: $document) { PolicyBrowser(document: $0) }
            .sheet(isPresented: $languagePicker) { LanguagePicker() }
    }

    private var localLibrary: some View {
        HStack(spacing: 10) {
            Glyph(symbol: .driveFolder, size: 22, tint: GlamoStyle.accent)
                .frame(width: 32, height: 32)
                .background(GlamoStyle.paperMuted, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                LocalizedText("On this device").font(.glam(.subheadline, weight: .semibold))
                LocalizedText(localItemCount == 1 ? "%@ item" : "%@ items",
                              localItemCount.formatted(.number.locale(locale)))
                    .font(.glam(.caption)).monospacedDigit()
                    .foregroundStyle(GlamoStyle.secondary)
            }.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Glyph(symbol: .back, size: 12, tint: GlamoStyle.secondary)
                .rotationEffect(.degrees(layoutDirection == .leftToRight ? 180 : 0))
                .frame(width: 20, height: 24)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var rowDivider: some View {
        Divider().overlay(GlamoStyle.line).padding(.horizontal, 16)
    }
}

// Plain native rows with the original raster navigation glyph.
private struct AccountMenuRow: View {
    let title: String
    var detail: String? = nil
    var destructive = false
    var symbol: GlamoGlyph? = nil
    @Environment(\.layoutDirection) private var layoutDirection
    var body: some View {
        let rowTitle = LocalizedText(title).font(.glam(.subheadline, weight: .medium))
            .foregroundStyle(destructive ? GlamoStyle.danger : GlamoStyle.ink)
            .fixedSize(horizontal: false, vertical: true)
        return HStack(spacing: 12) {
            if let symbol {
                Glyph(symbol: symbol, size: 18, tint: GlamoStyle.accent)
                    .frame(width: 32, height: 32)
                    .background(GlamoStyle.paper, in: RoundedRectangle(cornerRadius: 8))
            }
            if let detail {
                let value = LocalizedText(detail).font(.glam(.footnote))
                    .foregroundStyle(GlamoStyle.secondary).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        rowTitle
                        Spacer(minLength: 0)
                        value
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
            Glyph(symbol: .back, size: 12, tint: GlamoStyle.secondary)
                .rotationEffect(.degrees(layoutDirection == .leftToRight ? 180 : 0))
                .frame(width: 20, height: 24)
                .allowsHitTesting(false).accessibilityHidden(true)
        }.padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(.interaction, Rectangle())
    }
}
