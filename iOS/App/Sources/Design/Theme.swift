import SwiftUI
import UIKit
import VoiceIQCore

/// The iPhone design system, read from the shared `VQ` tokens: one white
/// canvas, ink type, hairline lists, the brand blue for actions and red only
/// while recording. Type is Google Sans Flex, set light for large titles.
enum Theme {
    enum Colors {
        static let canvas = VQ.Colors.canvas
        /// Grouped pages (Settings).
        static let grouped = VQ.Colors.grouped
        static let surface = VQ.Colors.surface
        static let surfaceNested = VQ.Colors.fill
        /// Secondary buttons and quiet controls.
        static let porcelain = VQ.Colors.fill
        static let ink = VQ.Colors.ink
        static let inkSecondary = VQ.Colors.ink2
        static let muted = VQ.Colors.muted
        static let faint = VQ.Colors.faint
        static let hairline = VQ.Colors.hairline
        /// Brand blue. Actions, links, selection. Never a background fill for content.
        static let accent = VQ.Colors.accent
        static let accentSoft = VQ.Colors.accentSoft
        static let onAccent = VQ.Colors.onAccent
        /// Recording state only.
        static let recording = VQ.Colors.record
        static let success = VQ.Colors.success
        static let pending = VQ.Colors.warning

        static func dynamic(light: UInt32, dark: UInt32) -> Color {
            VQ.Colors.dynamic(light: light, dark: dark)
        }
    }

    enum Radius {
        static let card: CGFloat = VQ.Radius.card
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
        /// Horizontal page margin: the system layout margin, where large
        /// titles and inset lists already sit, so every page has one left edge.
        static let page: CGFloat = 16
    }

    enum Fonts {
        static func display() -> Font { flex(VQ.TypeScale.display, style: .largeTitle) }
        static func title() -> Font { flex(VQ.TypeScale.title, style: .title1) }
        static func title2() -> Font { flex(VQ.TypeScale.title2, style: .title2) }
        static func headline() -> Font { flex(VQ.TypeScale.headline, style: .headline) }
        static func body() -> Font { flex(VQ.TypeScale.body, style: .body) }
        static func callout() -> Font { flex(VQ.TypeScale.callout, style: .callout) }
        static func subheadline() -> Font { flex(14, weight: 400, style: .subheadline) }
        static func footnote() -> Font { flex(VQ.TypeScale.meta, style: .footnote) }
        static func label() -> Font { flex(13, weight: 560, style: .footnote) }
        static func caption() -> Font { flex(VQ.TypeScale.caption, style: .caption1) }
        static func numeric(_ size: CGFloat, weight: CGFloat = 350) -> Font {
            flex(size, weight: weight, style: .title1).monospacedDigit()
        }
        static func flex(_ type: VQ.TypeStyle, style: UIFont.TextStyle) -> Font {
            flex(type.size, weight: type.weight, style: style)
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
            .font: Fonts.uiFlex(VQ.TypeScale.display.size, weight: VQ.TypeScale.display.weight, style: .largeTitle),
            .foregroundColor: ink,
        ]
        appearance.titleTextAttributes = [
            .font: Fonts.uiFlex(17, weight: 560, style: .headline),
            .foregroundColor: ink,
        ]
    }
}
