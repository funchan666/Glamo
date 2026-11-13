import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    var openAccount: () -> Void
    var discover: () -> Void
    var openTools: () -> Void
    @Binding var link: String
    @State private var error: String?
    @State private var linkFailure = ""
    @State private var showingLinkFailure = false
    @State private var channel: ChannelRoute?
    @State private var searchRequest: LessonSearch?
    @State private var paywall = false
    @State private var channels: [LandingInfo] = []
    @State private var channelRetry = 0
    @State private var showingLinkGuide = false
    @State private var showingLookGuide = false
    @State private var showingRehearsal = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var lookTopic: LookTopic?
    @State private var showingLink = false
    @State private var pendingLinkSearch: LessonSearch?
    @State private var composerError: String?
    @FocusState private var focused: Bool
    var body: some View {
        let request = ChannelRequest(links: commerce.release?.lcList?["us"] ?? [], attempt: channelRetry)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                lookSpread
                LookRehearsalEntry { showingRehearsal = true }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { editorialActions }
                    VStack(alignment: .leading, spacing: 8) { editorialActions }
                }
                connection
                lookCollections
                LookGuideEntry(compact: true) { showingLookGuide = true }
                recentLinks
                Button(LocalizedStringKey(commerce.premium ? "Plus" : "Get Plus")) { paywall = true }
                    .buttonStyle(SoftActionStyle())
            }.glamoPage()
        }.glamoScreenBackground().scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showingLink, onDismiss: openPendingLesson) {
                VStack(spacing: 0) {
                    SheetHeading(title: "Open a makeup lesson") { showingLink = false }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            linkComposer
                            if let composerError { ErrorNote(message: composerError) }
                            if api.session == nil { ConnectionPanel() }
                        }.glamoPage()
                    }.scrollDismissesKeyboard(.interactively)
                }.glamoScreenBackground()
                    .dismissKeyboardOnOutsideTap($focused, scope: "home-link-input")
                    .sheet(isPresented: $showingLinkGuide) { LinkGuideSheet() }
            }
            .sheet(item: $channel) { ChannelView(route: $0) }
            .fullScreenCover(item: $searchRequest) { request in
                DiscoverView(initialSearch: request.query, canDismiss: true) { query, clip in
                    library.record(link: query, title: clip.title)
                }
            }
            .fullScreenCover(isPresented: $showingLinkFailure) {
                AccountDecisionDialog(title: "Couldn’t open this link", message: linkFailure,
                                      confirmTitle: "Back to link", confirm: { showingLinkFailure = false })
                    .presentationBackground(.clear)
            }
            .sheet(isPresented: $paywall) { MembershipView() }
            .sheet(isPresented: $showingLookGuide) { LookGuideView() }
            .sheet(item: $lookTopic) { topic in LookGuideView(initialNoteID: topic.id) }
            .sheet(isPresented: $showingRehearsal) { LookRehearsalView() }
            .task(id: request) {
                guard !Task.isCancelled else { return }
                channels = []
                error = nil
                guard !request.links.isEmpty else { return }
                do {
                    let result = try await api.channels(links: request.links)
                    if !Task.isCancelled { channels = result }
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { headerContent }
            VStack(alignment: .leading, spacing: 6) { headerContent }
        }
    }

    @ViewBuilder private var headerContent: some View {
            Text(verbatim: "Glamo").font(.glam(.title2, editorial: true))
                .foregroundStyle(GlamoStyle.ink).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0).frame(maxHeight: 0)
            Button { showingLink = true } label: {
                LocalizedText("Open a lesson").font(.glam(.footnote, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 44)
                    .foregroundStyle(GlamoStyle.onAccent)
                    .background(GlamoStyle.accent, in: Capsule())
                    .contentShape(Rectangle())
            }.buttonStyle(PressStyle()).accessibilityIdentifier("home.showLink")
            IconButton(symbol: .settings, label: "Open Me and account settings", action: openAccount)
    }

    @ViewBuilder private var connection: some View {
        if api.session == nil { ConnectionPanel() }
        if let error {
            MessagePanel(title: "Couldn’t load lesson collections", message: error, actionTitle: "Try again") {
                channelRetry += 1
            }
        }
    }

    private enum LookTopic: String, Identifiable {
        case eyes, base, lips
        var id: String { rawValue }
        var title: String {
            switch self { case .eyes: "Eyes"; case .base: "Base"; case .lips: "Lips" }
        }
        var cover: GlamArt {
            switch self { case .eyes: .eyes; case .base: .base; case .lips: .lips }
        }
    }

    private var lookSpread: some View {
        VStack(alignment: .leading, spacing: 12) {
            LocalizedText("Party look notes").font(.glam(.title2, editorial: true))
                .accessibilityAddTraits(.isHeader)
            if typeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    lookTile(.eyes, ratio: 1.8)
                    lookTile(.base, ratio: 1.8)
                    lookTile(.lips, ratio: 1.8)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        lookTile(.eyes, ratio: 0.80).frame(minWidth: 148)
                        VStack(spacing: 10) {
                            lookTile(.base, ratio: 1.75)
                            lookTile(.lips, ratio: 1.75)
                        }.frame(minWidth: 86, maxWidth: 142)
                    }
                    VStack(spacing: 10) {
                        lookTile(.eyes, ratio: 1.6)
                        HStack(spacing: 10) {
                            lookTile(.base, ratio: 1.3)
                            lookTile(.lips, ratio: 1.3)
                        }
                    }
                }
            }
        }
    }

    private func lookTile(_ topic: LookTopic, ratio: CGFloat) -> some View {
        Button { lookTopic = topic } label: {
            VStack(alignment: .leading, spacing: 0) {
                GlamCover(kind: topic.cover).aspectRatio(ratio, contentMode: .fit)
                LocalizedText(topic.title).font(.glam(.headline, editorial: true))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
            }.foregroundStyle(GlamoStyle.ink)
                .background(GlamoStyle.paper)
                .clipShape(.rect(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
            .accessibilityIdentifier("home.look.\(topic.id)")
    }

    @ViewBuilder private var lookCollections: some View {
        if !channels.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                LocalizedText("Look collections").font(.glam(.title2, editorial: true))
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 138),
                                             spacing: 12)], alignment: .leading, spacing: 18) {
                    ForEach(channels.indices, id: \.self) { index in
                        let item = channels[index]
                        if let info = item.extraInfo, let title = info.channelName, let short = info.externalLinks {
                            Button { channel = ChannelRoute(link: short, title: title) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    MediaCover(url: WebAddress.media(item.shortCover)).aspectRatio(0.94, contentMode: .fit)
                                        .clipShape(.rect(cornerRadius: 14)).accessibilityHidden(true)
                                    Text(verbatim: title).font(.glam(.headline, editorial: true))
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let count = info.videoFileCount {
                                        LocalizedText("\(count) videos").font(.glam(.caption))
                                            .foregroundStyle(GlamoStyle.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(PressStyle())
                        }
                    }
                }
            }
        }
    }

    private func openPendingLesson() {
        composerError = nil
        guard let request = pendingLinkSearch else { return }
        pendingLinkSearch = nil
        searchRequest = request
    }

    private var linkComposer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                LocalizedText("Lesson link or code").font(.glam(.headline, editorial: true))
                    .foregroundStyle(GlamoStyle.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pasteButton
            }
            linkField
            Button(action: resolve) {
                LocalizedText("Open lesson").font(.glam(.headline, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(canOpenLink ? GlamoStyle.onAccent : GlamoStyle.secondary)
                    .background(canOpenLink ? GlamoStyle.accent : GlamoStyle.raised, in: Capsule())
                    .contentShape(Rectangle())
            }.buttonStyle(ComposerPressStyle()).disabled(!canOpenLink)
                .accessibilityIdentifier("home.openLesson")
            allowanceLabel
            Button { showingLinkGuide = true } label: {
                LocalizedText("How it works").font(.glam(.footnote, weight: .semibold))
                    .underline().foregroundStyle(GlamoStyle.accent)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(PressStyle()).accessibilityIdentifier("home.linkHelp")
        }.padding(16).background(GlamoStyle.paper, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var editorialActions: some View {
        editorialButton("Watch looks", action: discover)
        editorialButton("Review your try-on", action: openTools)
    }

    private func editorialButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LocalizedText(title).font(.glam(.subheadline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(GlamoStyle.ink)
                .background(GlamoStyle.raised, in: Capsule())
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }

    private var linkField: some View {
        HStack(spacing: 0) {
            Glyph(symbol: .link, size: 18, tint: GlamoStyle.secondary)
                .padding(.leading, 12)
            TextField("Lesson link or code", text: $link,
                      prompt: Text("Lesson link or code").foregroundColor(GlamoStyle.secondary), axis: .vertical)
                .lineLimit(1...3).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focused).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.ink)
                .tint(GlamoStyle.accent)
                .padding(.leading, 10).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(LocalizedStringKey("Lesson link or code"))
                .accessibilityIdentifier("home.linkField")
            if !link.isEmpty {
                Button {
                    link = ""
                    composerError = nil
                    focused = true
                } label: {
                    Glyph(symbol: .close, size: 14, tint: GlamoStyle.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(ComposerPressStyle())
                    .accessibilityLabel(LocalizedStringKey("Clear link"))
                    .accessibilityIdentifier("home.clearLink")
            }
        }
            // Link input and its clear action stay together, including when
            // the outside-tap handler decides whether to dismiss the keyboard.
            .padding(.trailing, link.isEmpty ? 14 : 4)
            .environment(\.layoutDirection, .leftToRight)
            .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? GlamoStyle.accent : GlamoStyle.controlLine)
                    .allowsHitTesting(false)
            }
            .keyboardInputRegion("home-link-input")
    }

    private var canOpenLink: Bool { searchRequest == nil && link.nilIfBlank != nil }
    @ViewBuilder private var allowanceLabel: some View {
        if api.session != nil {
            LocalizedText(quota.usage == nil ? "Loading…" : commerce.premium || quota.unlimited ? "Unlimited viewing today" : "\(quota.watchesLeft) views left today")
                .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var pasteButton: some View {
        Button(action: pasteCopiedLink) {
            LocalizedText("Paste").font(.glam(.footnote, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .frame(minHeight: 44)
                .foregroundStyle(GlamoStyle.ink)
                .background { GlamSurface(tone: .mutedOnPaper, radius: 22) }
                .contentShape(Rectangle())
        }.buttonStyle(ComposerPressStyle())
            .accessibilityIdentifier("home.pasteLink")
    }
    private func pasteCopiedLink() {
        guard let text = UIPasteboard.general.string, text.nilIfBlank != nil else {
            showLinkFailure("Copy a lesson link or code first, then tap Paste.")
            return
        }
        composerError = nil
        link = text
    }
    @ViewBuilder private var recentLinks: some View {
        if !library.history.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    LocalizedText("Recently opened").font(.glam(.title3, editorial: true))
                    Spacer()
                    Button("Clear") { library.clearHistory() }
                        .buttonStyle(SoftActionStyle())
                }
                ForEach(library.history.prefix(5)) { visit in
                    HStack {
                        Button { link = visit.link; resolve() } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: visit.title).font(.glam(.headline)).lineLimit(1)
                                Text(verbatim: visit.link).font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(PressStyle()).disabled(searchRequest != nil)
                        IconButton(symbol: .close, label: "Remove history item") { library.removeVisit(visit) }
                    }
                }
            }
        }
    }
    private func resolve() {
        guard let text = link.nilIfBlank, searchRequest == nil else { return }
        focused = false
        guard api.session != nil else { showLinkFailure("Your connection is not ready yet. Please try again."); return }
        // Preserve exactly what was entered (trimmed at the ends only). Search owns
        // loading, errors and cursor pagination.
        let request = LessonSearch(query: text.trimmingCharacters(in: .whitespacesAndNewlines))
        if showingLink {
            pendingLinkSearch = request
            showingLink = false
        } else {
            searchRequest = request
        }
    }
    private func showLinkFailure(_ message: String) {
        if showingLink {
            composerError = message
            return
        }
        linkFailure = message
        showingLinkFailure = true
    }
}

// Disabled artwork already has its own legible palette; do not fade the entire
// button into the paper surface as the shared PressStyle does.
private struct ComposerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.88 : 1)
    }
}

