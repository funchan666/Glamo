import SwiftUI
import UIKit

// Shared palette from the supplied Vifol design (APP UI / 323:4903).
enum GlamoStyle {
    static let background = DriveStyle.background
    static let surface = Color.white
    static let raised = Color(red: 229 / 255, green: 229 / 255, blue: 234 / 255)
    static let accent = DriveStyle.accent
    static let playbackProgress = DriveStyle.accent
    static let onAccent = Color.white
    static let ink = DriveStyle.ink
    static let secondary = DriveStyle.secondary
    static let paper = Color(red: 247 / 255, green: 248 / 255, blue: 252 / 255)
    static let paperMuted = Color(red: 223 / 255, green: 235 / 255, blue: 252 / 255)
    static let line = Color(red: 228 / 255, green: 228 / 255, blue: 234 / 255)
    static let controlLine = Color(red: 0.424, green: 0.475, blue: 0.565)
    static let danger = Color(red: 0.647, green: 0.176, blue: 0.212)     // #A52D36
}

enum DriveStyle {
    static let background = Color(red: 242 / 255, green: 241 / 255, blue: 247 / 255)
    static let accent = Color(red: 0, green: 130 / 255, blue: 251 / 255)
    static let link = Color(red: 0, green: 101 / 255, blue: 200 / 255)
    static let folder = Color(red: 238 / 255, green: 170 / 255, blue: 23 / 255)
    static let ink = Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255)
    static let secondary = Color(red: 113 / 255, green: 112 / 255, blue: 120 / 255)
    static let separator = Color(red: 244 / 255, green: 244 / 255, blue: 246 / 255)
    static let selectedTab = Color(red: 229 / 255, green: 229 / 255, blue: 233 / 255)
    static let pageInset: CGFloat = 24
    static let cardRadius: CGFloat = 24
    static let tabWidth: CGFloat = 344
}

private struct DriveFloatingPresentationKey: EnvironmentKey {
    static let defaultValue = false
}

private struct DriveBottomOverlayInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var driveBottomOverlayInset: CGFloat {
        get { self[DriveBottomOverlayInsetKey.self] }
        set { self[DriveBottomOverlayInsetKey.self] = newValue }
    }

    var driveFloatingPresentation: Bool {
        get { self[DriveFloatingPresentationKey.self] }
        set { self[DriveFloatingPresentationKey.self] = newValue }
    }
}

/// A real native presentation owns dismissal and child system sheets. Only its
/// app-owned content floats; the background does not become an opaque drawer.
struct DriveFloatingDialog<Content: View>: View {
    var maxWidth: CGFloat = 360
    var height: CGFloat? = nil
    var overVideo = false
    var close: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 300

    var body: some View {
        GeometryReader { container in
            let margins = drivePaneMargins(in: container, includesHorizontalFold: true)
            let width = max(0, min(maxWidth, container.size.width - margins.leading - margins.trailing - 32))
            let capacity = max(0, container.size.height - margins.top - margins.bottom - 32)
            ZStack {
                Color.black.opacity(overVideo ? 0.12 : 0.18)
                    .ignoresSafeArea(.container, edges: .all)
                    .contentShape(Rectangle())
                    .onTapGesture { close?() }
                    .accessibilityHidden(true)
                Group {
                    if let height {
                        content().frame(height: min(height, capacity))
                    } else {
                        ScrollView {
                            content()
                                .frame(maxWidth: .infinity)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                    contentHeight = $0
                                }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollDismissesKeyboard(.interactively)
                        .frame(height: min(capacity, contentHeight))
                    }
                }
                .frame(width: width)
                .environment(\.driveFloatingPresentation, true)
                .glamoGlass(in: RoundedRectangle(cornerRadius: 24), tint: .white)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.12), radius: 28, y: 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(margins)
            }
        }
        .presentationBackground(.clear)
        .accessibilityAddTraits(.isModal)
    }
}

struct DriveDialogButtonStyle: ButtonStyle {
    var primary = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .driveFont(15, relativeTo: .subheadline, weight: .semibold)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(destructive ? Color(red: 1, green: 0.24, blue: 0.30) : primary ? .white : DriveStyle.ink)
            .background(primary && !destructive ? DriveStyle.accent : Color(red: 0.78, green: 0.78, blue: 0.80), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

struct DriveDialogActions<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: () -> Content
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8))
                                                  : AnyLayout(HStackLayout(spacing: 10))
        layout { content() }
    }
}

