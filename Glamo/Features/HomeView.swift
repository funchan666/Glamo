import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var paywall = false
    let edit: (PracticeRecording) -> Void
    let preview: (PracticeRecording) -> Void
    let showFiles: () -> Void
    let showLessons: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LocalizedText("Video files").font(.glam(.largeTitle, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                importPanel
                if !library.movies.isEmpty { recentFiles }
                PlusEntry(isMember: commerce.premium) { paywall = true }
                    .disabled(library.importingVideo)
                    .accessibilityIdentifier("home.plus")
                Button(action: showLessons) {
                    HStack(spacing: 10) {
                        Glyph(symbol: .library, size: 19, tint: GlamoStyle.secondary)
                        LocalizedText("Lessons").font(.glam(.subheadline, weight: .semibold))
                        Spacer(minLength: 8)
                        Glyph(symbol: .back, size: 11, tint: GlamoStyle.secondary).rotationEffect(.degrees(180))
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(PressStyle()).disabled(library.importingVideo)
            }.glamoPage()
        }.glamoScreenBackground()
            .sheet(isPresented: $paywall) { MembershipView() }
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    LocalizedText("Import a video").font(.glam(.title2, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    LocalizedText("Trim, crop, change speed or extract audio.")
                        .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                }.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if library.movies.isEmpty, !typeSize.isAccessibilitySize {
                    Image("GlamoLaunchMark").resizable().scaledToFit()
                        .frame(width: 84, height: 84).accessibilityHidden(true)
                }
            }
            VideoImportControls(onImport: edit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16)
            .glamoGlass(in: RoundedRectangle(cornerRadius: 22), tint: GlamoStyle.surface)
    }

    private var recentFiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { recentHeading; Spacer(minLength: 12); allFilesButton }
                VStack(alignment: .leading, spacing: 4) { recentHeading; allFilesButton }
            }
            VStack(spacing: 0) {
                ForEach(library.movies.prefix(4)) { movie in
                    if movie.id != library.movies.first?.id { Divider().overlay(GlamoStyle.line) }
                    Button { preview(movie) } label: {
                        HStack(spacing: 8) {
                            LocalMediaLabel(movie: movie)
                            Glyph(symbol: .play, size: 13, tint: GlamoStyle.secondary)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(PressStyle()).disabled(library.importingVideo)
                }
            }
        }
    }

    private var recentHeading: some View {
        LocalizedText("Recent files").font(.glam(.title3, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private var allFilesButton: some View {
        Button(action: showFiles) { LocalizedText("All files") }
            .buttonStyle(CompactActionStyle()).disabled(library.importingVideo)
    }
}

struct LessonsView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @Environment(\.dismiss) private var dismiss
    let downloadsRequest: UUID?
    @Binding var link: String
    @State private var error: String?
    @State private var linkFailure = ""
    @State private var showingLinkFailure = false
    @State private var channel: ChannelRoute?
    @State private var searchRequest: LessonSearch?
    @State private var channels: [LandingInfo] = []
    @State private var channelRetry = 0
    @State private var showingLinkGuide = false
    @State private var showingLookGuide = false
    @State private var showingRehearsal = false
    @State private var showingDiscover = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingLink = false
    @State private var pendingLinkSearch: LessonSearch?
    @State private var composerError: String?
    @FocusState private var focused: Bool
    var body: some View {
        let request = ChannelRequest(links: commerce.release?.lcList?["us"] ?? [], attempt: channelRetry)
        VStack(spacing: 0) {
            SheetHeading(title: "Lessons") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { lessonActions }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 8) { lessonActions }
                    }
                    SavedLessonsSection(watchLessons: { showingDiscover = true }, downloadsRequest: downloadsRequest)
                    if let message = library.error {
                        HStack(spacing: 8) {
                            ErrorNote(message: message)
                            IconButton(symbol: .close, label: "Dismiss message") { library.error = nil }
                        }
                    }
                    if api.session == nil { ConnectionPanel() }
                    if let error {
                        MessagePanel(title: "Couldn’t load lesson collections", message: error, actionTitle: "Try again") {
                            channelRetry += 1
                        }
                    }
                    lookCollections
                    recentLinks
                    VStack(spacing: 0) {
                        LookGuideEntry { showingLookGuide = true }
                        Divider().overlay(GlamoStyle.line)
                        LookRehearsalEntry { showingRehearsal = true }
                    }
                }.glamoPage()
            }
        }.glamoScreenBackground().scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showingLink, onDismiss: openPendingLesson) {
                VStack(spacing: 0) {
                    SheetHeading {
                        focused = false
                        showingLink = false
                    }
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
            .fullScreenCover(isPresented: $showingDiscover) { DiscoverView(canDismiss: true) }
            .fullScreenCover(item: $searchRequest) { request in
                DiscoverView(initialSearch: request.query, canDismiss: true) { query, clip in
                    library.record(link: query, title: clip.title)
                }
            }
            .fullScreenCover(isPresented: $showingLinkFailure) {
                AccountDecisionDialog(title: "Couldn’t open the lesson", message: linkFailure,
                                      confirmTitle: "Back", confirm: { showingLinkFailure = false })
                    .presentationBackground(.clear)
            }
            .sheet(isPresented: $showingLookGuide) { LookGuideView() }
            .sheet(isPresented: $showingRehearsal) { LookRehearsalView() }
            .onChange(of: downloadsRequest) { _, request in
                if request != nil { channel = nil }
            }
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

    @ViewBuilder private var lessonActions: some View {
        Button { showingDiscover = true } label: {
            HStack(spacing: 8) {
                Glyph(symbol: .play, size: 13, tint: GlamoStyle.onAccent)
                LocalizedText("Watch lessons")
            }
        }.buttonStyle(GlamoActionStyle(fillsWidth: false))
        Button { showingLink = true } label: {
            HStack(spacing: 8) {
                Glyph(symbol: .link, size: 14, tint: GlamoStyle.accent)
                LocalizedText("Open a lesson")
            }
        }.buttonStyle(GlamoActionStyle(primary: false, fillsWidth: false))
            .accessibilityHint(Text(LocalizedStringKey("Lesson link or short code")))
            .accessibilityIdentifier("home.showLink")
    }

    @ViewBuilder private var lookCollections: some View {
        if !channels.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                LocalizedText("Look collections").font(.glam(.title2, editorial: true))
                    .accessibilityAddTraits(.isHeader)
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(channels.indices, id: \.self) { index in
                        let item = channels[index]
                        if let info = item.extraInfo, let title = info.channelName, let short = info.externalLinks {
                            Button { channel = ChannelRoute(link: short, title: title) } label: {
                                HStack(spacing: 12) {
                                    MediaCover(url: WebAddress.media(item.shortCover))
                                        .frame(width: 68, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: title).font(.glam(.headline, editorial: true))
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let count = info.videoFileCount {
                                            LocalizedText("\(count) videos").font(.glam(.caption))
                                                .foregroundStyle(GlamoStyle.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Glyph(symbol: .back, size: 11, tint: GlamoStyle.secondary)
                                        .rotationEffect(.degrees(180))
                                }.padding(.vertical, 6).contentShape(Rectangle())
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
        let headingLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        return VStack(alignment: .leading, spacing: 16) {
            headingLayout {
                LocalizedText("Open a lesson").font(.glam(.title3, editorial: true))
                    .foregroundStyle(GlamoStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pasteButton
            }
            linkField
            Button(action: resolve) {
                LocalizedText("Open lesson")
            }.buttonStyle(GlamoActionStyle()).disabled(!canOpenLink)
                .accessibilityIdentifier("home.openLesson")
            allowanceLabel
            Button { showingLinkGuide = true } label: {
                LocalizedText("Help with links and codes").font(.glam(.footnote, weight: .semibold))
                    .underline().foregroundStyle(GlamoStyle.accent)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(PressStyle()).accessibilityIdentifier("home.linkHelp")
        }.padding(16).glamoCard(radius: 24, fill: GlamoStyle.paper)
    }

    private var linkField: some View {
        HStack(spacing: 0) {
            Glyph(symbol: .link, size: 18, tint: GlamoStyle.secondary)
                .padding(.leading, 12)
            TextField("Lesson link or short code", text: $link,
                      prompt: Text("Lesson link or short code").foregroundColor(GlamoStyle.secondary), axis: .vertical)
                .lineLimit(1...3).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focused).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.ink)
                .tint(GlamoStyle.accent)
                .padding(.leading, 10).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(LocalizedStringKey("Lesson link or short code"))
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
                    .accessibilityLabel(LocalizedStringKey("Clear link or code"))
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
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .frame(minHeight: 44)
                .foregroundStyle(GlamoStyle.ink)
                .glamoGlass(in: Capsule(), tint: GlamoStyle.paperMuted, interactive: true)
                .contentShape(Rectangle())
        }.buttonStyle(ComposerPressStyle())
            .accessibilityIdentifier("home.pasteLink")
    }
    private func pasteCopiedLink() {
        guard let text = UIPasteboard.general.string, text.nilIfBlank != nil else {
            showLinkFailure("Copy a lesson link or short code, then try pasting again.")
            return
        }
        composerError = nil
        link = text
    }
    @ViewBuilder private var recentLinks: some View {
        if !library.history.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    LocalizedText("Recent lessons").font(.glam(.title3, editorial: true))
                    Spacer()
                    Button("Clear history") { library.clearHistory() }
                        .buttonStyle(CompactActionStyle())
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
                    }.padding(.horizontal, 12).glamoCard(radius: 16)
                }
            }
        }
    }
    private func resolve() {
        guard let text = link.nilIfBlank, searchRequest == nil else { return }
        focused = false
        guard api.session != nil else { showLinkFailure("Connect to Glamo, then try opening the lesson again."); return }
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
        let empty = items.isEmpty && error == nil && !loading && page > 1
        VStack(spacing: 0) {
            SheetHeading(title: route.title) { dismiss() }
            ScrollView {
                LazyVStack(spacing: 18) {
                    if items.isEmpty, error == nil {
                        if empty {
                            GlamoEmptyState(title: "No videos in this collection",
                                            message: "Go back to browse other collections.") {
                                if hasMore {
                                    ActionButton(title: "Load more lessons") { Task { await load() } }
                                } else {
                                    ActionButton(title: "Back") { dismiss() }
                                }
                            }
                        } else {
                            AccountLoadingIndicator(title: "Loading lessons…").frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(items, id: \.stableID) { item in
                        Button { open(item) } label: {
                            HStack(spacing: 16) {
                                MediaCover(url: WebAddress.media(item.coverImage), folder: item.isFolder == true)
                                    .frame(width: 64, height: 76).clipShape(RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(verbatim: item.name ?? L10n.text("Untitled")).font(.glam(.headline)).lineLimit(3)
                                    LocalizedText(item.isFolder == true ? "\(item.childrenFileNum ?? 0) videos" : durationLabel(item.length ?? 0))
                                        .font(.caption.monospacedDigit()).foregroundStyle(GlamoStyle.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Glyph(symbol: item.isFolder == true ? .folder : .play, size: 20)
                            }.padding(10).glamoCard(radius: 20).contentShape(Rectangle())
                        }.buttonStyle(PressStyle())
                    }
                    if let error { ErrorNote(message: error) }
                    if hasMore, !items.isEmpty || error != nil {
                        ActionButton(title: error == nil ? "Load more" : "Try again", primary: false, busy: loading) {
                            Task { await load() }
                        }
                    }
                }.glamoPage()
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
        } else { error = "There’s no playable video here." }
    }
}

struct LinkGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Lesson links and codes") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    FeatureRow(symbol: .link, title: "Enter the link or code", detail: "Paste the lesson link or type the short code. Match uppercase and lowercase letters.")
                    FeatureRow(symbol: .play, title: "Open lesson", detail: "Swipe up or down to browse videos once the lesson opens.")
                    ActionButton(title: "Got it") { dismiss() }
                }.glamoPage()
            }
        }.glamoScreenBackground()
    }
}
