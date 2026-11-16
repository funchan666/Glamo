import SwiftUI
import UIKit

/// The video URL entry on the Files page. Opens the full-screen results with
/// exactly what was entered; history, quota and search stay in their stores.
struct VideoLinkComposer: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var quota: QuotaStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var link: String
    let focused: FocusState<Bool>.Binding
    let willOpen: () -> Void
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
                LinkedVideoView(search: request.query) { query, clip in
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
        willOpen()
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

private struct LinkGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    FeatureRow(symbol: .link, title: "Copy the URL", detail: "Copy the video URL from the share menu or the address bar.")
                    FeatureRow(symbol: .edit, title: "Paste it here", detail: "Paste the URL on the Files page, then tap Open. Enter it exactly as shared, including uppercase and lowercase letters.")
                    FeatureRow(symbol: .play, title: "Browse videos", detail: "Once it opens, swipe up or down to browse videos.")
                    ActionButton(title: "Got it") { dismiss() }
                }.glamoPage()
            }
        }.glamoScreenBackground()
    }
}