private struct GlamoScreenSurface: ViewModifier {
    let color: Color
    @Environment(\.driveFloatingPresentation) private var floating
    func body(content: Content) -> some View {
        if floating {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background { color.ignoresSafeArea(.container, edges: .all).allowsHitTesting(false).accessibilityHidden(true) }
                .presentationBackground(color)
        }
    }
}

struct DrivePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var fillsWidth = true
    var radius: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .driveFont(17, relativeTo: .body, weight: .semibold)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: fillsWidth ? 48 : 44)
            .foregroundStyle(Color.white)
            .background(DriveStyle.accent, in: RoundedRectangle(cornerRadius: radius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

// MARK: - Original raster artwork
// Every pictorial element is an original bitmap in Assets.xcassets.
// Native code supplies layout, text and touch handling.
// A missing asset shows a neutral placeholder or a text label, never substitute drawing.

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
    case feed, edit, link, search
    case tabHome, tabFiles, tabProfile
    case play, pause, close, back, sound, folder
    case driveFolder, driveRecent, driveActivity, driveSettings, driveGrid, driveList, driveAdd, driveMore, driveExpand, driveShare
    var assetName: String { "Glyph" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var fallback: String {
        switch self {
        case .feed: "Video"
        case .tabHome: "Home"
        case .tabFiles: "Files"
        case .tabProfile: "Profile"
        case .edit: "Edit"
        case .link: "Link"
        case .search: "Search"
        case .play: "Play"
        case .pause: "Pause"
        case .close: "Close"
        case .back: "Back"
        case .sound: "Audio"
        case .folder: "Folder"
        case .driveFolder: "Files"
        case .driveRecent: "Recent"
        case .driveActivity: "Transfers"
        case .driveSettings: "Settings"
        case .driveGrid: "Grid view"
        case .driveList: "List view"
        case .driveAdd: "Add"
        case .driveMore: "More"
        case .driveExpand: "Open player"
        case .driveShare: "Share file"
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
    var glyphSize: CGFloat = 20
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            let glyph = Glyph(symbol: symbol, size: glyphSize, tint: selected ? GlamoStyle.onAccent : tint)
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
            content.glassEffect(.regular.tint(tint.opacity(mediaBackdrop ? 0.52 : 0.34))
                .interactive(interactive && !reduceMotion), in: shape)
        } else {
            content.background {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill(tint.opacity(mediaBackdrop ? 0.52 : 0.36)) }
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
    /// Optional original illustration shown above the title. Hidden at accessibility sizes.
    var art: String? = nil
    @ViewBuilder let actions: () -> Actions
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 18) {
            if let art, !typeSize.isAccessibilitySize, UIImage(named: art) != nil {
                Image(art).resizable().scaledToFit()
                    .frame(maxWidth: 168, maxHeight: 132)
                    .accessibilityHidden(true)
            }
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
    func driveDialog<Content: View>(isPresented: Binding<Bool>, maxWidth: CGFloat = 360,
                                   height: CGFloat? = nil, onDismiss: (() -> Void)? = nil,
                                   @ViewBuilder content: @escaping () -> Content) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            DriveFloatingDialog(maxWidth: maxWidth, height: height, content: content)
        }
    }

    func driveDialog<Item: Identifiable, Content: View>(item: Binding<Item?>, maxWidth: CGFloat = 360,
                                                       height: CGFloat? = nil, onDismiss: (() -> Void)? = nil,
                                                       @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { value in
            DriveFloatingDialog(maxWidth: maxWidth, height: height) { content(value) }
        }
    }

    func driveGlassCard(radius: CGFloat = DriveStyle.cardRadius) -> some View {
        glamoGlass(in: RoundedRectangle(cornerRadius: radius), tint: .white)
    }

    func driveScreenBackground() -> some View {
        glamoScreenBackground(DriveStyle.background)
            .foregroundStyle(DriveStyle.ink)
            .preferredColorScheme(.light)
    }

    func glamoCard(radius: CGFloat = 22, fill: Color = GlamoStyle.surface, border: Color = GlamoStyle.line) -> some View {
        glamoGlass(in: RoundedRectangle(cornerRadius: radius), tint: fill)
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
    }
    func glamoScreenBackground(_ color: Color) -> some View {
        modifier(GlamoScreenSurface(color: color))
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
                LocalizedText(title).font(.glam(.headline))
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
                LocalizedText(title).font(.glam(.title3))
                Spacer(minLength: 12)
                if let detail { LocalizedText(detail).font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary) }
            }
            VStack(alignment: .leading, spacing: 6) {
                LocalizedText(title).font(.glam(.title3))
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
