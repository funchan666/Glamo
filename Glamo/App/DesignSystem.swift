import SwiftUI
import UIKit

// Neutral surfaces keep media visible. Berry identifies primary actions.
enum GlamoStyle {
    static let background = Color(red: 0.980, green: 0.973, blue: 0.976) // #FAF8F9
    static let surface = Color(red: 1, green: 0.996, blue: 0.996)        // #FFFEFE
    static let raised = Color(red: 0.937, green: 0.925, blue: 0.937)     // #EFECEF
    static let accent = Color(red: 0.600, green: 0.161, blue: 0.282)     // #992948
    static let onAccent = Color(red: 1, green: 0.984, blue: 0.988)       // #FFFBFC
    static let ink = Color(red: 0.157, green: 0.133, blue: 0.157)        // #282228
    static let secondary = Color(red: 0.396, green: 0.361, blue: 0.396)  // #655C65
    static let paper = Color(red: 0.965, green: 0.949, blue: 0.961)      // #F6F2F5
    static let paperMuted = Color(red: 0.941, green: 0.894, blue: 0.922) // #F0E4EB
    static let line = Color(red: 0.890, green: 0.867, blue: 0.890)       // #E3DDE3
    static let controlLine = Color(red: 0.553, green: 0.490, blue: 0.537) // #8D7D89
    static let danger = Color(red: 0.647, green: 0.176, blue: 0.212)     // #A52D36
}

// MARK: - Original raster artwork
// Every pictorial element is an original bitmap in Assets.xcassets.
// Native code supplies layout, text and touch handling.
// A missing asset shows a neutral placeholder or a text label, never substitute drawing.

enum GlamArt: String, CaseIterable {
    case plus = "PlusArtwork"
    case vanity = "ArtVanity"
    case lesson = "ArtLesson"
    case pouch = "ArtPouch"
    case notebook = "ArtNotebook"
    case review = "ArtReview"
    case speed = "ArtSpeed"
    case frame = "ArtFrame"
    case audio = "ArtAudio"
    case base = "ArtBase"
    case eyes = "ArtEyes"
    case lips = "ArtLips"
    case glow = "ArtGlow"
    case care = "ArtCare"
    case rehearsal = "ArtRehearsal"
    var available: Bool { UIImage(named: rawValue) != nil }
}

