import SwiftUI
import UIKit

/// The iPhone design system. A light, spacious canvas where the brand blue is
/// the only vivid color and marks actions; red appears only while recording.
/// Type is Google Sans Flex, the Mac app's face, set light for large titles.
enum Theme {
    enum Colors {
        static let canvas = dynamic(light: 0xFAFBFC, dark: 0x0D0E10)
        static let surface = dynamic(light: 0xFFFFFF, dark: 0x17181A)
        static let surfaceNested = dynamic(light: 0xF2F6FA, dark: 0x1E1F22)
        /// Secondary buttons and quiet controls.
        static let porcelain = dynamic(light: 0xECEFF3, dark: 0x26272B)
        static let ink = dynamic(light: 0x292C3D, dark: 0xF2F3F5)
        static let inkSecondary = dynamic(light: 0x3E4150, dark: 0xC9CBD2)
        static let muted = dynamic(light: 0x686A76, dark: 0x8E919B)
        static let hairline = dynamic(light: 0xE4E8EE, dark: 0x2A2B30)
        /// Brand blue. Actions, links, selection. Never a background fill for content.
        static let accent = dynamic(light: 0x2252BC, dark: 0x5786F0)
        static let onAccent = Color.white
        /// Recording state only.
        static let recording = Color(red: 0.92, green: 0.26, blue: 0.21)
        static let success = dynamic(light: 0x1C8C52, dark: 0x4CC38A)
        static let pending = dynamic(light: 0xB25E09, dark: 0xF0A44B)

        static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(UIColor { traits in
                UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
            })
        }
    }

    enum Radius {
        static let card: CGFloat = 12
        static let field: CGFloat = 10
        static let tile: CGFloat = 8
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Horizontal page margin.
        static let page: CGFloat = 20
    }

    enum Fonts {
        static func display() -> Font { flex(34, weight: 300, style: .largeTitle) }
        static func title() -> Font { flex(28, weight: 350, style: .title1) }
        static func title2() -> Font { flex(22, weight: 400, style: .title2) }
        static func headline() -> Font { flex(17, weight: 550, style: .headline) }
        static func body() -> Font { flex(16, weight: 400, style: .body) }
        static func callout() -> Font { flex(15, weight: 400, style: .callout) }
        static func subheadline() -> Font { flex(14, weight: 400, style: .subheadline) }
        static func footnote() -> Font { flex(13, weight: 400, style: .footnote) }
        static func label() -> Font { flex(13, weight: 550, style: .footnote) }
        static func caption() -> Font { flex(12, weight: 500, style: .caption1) }
        static func numeric(_ size: CGFloat, weight: CGFloat = 350) -> Font {
            flex(size, weight: weight, style: .title1).monospacedDigit()
        }
        static let code = Font.system(.callout, design: .monospaced)

        /// Google Sans Flex at an exact weight on its variable axis, scaled with
        /// Dynamic Type. Falls back to the system face if the font is missing.
        static func flex(_ size: CGFloat, weight: CGFloat, style: UIFont.TextStyle) -> Font {
            Font(uiFlex(size, weight: weight, style: style))
        }

        static func uiFlex(_ size: CGFloat, weight: CGFloat, style: UIFont.TextStyle) -> UIFont {
            let wght: UInt32 = 0x77676874, opsz: UInt32 = 0x6F70737A
            let descriptor = UIFontDescriptor(fontAttributes: [
                .name: "GoogleSansFlex-Regular",
                kCTFontVariationAttribute as UIFontDescriptor.AttributeName: [
                    NSNumber(value: wght): NSNumber(value: Double(weight)),
                    NSNumber(value: opsz): NSNumber(value: Double(min(max(size, 17), 144))),
                ],
            ])
            let base = UIFont(descriptor: descriptor, size: size)
            let font = base.familyName.contains("Google") ? base : UIFont.systemFont(ofSize: size, weight: systemWeight(weight))
            return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
        }

        private static func systemWeight(_ weight: CGFloat) -> UIFont.Weight {
            switch weight {
            case ..<350: return .light
            case ..<450: return .regular
            case ..<575: return .medium
            default: return .semibold
            }
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Kept for code that predates the theme.
enum Brand {
    static let accent = Theme.Colors.accent
    static let recording = Theme.Colors.recording
}

extension Theme {
    /// Navigation bar titles in the brand face: large titles light, inline
    /// titles medium. Set once at launch.
    @MainActor static func applyAppearance() {
        let ink = UIColor(Colors.ink)
        let appearance = UINavigationBar.appearance()
        appearance.largeTitleTextAttributes = [
            .font: Fonts.uiFlex(34, weight: 400, style: .largeTitle),
            .foregroundColor: ink,
        ]
        appearance.titleTextAttributes = [
            .font: Fonts.uiFlex(17, weight: 550, style: .headline),
            .foregroundColor: ink,
        ]
    }
}
