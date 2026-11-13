import SwiftUI

// System faces only: SF Pro for interface copy and New York (serif design) for
// editorial headlines. Both follow Dynamic Type and cascade to CJK and Arabic.
extension Font {
    static func glam(_ style: Font.TextStyle, weight: Font.Weight = .regular, editorial: Bool = false) -> Font {
        if editorial {
            return .system(style, design: .serif, weight: weight == .regular ? .medium : weight)
        }
        let resolved: Font.Weight = style == .headline && weight == .regular ? .semibold : weight
        return .system(style, design: .default, weight: resolved)
    }
}
