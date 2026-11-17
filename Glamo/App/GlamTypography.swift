import SwiftUI

extension Font {
    static func glam(_ style: Font.TextStyle, weight: Font.Weight = .regular, editorial: Bool = false) -> Font {
        let resolved: Font.Weight = (style == .headline || editorial) && weight == .regular ? .semibold : weight
        return .system(style, design: .default, weight: resolved)
    }
}

struct GlamDisplay: ViewModifier {
    @Environment(\.locale) private var locale
    var size: CGFloat = 46
    var relativeTo: Font.TextStyle = .largeTitle

    func body(content: Content) -> some View {
        let language = AppLanguage.from(locale)
        let usesLatin = language == .en || language == .es || language == .pt || language == .id
        content.font(usesLatin ? .custom("InstrumentSerif-Regular", size: size, relativeTo: relativeTo)
                               : .system(relativeTo, weight: .regular))
    }
}

extension View {
    func glamDisplay(_ size: CGFloat = 46, relativeTo: Font.TextStyle = .largeTitle) -> some View {
        modifier(GlamDisplay(size: size, relativeTo: relativeTo))
    }

    func driveFont(_ size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(DriveFont(size: size, style: style, weight: weight))
    }
}

private struct DriveFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight

    init(size: CGFloat, style: Font.TextStyle, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}