private struct LessonSearch: Identifiable {
    let id = UUID()
    let query: String
}

private struct ChannelRequest: Equatable {
    let links: [String]
    let attempt: Int
}

struct ChannelView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let route: ChannelRoute
    @State private var items: [RemoteLessonFile] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var child: ChannelRoute?
    @State private var player: PlayerRoute?
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: route.title) { dismiss() }
            ScrollView {
                LazyVStack(spacing: 18) {
                    if items.isEmpty, !loading, error == nil {
                        GlamArtwork(kind: .pouch, height: 140)
                        MessagePanel(title: "Nothing here yet", message: "This collection has no available videos.")
                    }
                    ForEach(items, id: \.stableID) { item in
                        Button { open(item) } label: {
                            HStack(spacing: 16) {
                                MediaCover(url: WebAddress.media(item.coverImage), folder: item.isFolder == true)
                                    .frame(width: 80, height: 100).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(verbatim: item.name ?? L10n.text("Untitled")).font(.glam(.headline)).lineLimit(3)
                                    LocalizedText(item.isFolder == true ? "\(item.childrenFileNum ?? 0) videos" : durationLabel(item.length ?? 0))
                                        .font(.caption.monospacedDigit()).foregroundStyle(GlamoStyle.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Glyph(symbol: item.isFolder == true ? .folder : .play, size: 20)
                            }.contentShape(Rectangle())
                        }.buttonStyle(PressStyle())
                    }
                    if let error { ErrorNote(message: error) }
                    if hasMore { ActionButton(title: error == nil ? "Load more" : "Try again", primary: false, busy: loading) { Task { await load() } } }
                }.padding(22)
            }
        }.glamoScreenBackground()
            .task { if items.isEmpty { await load() } }
            .sheet(item: $child) { ChannelView(route: $0) }
            .fullScreenCover(item: $player) { PlayerScreen(route: $0) }
    }
    private func load() async {
        guard !loading, hasMore else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await api.channelPage(link: route.link, page: page)
            var seen = Set(items.map(\.stableID))
            items += result.list.filter { $0.name?.nilIfBlank != nil && !$0.stableID.isEmpty && seen.insert($0.stableID).inserted }
            hasMore = page * 20 < result.total && !result.list.isEmpty
            page += 1
        } catch { self.error = error.localizedDescription }
    }
    private func open(_ item: RemoteLessonFile) {
        if item.isFolder == true, let link = item.landingPage?.nilIfBlank {
            child = ChannelRoute(link: link, title: item.name ?? "Folder")
        } else if let clip = item.clip(channel: route.title) {
            player = PlayerRoute(clips: items.compactMap { $0.clip(channel: route.title) }, startID: clip.id, continuesRecommendations: true)
        } else { error = "This item does not contain a playable video." }
    }
}

struct LinkGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Open your next look") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    GlamArtwork(kind: .lesson, height: 150)
                    FeatureRow(symbol: .link, title: "1. Copy the lesson link", detail: "Use a link or code shared with you for a Glamo lesson.")
                    FeatureRow(symbol: .search, title: "2. Paste it on Home", detail: "Tap Paste, or type the code exactly as you received it. Codes are case-sensitive.")
                    FeatureRow(symbol: .play, title: "3. Open and watch", detail: "Tap Open lesson, then swipe up or down to move between videos.")
                    LocalizedText("No results? Check your input, or ask the sender for a new link.")
                        .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                    ActionButton(title: "Got it") { dismiss() }
                }.glamoPage()
            }
        }.glamoScreenBackground()
    }
}
