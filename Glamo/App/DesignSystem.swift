import SwiftUI
import UIKit

// Glamo's palette: an after-dark vanity. Deep aubergine walls, a blush card for the
// one thing you type, and a rose-shimmer accent for the next action.
enum GlamoStyle {
    static let background = Color(red: 0.106, green: 0.063, blue: 0.125)   // #1B1020
    static let surface = Color(red: 0.165, green: 0.102, blue: 0.188)      // #2A1A30
    static let raised = Color(red: 0.231, green: 0.149, blue: 0.263)       // #3B2643
    static let accent = Color(red: 0.957, green: 0.655, blue: 0.765)       // #F4A7C3
    static let ink = Color(red: 0.169, green: 0.063, blue: 0.125)          // #2B1020
    static let secondary = Color(red: 0.776, green: 0.690, blue: 0.761)    // #C6B0C2
    static let paper = Color(red: 0.976, green: 0.906, blue: 0.925)        // #F9E7EC
    static let paperSecondary = Color(red: 0.482, green: 0.329, blue: 0.400) // #7B5466
    static let paperMuted = Color(red: 0.910, green: 0.796, blue: 0.835)   // #E8CBD5
    static let gold = Color(red: 0.914, green: 0.773, blue: 0.549)         // #E9C58C
    static let line = Color.white.opacity(0.10)
    static let danger = Color(red: 1, green: 0.620, blue: 0.573)           // #FF9E92
}

// MARK: - Original raster artwork
// Every pictorial element is an original bitmap in Assets.xcassets.
// Native code supplies layout, text and touch handling.
// A missing asset shows a neutral placeholder or a text label, never substitute drawing.

enum GlamArt: String, CaseIterable {
    case hero = "ArtHero"
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
    var body: some View {
        GlamoStyle.raised.overlay {
            if kind.available {
                GeometryReader { geometry in
                    Image(kind.rawValue).renderingMode(.original).resizable().interpolation(.high).scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
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
    var tint: Color = .white
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
    var tint: Color = .white
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
    enum Tone { case accent, plum, blush, mauve, inkOnPaper, mutedOnPaper, gold }
    let tone: Tone
    var radius: CGFloat = 14
    private var fill: Color {
        switch tone {
        case .accent: GlamoStyle.accent
        case .plum: GlamoStyle.raised
        case .blush: GlamoStyle.paper
        case .mauve: GlamoStyle.surface
        case .inkOnPaper: GlamoStyle.ink
        case .mutedOnPaper: GlamoStyle.paperMuted
        case .gold: GlamoStyle.gold
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
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Glyph(symbol: symbol, size: 20, tint: selected ? GlamoStyle.ink : .white)
                .allowsHitTesting(false)
                .frame(minWidth: 44, minHeight: 44)
                .background {
                    if selected { GlamSurface(tone: .accent, radius: 22) }
                }
                .contentShape(.interaction, Rectangle())
        }.buttonStyle(PressStyle()).accessibilityLabel(LocalizedStringKey(label))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(!isEnabled ? 0.55 : (configuration.isPressed ? 0.7 : 1))
    }
}
// Compact controls keep their full localized label; enclosing layouts can scroll
// or use ViewThatFits instead of splitting words across lines.
struct CompactActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.glam(.footnote, weight: .semibold))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 16).frame(minHeight: 44)
            .foregroundStyle(GlamoStyle.paper)
            .background { GlamSurface(tone: .plum, radius: 22) }
            .contentShape(.interaction, Rectangle())
            .opacity(!isEnabled ? 0.55 : (configuration.isPressed ? 0.7 : 1))
    }
}
struct ActionButton: View {
    let title: String
    var primary = true
    var busy = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            LocalizedText(busy ? "Please wait…" : title).font(.glam(.subheadline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.vertical, 12)
                .foregroundStyle(primary ? GlamoStyle.ink : GlamoStyle.paper)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(primary ? GlamoStyle.accent : GlamoStyle.raised, in: Capsule())
                .contentShape(.interaction, Rectangle())
        }.buttonStyle(PressStyle()).disabled(busy)
    }
}
struct MessagePanel: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LocalizedText(title).font(.glam(.headline)).foregroundStyle(.white)
            LocalizedText(message).font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action { ActionButton(title: actionTitle, primary: false, action: action) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        content.font(.glam(.subheadline)).foregroundStyle(.white).padding(14)
            .background(GlamoStyle.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    // Extend backgrounds to every container edge while keeping interactive
    // content inside the safe area (asymmetric on iPhone Duo with vertical bars).
    func glamoScreenBackground(_ color: Color = GlamoStyle.background) -> some View {
        background { color.ignoresSafeArea(.container, edges: .all) }
    }
    // A readable column that follows the available container width.
    func glamoPage() -> some View {
        pageHorizontalMargins().padding(.top, 16).padding(.bottom, 24)
            .frame(maxWidth: 680).frame(maxWidth: .infinity, alignment: .top)
    }
    @ViewBuilder
    fileprivate func pageHorizontalMargins() -> some View {
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
    let title: String
    var close: () -> Void
    var body: some View {
        HStack {
            LocalizedText(title).font(.glam(.headline)).lineLimit(2)
            Spacer()
            IconButton(symbol: .close, label: "Close", action: close)
        }.pageHorizontalMargins().padding(.top, 8)
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
                LocalizedText(title).font(.glam(.subheadline, weight: .semibold)).foregroundStyle(.white)
                LocalizedText(detail).font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct SoftActionStyle: ButtonStyle {
    var onPaper = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.glam(.footnote, weight: .semibold))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
            .foregroundStyle(onPaper ? GlamoStyle.ink : GlamoStyle.paper)
            .background { GlamSurface(tone: onPaper ? .mutedOnPaper : .plum, radius: 22) }
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.55 : (configuration.isPressed ? 0.75 : 1))
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
                            .foregroundStyle(selected == value ? GlamoStyle.ink : GlamoStyle.paper)
                            .background { GlamSurface(tone: selected == value ? .accent : .plum, radius: 22) }
                            .contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                        .accessibilityAddTraits(selected == value ? .isSelected : [])
                }
            }
        }
    }
}

/// Home's opening image: the vanity before a night out. Text stays native.
struct GlamHeroBanner: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 16) {
                        copy.frame(minWidth: 144, maxWidth: .infinity, alignment: .leading)
                        portrait.frame(width: 146, height: 206)
                    }
                    stacked
                }
            }
        }
        .padding(16)
        .background(GlamoStyle.paper, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
    }
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 14) {
            portrait.aspectRatio(2, contentMode: .fit)
            copy
        }
    }
    private var copy: some View {
        VStack(alignment: .leading, spacing: 10) {
            LocalizedText("Get ready\nfor the party.")
                .font(.glam(.largeTitle, weight: .semibold, editorial: true))
                .foregroundStyle(GlamoStyle.ink)
                .accessibilityAddTraits(.isHeader)
            LocalizedText("Short makeup lessons for nights out. Watch a look, then try it in your mirror.")
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.paperSecondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var portrait: some View {
        GeometryReader { container in
            Image(GlamArt.hero.rawValue).resizable().scaledToFill()
                .frame(width: container.size.width, height: container.size.height, alignment: .trailing)
                .clipped()
        }
        .clipShape(.rect(cornerRadius: 16))
        .accessibilityHidden(true)
    }
}
