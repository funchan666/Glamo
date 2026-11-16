import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @State private var paywall = false
    @FocusState private var linkFocused: Bool
    let edit: (PracticeRecording) -> Void
    let preview: (PracticeRecording) -> Void
    let showFiles: () -> Void
    let showLessons: () -> Void
    @Binding var link: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Opening a shared video URL is a first-class, visible feature
                // on the first screen, next to local import.
                VideoLinkComposer(link: $link, focused: $linkFocused)
                    .disabled(library.importingVideo)
                importPanel
                if !library.movies.isEmpty { recentFiles }
                PlusEntry(isMember: commerce.premium) { paywall = true }
                    .disabled(library.importingVideo)
                    .accessibilityIdentifier("home.plus")
                Button(action: showLessons) {
                    HStack(spacing: 10) {
                        Glyph(symbol: .library, size: 19, tint: GlamoStyle.secondary)
                        LocalizedText("Discover").font(.glam(.subheadline, weight: .semibold))
                        Spacer(minLength: 8)
                        Glyph(symbol: .back, size: 11, tint: GlamoStyle.secondary).rotationEffect(.degrees(180))
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(PressStyle()).disabled(library.importingVideo)
            }.glamoPage()
        }.scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnOutsideTap($linkFocused, scope: "home-link-input")
            .glamoScreenBackground()
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
    @Environment(\.dismiss) private var dismiss
    let downloadsRequest: UUID?
    @State private var error: String?
    @State private var linkFailure = ""
    @State private var showingLinkFailure = false
    @State private var channel: ChannelRoute?
    @State private var searchRequest: LessonSearch?
    @State private var channels: [LandingInfo] = []
    @State private var channelRetry = 0
    @State private var showingLookGuide = false
    @State private var showingRehearsal = false
    @State private var showingDiscover = false
    var body: some View {
        let request = ChannelRequest(links: commerce.release?.lcList?["us"] ?? [], attempt: channelRetry)
        VStack(spacing: 0) {
            SheetHeading { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Button { showingDiscover = true } label: {
                        HStack(spacing: 8) {
                            Glyph(symbol: .play, size: 13, tint: GlamoStyle.onAccent)
                            LocalizedText("Browse videos")
                        }
                    }.buttonStyle(GlamoActionStyle(fillsWidth: false))
                    SavedLessonsSection(watchLessons: { showingDiscover = true }, downloadsRequest: downloadsRequest)
                    if let message = library.error {
                        HStack(spacing: 8) {
                            ErrorNote(message: message)
                            IconButton(symbol: .close, label: "Dismiss message") { library.error = nil }
                        }
                    }
                    if api.session == nil { ConnectionPanel() }
                    if let error {
                        MessagePanel(title: "Couldn’t load collections", message: error, actionTitle: "Try again") {
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
        }.glamoScreenBackground()
            .sheet(item: $channel) { ChannelView(route: $0) }
            .fullScreenCover(isPresented: $showingDiscover) { DiscoverView(canDismiss: true) }
            .fullScreenCover(item: $searchRequest) { request in
                DiscoverView(initialSearch: request.query, canDismiss: true) { query, clip in
                    library.record(link: query, title: clip.title)
                }
            }
            .fullScreenCover(isPresented: $showingLinkFailure) {
                AccountDecisionDialog(title: "Couldn’t open the URL", message: linkFailure,
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

    @ViewBuilder private var recentLinks: some View {
        if !library.history.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    LocalizedText("Recently opened").font(.glam(.title3, editorial: true))
                    Spacer()
                    Button("Clear history") { library.clearHistory() }
                        .buttonStyle(CompactActionStyle())
                }
                ForEach(library.history.prefix(5)) { visit in
                    HStack {
                        Button { open(visit.link) } label: {
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
    private func open(_ address: String) {
        guard let text = address.nilIfBlank, searchRequest == nil else { return }
        guard api.session != nil else {
            linkFailure = "Connect to Glamo, then try opening the URL again."
            showingLinkFailure = true
            return
        }
        // Preserve exactly what was entered (trimmed at the ends only). Search owns
        // loading, errors and cursor pagination.
        searchRequest = LessonSearch(query: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The video URL entry on the Videos page. Opens the full-screen results with
/// exactly what was entered; history, quota and search stay in their stores.
struct VideoLinkComposer: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var link: String
    let focused: FocusState<Bool>.Binding
    @State private var searchRequest: LessonSearch?
    @State private var composerError: String?
    @State private var needsConnection = false
    @State private var showingLinkGuide = false

    var body: some View {
        let headingLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        VStack(alignment: .leading, spacing: 14) {
            headingLayout {
                LocalizedText("Open a video URL").font(.glam(.title3, weight: .semibold))
                    .foregroundStyle(GlamoStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pasteButton
            }
            linkField
            Button(action: resolve) {
                LocalizedText("Open")
            }.buttonStyle(GlamoActionStyle()).disabled(!canOpenLink)
                .accessibilityIdentifier("home.openLesson")
            if let composerError { ErrorNote(message: composerError) }
            if needsConnection, api.session == nil { ConnectionPanel() }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { allowanceLabel; Spacer(minLength: 8); helpButton }
                VStack(alignment: .leading, spacing: 2) { allowanceLabel; helpButton }
            }
        }.padding(16)
            .glamoGlass(in: RoundedRectangle(cornerRadius: 22), tint: GlamoStyle.surface)
            .onChange(of: link) { _, _ in composerError = nil }
            .onChange(of: api.session == nil) { _, missing in
                if !missing { needsConnection = false; composerError = nil }
            }
            .fullScreenCover(item: $searchRequest) { request in
                DiscoverView(initialSearch: request.query, canDismiss: true) { query, clip in
                    library.record(link: query, title: clip.title)
                }
            }
            .sheet(isPresented: $showingLinkGuide) { LinkGuideSheet() }
    }

    private var linkField: some View {
        HStack(spacing: 0) {
            Glyph(symbol: .link, size: 18, tint: GlamoStyle.secondary)
                .padding(.leading, 12)
            TextField("Video URL", text: $link,
                      prompt: Text("Paste or enter a video URL").foregroundColor(GlamoStyle.secondary), axis: .vertical)
                .lineLimit(1...3).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused(focused).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.ink)
                .tint(GlamoStyle.accent)
                .padding(.leading, 10).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(LocalizedStringKey("Video URL"))
                .accessibilityIdentifier("home.linkField")
            if !link.isEmpty {
                Button {
                    link = ""
                    focused.wrappedValue = true
                } label: {
                    Glyph(symbol: .close, size: 14, tint: GlamoStyle.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(ComposerPressStyle())
                    .accessibilityLabel(LocalizedStringKey("Clear URL"))
                    .accessibilityIdentifier("home.clearLink")
            }
        }
            // Input and its clear action stay together, including when the
            // outside-tap handler decides whether to dismiss the keyboard.
            .padding(.trailing, link.isEmpty ? 14 : 4)
            .environment(\.layoutDirection, .leftToRight)
            .background(GlamoStyle.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(focused.wrappedValue ? GlamoStyle.accent : GlamoStyle.controlLine)
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

    private var helpButton: some View {
        Button { showingLinkGuide = true } label: {
            LocalizedText("How to open a video URL").font(.glam(.footnote, weight: .semibold))
                .underline().foregroundStyle(GlamoStyle.accent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(PressStyle()).accessibilityIdentifier("home.linkHelp")
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
            composerError = "Copy a video URL, then try pasting again."
            return
        }
        link = text
    }

    private func resolve() {
        guard let text = link.nilIfBlank, searchRequest == nil else { return }
        focused.wrappedValue = false
        guard api.session != nil else {
            needsConnection = true
            composerError = "Connect to Glamo, then try opening the URL again."
            return
        }
        composerError = nil
        // Preserve exactly what was entered (trimmed at the ends only). Search owns
        // loading, errors and cursor pagination.
        searchRequest = LessonSearch(query: text.trimmingCharacters(in: .whitespacesAndNewlines))
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
                                    ActionButton(title: "Load more videos") { Task { await load() } }
                                } else {
                                    ActionButton(title: "Back") { dismiss() }
                                }
                            }
                        } else {
                            AccountLoadingIndicator(title: "Loading videos…").frame(maxWidth: .infinity)
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
            SheetHeading { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    FeatureRow(symbol: .link, title: "Copy the URL", detail: "Copy the video URL from the share menu or the address bar.")
                    FeatureRow(symbol: .edit, title: "Paste it here", detail: "Paste the URL on the Videos page, then tap Open. Enter it exactly as shared, including uppercase and lowercase letters.")
                    FeatureRow(symbol: .play, title: "Browse videos", detail: "Once it opens, swipe up or down to browse videos.")
                    ActionButton(title: "Got it") { dismiss() }
                }.glamoPage()
            }
        }.glamoScreenBackground()
    }
}
