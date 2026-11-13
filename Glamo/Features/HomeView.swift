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
    @FocusState private var focused: Bool
    var body: some View {
        let request = ChannelRequest(links: commerce.release?.lcList?["us"] ?? [], attempt: channelRetry)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Text(verbatim: "Glamo").font(.glam(.title2, weight: .semibold, editorial: true))
                        .italic().foregroundStyle(GlamoStyle.paper)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(LocalizedStringKey(commerce.premium ? "Plus" : "Get Plus")) { paywall = true }
                        .buttonStyle(SoftActionStyle())
                    IconButton(symbol: .settings, label: "Open Me and account settings", action: openAccount)
                }
                GlamHeroBanner()
                linkComposer
                if let error {
                    MessagePanel(title: "Couldn’t load lesson collections", message: error, actionTitle: "Try again") {
                        channelRetry += 1
                    }
                }
                if api.session == nil { ConnectionPanel() }
                VStack(alignment: .leading, spacing: 16) {
                    SectionLabel(title: "From the screen to your mirror")
                    LookRehearsalEntry { showingRehearsal = true }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        quickAction(artwork: .lesson, title: "Watch looks", detail: "Swipe through short party makeup lessons.", action: discover)
                        quickAction(artwork: .review, title: "Review your try-on", detail: "Slow down or reframe a video of your own look.", action: openTools)
                    }
                    LookGuideEntry(compact: true) { showingLookGuide = true }
                }
                recentLinks
                if !channels.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                LocalizedText("Look collections").font(.glam(.title3, editorial: true))
                                LocalizedText("Complete looks, from base to finishing spray.").font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            GlamArtwork(kind: .pouch, height: 72).frame(width: 84)
                        }
                        ForEach(Array(channels.enumerated()), id: \.offset) { _, item in
                            if let info = item.extraInfo, let title = info.channelName, let short = info.externalLinks {
                                Button { channel = ChannelRoute(link: short, title: title) } label: {
                                    HStack(spacing: 14) {
                                        MediaCover(url: WebAddress.media(item.shortCover), folder: false).frame(width: 64, height: 80)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(verbatim: title).font(.glam(.headline)).lineLimit(2)
                                            if let count = info.videoFileCount { LocalizedText("\(count) videos").font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary) }
                                        }
                                        Spacer()
                                        Glyph(symbol: .back, size: 12, tint: GlamoStyle.secondary).rotationEffect(.degrees(180))
                                    }.contentShape(Rectangle())
                                }.buttonStyle(PressStyle())
                            }
                        }
                    }
                }
            }.glamoPage()
        }.glamoScreenBackground().scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnOutsideTap($focused, scope: "home-link-input")
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
            .sheet(isPresented: $showingLinkGuide) { LinkGuideSheet() }
            .sheet(isPresented: $showingLookGuide) { LookGuideView() }
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
    // The one thing to type on Home: a blush card that reads like a vanity note.
    private var linkComposer: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText("Open a makeup lesson").font(.glam(.title3, weight: .semibold, editorial: true))
                    .foregroundStyle(GlamoStyle.ink).fixedSize(horizontal: false, vertical: true)
                LocalizedText("Paste a lesson link or enter its code.")
                    .font(.glam(.caption)).foregroundStyle(GlamoStyle.paperSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 0) {
                Glyph(symbol: .link, size: 18, tint: GlamoStyle.paperSecondary)
                    .padding(.leading, 12)
                TextField("Lesson link or code", text: $link, axis: .vertical)
                    .lineLimit(1...3).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.ink)
                    .tint(GlamoStyle.ink)
                    .padding(.leading, 10).padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(LocalizedStringKey("Lesson link or code"))
                    .accessibilityIdentifier("home.linkField")
                if !link.isEmpty {
                    Button {
                        link = ""
                        focused = true
                    } label: {
                        Glyph(symbol: .close, size: 14, tint: GlamoStyle.ink.opacity(0.65))
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
                .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .environment(\.colorScheme, .light)
                .keyboardInputRegion("home-link-input")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    allowanceLabel.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    pasteButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Spacer(minLength: 0); pasteButton }
                    allowanceLabel
                }
            }
            Button(action: resolve) {
                LocalizedText("Open lesson")
                    .font(.glam(.subheadline, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(canOpenLink ? GlamoStyle.paper : GlamoStyle.paperSecondary)
                    .background { GlamSurface(tone: canOpenLink ? .inkOnPaper : .mutedOnPaper) }
                    .contentShape(Rectangle())
            }.buttonStyle(ComposerPressStyle()).disabled(!canOpenLink)
                .accessibilityIdentifier("home.openLesson")
            HStack(alignment: .center, spacing: 12) {
                LocalizedText("Codes are case-sensitive.")
                    .font(.glam(.caption)).foregroundStyle(GlamoStyle.paperSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { showingLinkGuide = true } label: {
                    LocalizedText("How it works").font(.glam(.caption, weight: .semibold))
                        .underline().foregroundStyle(GlamoStyle.ink)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(ComposerPressStyle())
                    .accessibilityIdentifier("home.linkHelp")
            }
        }.padding(20).background(GlamoStyle.paper, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
    private var canOpenLink: Bool { searchRequest == nil && link.nilIfBlank != nil }
    @ViewBuilder private var allowanceLabel: some View {
        if api.session != nil {
            LocalizedText(quota.usage == nil ? "Loading…" : commerce.premium || quota.unlimited ? "Unlimited viewing today" : "\(quota.watchesLeft) views left today")
                .font(.glam(.caption)).foregroundStyle(GlamoStyle.paperSecondary)
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
    private func quickAction(artwork: GlamArt, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                GlamCover(kind: artwork).aspectRatio(1.25, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    LocalizedText(title).font(.glam(.headline)).foregroundStyle(.white)
                    LocalizedText(detail).font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }
    private func resolve() {
        guard let text = link.nilIfBlank, searchRequest == nil else { return }
        focused = false
        guard api.session != nil else { showLinkFailure("Your connection is not ready yet. Please try again."); return }
        // Preserve exactly what was entered (trimmed at the ends only). Search owns
        // loading, errors and cursor pagination.
        searchRequest = LessonSearch(query: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private func showLinkFailure(_ message: String) {
        linkFailure = message
        showingLinkFailure = true
    }
}

// Disabled artwork already has its own legible palette; do not fade the entire
// button into the paper surface as the shared PressStyle does.
private struct ComposerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
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
        }.glamoScreenBackground().foregroundStyle(.white)
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
        }.glamoScreenBackground().foregroundStyle(.white)
    }
}