/// Square, fitted illustration with a fixed side length.
struct GlamArtwork: View {
    let kind: GlamArt
    var height: CGFloat = 160
    var body: some View {
        Group {
            if kind.available {
                Image(kind.rawValue).renderingMode(.original).resizable().interpolation(.high).scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(GlamoStyle.raised.opacity(0.6))
            }
        }
        .frame(width: height, height: height)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Illustration that fills whatever frame its parent gives it.
struct GlamCover: View {
    let kind: GlamArt
    var alignment: Alignment = .center
    var body: some View {
        GlamoStyle.raised.overlay {
            if kind.available {
                GeometryReader { geometry in
                    Image(kind.rawValue).renderingMode(.original).resizable().interpolation(.high).scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: alignment)
                        .clipped()
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Tinted single-colour artwork. Falls back to a short localized word while the
/// original asset is missing, so controls stay identifiable during development.
struct AssetMask: View {
    let name: String
    var tint: Color = GlamoStyle.ink
    var fallback: String? = nil
    var body: some View {
        if UIImage(named: name) != nil {
            Image(name).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                .foregroundStyle(tint)
                .environment(\.layoutDirection, .leftToRight)
                .allowsHitTesting(false)
        } else if let fallback {
            LocalizedText(fallback).font(.glam(.caption2, weight: .semibold))
                .foregroundStyle(tint).lineLimit(1).fixedSize()
                .allowsHitTesting(false)
        }
    }
}

enum GlamoGlyph: String, CaseIterable {
    case home, feed, edit, library, link, search, bookmark, download
    case play, pause, close, back, sound, mute, folder, settings
    var assetName: String { "Glyph" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var fallback: String {
        switch self {
        case .home: "Home"
        case .feed: "Video"
        case .edit: "Edit"
        case .library: "Library"
        case .link: "Link"
        case .search: "Search"
        case .bookmark: "Save"
        case .download: "Download"
        case .play: "Play"
        case .pause: "Pause"
        case .close: "Close"
        case .back: "Back"
        case .sound: "Sound"
        case .mute: "Mute"
        case .folder: "Folder"
        case .settings: "Settings"
        }
    }
}

struct Glyph: View {
    @Environment(\.layoutDirection) private var direction
    let symbol: GlamoGlyph
    var size: CGFloat = 25
    var tint: Color = GlamoStyle.ink
    var body: some View {
        AssetMask(name: symbol.assetName, tint: tint, fallback: symbol.fallback)
            .frame(minWidth: size, minHeight: size)
            .frame(height: size)
            .scaleEffect(x: symbol == .back && direction == .rightToLeft ? -1 : 1, y: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Control surfaces (flat fills; no decorative drawing)

struct GlamSurface: View {
    enum Tone { case accent, raised, surface }
    let tone: Tone
    var radius: CGFloat = 14
    private var fill: Color {
        switch tone {
        case .accent: GlamoStyle.accent
        case .raised: GlamoStyle.raised
        case .surface: GlamoStyle.surface
        }
    }
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct IconButton: View {
    let symbol: GlamoGlyph
    let label: String
    var selected = false
    var tint: Color = GlamoStyle.ink
    var glass = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            let glyph = Glyph(symbol: symbol, size: 20, tint: selected ? GlamoStyle.onAccent : tint)
                .frame(minWidth: 44, minHeight: 44)
            Group {
                if selected {
                    glyph.background(GlamoStyle.accent, in: Circle())
                } else if glass {
                    glyph.glamoGlass(in: Circle(), interactive: true, mediaBackdrop: true)
                } else {
                    glyph
                }
            }.contentShape(.interaction, Rectangle())
        }.buttonStyle(PressStyle()).accessibilityLabel(LocalizedStringKey(label))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct GlamoGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color
    let interactive: Bool
    let mediaBackdrop: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(tint, in: shape)
                .overlay { shape.strokeBorder(GlamoStyle.line).allowsHitTesting(false) }
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint.opacity(mediaBackdrop ? 0.84 : 0.52))
                .interactive(interactive && !reduceMotion), in: shape)
        } else {
            content.background {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill(tint.opacity(mediaBackdrop ? 0.84 : 0.58)) }
                    .overlay { shape.strokeBorder(GlamoStyle.surface.opacity(0.82)) }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(!isEnabled ? 0.75 : (configuration.isPressed ? 0.88 : 1))
    }
}

struct CompactActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.glam(.footnote, weight: .semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(isEnabled ? GlamoStyle.ink : GlamoStyle.secondary)
            .glamoGlass(in: Capsule(), tint: GlamoStyle.paper, interactive: isEnabled)
            .contentShape(.interaction, Rectangle())
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

struct GlamoActionStyle: ButtonStyle {
    var primary = true
    var fillsWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.glam(.subheadline, weight: .semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: 52)
        Group {
            if primary {
                label.foregroundStyle(isEnabled ? GlamoStyle.onAccent : GlamoStyle.secondary)
                    .background(isEnabled ? GlamoStyle.accent : GlamoStyle.raised, in: Capsule())
                    .overlay { Capsule().strokeBorder(GlamoStyle.onAccent.opacity(0.26)).allowsHitTesting(false) }
                    .shadow(color: isEnabled ? GlamoStyle.accent.opacity(0.18) : .clear, radius: 8, y: 4)
            } else {
                label.foregroundStyle(isEnabled ? GlamoStyle.ink : GlamoStyle.secondary)
                    .glamoGlass(in: Capsule(), tint: GlamoStyle.paper, interactive: isEnabled,
                                mediaBackdrop: !fillsWidth)
            }
        }
        .contentShape(.interaction, Capsule())
        .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

struct ActionButton: View {
    let title: String
    var primary = true
    var busy = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            LocalizedText(busy ? "Please wait…" : title)
        }.buttonStyle(GlamoActionStyle(primary: primary)).disabled(busy)
    }
}
struct MessagePanel: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LocalizedText(title).font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
            LocalizedText(message).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action { ActionButton(title: actionTitle, primary: false, action: action) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .glamoCard()
    }
}

struct GlamoEmptyState<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 7) {
                LocalizedText(title).font(.glam(.title2, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                LocalizedText(message)
                    .font(.glam(.subheadline))
                    .foregroundStyle(GlamoStyle.secondary)
                    .lineSpacing(2)
            }
            .frame(maxWidth: 350)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            actions().frame(maxWidth: 320)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .foregroundStyle(GlamoStyle.ink)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorNote: View {
    @Environment(\.locale) private var locale
    let message: String
    var body: some View {
        LocalizedText(message).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.danger)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            .accessibilityLabel(Text(verbatim: L10n.display("Error: \(message)", language: AppLanguage.from(locale))))
    }
}
struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.glam(.subheadline)).foregroundStyle(GlamoStyle.ink).padding(14)
            .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(GlamoStyle.controlLine)
                    .allowsHitTesting(false)
            }
            .tint(GlamoStyle.accent)
    }
}
// Measure in the owning screen, so scrolling, keyboard avoidance and resizing
// keep the input exclusion region aligned. No global window or focus broadcast.
private struct KeyboardInputBounds: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $0.union($1) })
    }
}
private struct OutsideInputTap: ViewModifier {
    let focus: FocusState<Bool>.Binding
    let scope: String
    @State private var inputBounds: CGRect?
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle()) // Hit area only, no visible artwork.
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(scope)).onEnded { tap in
                guard focus.wrappedValue, let inputBounds, !inputBounds.contains(tap.location) else { return }
                focus.wrappedValue = false
            })
            .onPreferenceChange(KeyboardInputBounds.self) { inputBounds = $0[scope] }
            .coordinateSpace(name: scope)
    }
}

extension View {
    func glamoCard(radius: CGFloat = 22, fill: Color = GlamoStyle.surface, border: Color = GlamoStyle.line) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return background(fill, in: shape)
            .overlay { shape.strokeBorder(border).allowsHitTesting(false) }
    }

    func glamoGlass<S: InsettableShape>(in shape: S, tint: Color = GlamoStyle.surface,
                                     interactive: Bool = false, mediaBackdrop: Bool = false) -> some View {
        modifier(GlamoGlass(shape: shape, tint: tint, interactive: interactive, mediaBackdrop: mediaBackdrop))
    }

    func keyboardInputRegion(_ scope: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: KeyboardInputBounds.self,
                                       value: [scope: geometry.frame(in: .named(scope))])
            }.allowsHitTesting(false)
        }
    }
    func dismissKeyboardOnOutsideTap(_ focus: FocusState<Bool>.Binding, scope: String) -> some View {
        modifier(OutsideInputTap(focus: focus, scope: scope))
    }
    func glamoField() -> some View { modifier(FieldStyle()) }
    // Keep the surface continuous under system chrome. The foreground keeps
    // its container margins and keyboard avoidance.
    func glamoScreenBackground() -> some View {
        glamoScreenBackground(GlamoStyle.background)
            .foregroundStyle(GlamoStyle.ink)
            .preferredColorScheme(.light)
            .presentationBackground(GlamoStyle.background)
    }
    func glamoScreenBackground(_ color: Color) -> some View {
        background(color, ignoresSafeAreaEdges: .all)
    }
    // A readable column that follows the available container width.
    func glamoPage() -> some View {
        pageHorizontalMargins().padding(.top, 16).padding(.bottom, 24)
            .frame(maxWidth: 680).frame(maxWidth: .infinity, alignment: .top)
    }
    @ViewBuilder
    func pageHorizontalMargins() -> some View {
        if #available(iOS 27.1, *) {
            contentMargins(for: .container, edges: .horizontal)
        } else {
            padding(.horizontal, 20)
        }
    }
}
struct MediaCover: View {
    let url: URL?
    var folder = false
    var body: some View {
        GlamoStyle.raised.overlay {
            GeometryReader { geometry in
                Group {
                    if folder { Glyph(symbol: .folder, size: 28) }
                    else if let url {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { Glyph(symbol: .feed, size: 28) }
                        }
                    } else { Glyph(symbol: .feed, size: 28) }
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        }.clipped()
    }
}
struct SheetHeading: View {
    var title: String? = nil
    var inset = true
    var close: () -> Void
    @ViewBuilder
    var body: some View {
        if inset {
            heading.pageHorizontalMargins().padding(.top, 8)
        } else {
            heading
        }
    }

    private var heading: some View {
        HStack {
            if let title {
                LocalizedText(title).font(.glam(.headline, editorial: true))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            IconButton(symbol: .close, label: "Close", glass: true, action: close)
        }
    }
}

struct SectionLabel: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                LocalizedText(title).font(.glam(.title3, editorial: true))
                Spacer(minLength: 12)
                if let detail { LocalizedText(detail).font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary) }
            }
            VStack(alignment: .leading, spacing: 6) {
                LocalizedText(title).font(.glam(.title3, editorial: true))
                if let detail { LocalizedText(detail).font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FeatureRow: View {
    let symbol: GlamoGlyph
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 16) {
            Glyph(symbol: symbol, size: 22)
                .frame(width: 48, height: 48)
                .background(GlamoStyle.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(title).font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.ink)
                LocalizedText(detail).font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Horizontal single-choice chips (categories, filters, record options).
struct ChipFilter: View {
    let values: [String]
    let selected: String
    let select: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Button { select(value) } label: {
                        LocalizedText(value).font(.glam(.footnote, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .frame(minHeight: 44)
                            .foregroundStyle(selected == value ? GlamoStyle.accent : GlamoStyle.ink)
                            .background(selected == value ? GlamoStyle.paperMuted : GlamoStyle.surface, in: Capsule())
                            .overlay { Capsule().strokeBorder(selected == value ? GlamoStyle.accent : GlamoStyle.line).allowsHitTesting(false) }
                            .contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                        .accessibilityAddTraits(selected == value ? .isSelected : [])
                }
            }
        }
    }
}
