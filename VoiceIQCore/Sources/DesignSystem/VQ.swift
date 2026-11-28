import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The VoiceiQ design system shared by the Mac and iPhone apps: one white
/// canvas, ink type, hairline lists, the brand blue for actions and red only
/// while something records. `Theme` (iPhone) and `VoiceIQUI` (Mac) read their
/// values from here. Spec: docs/design/redesign-2026-11.md.
public enum VQ {
    public enum Colors {
        /// Page background.
        public static let canvas = dynamic(light: 0xFFFFFF, dark: 0x0F1012)
        /// Grouped pages (Settings) and the Mac sidebar.
        public static let grouped = dynamic(light: 0xF5F6F8, dark: 0x0F1012)
        /// Cards on a grouped page, menus and sheets.
        public static let surface = dynamic(light: 0xFFFFFF, dark: 0x1A1B1E)
        /// Search fields, switch tracks, the selected row and chips.
        public static let fill = dynamic(light: 0xEFF1F4, dark: 0x222428)
        /// Rules between rows and rings on cards and buttons.
        public static let hairline = dynamic(light: 0xE7E9ED, dark: 0x2A2C31)
        public static let ink = dynamic(light: 0x121419, dark: 0xF2F3F5)
        /// Icons and secondary text that must read.
        public static let ink2 = dynamic(light: 0x3D414B, dark: 0xC9CBD2)
        /// Meta, previews and captions.
        public static let muted = dynamic(light: 0x6E727C, dark: 0x8E929C)
        /// Placeholders and words still arriving. Never for text the user must read.
        public static let faint = dynamic(light: 0xA2A6AF, dark: 0x5D6169)
        /// The brand blue: buttons, links, selection and the Talk key.
        public static let accent = dynamic(light: 0x2252BC, dark: 0x7098F5)
        public static let accentSoft = dynamic(light: 0xE8EEFB, dark: 0x1B2540)
        public static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0B1430)
        /// Recording only.
        public static let record = dynamic(light: 0xE5484D, dark: 0xFF5F5F)
        public static let recordSoft = dynamic(light: 0xFDE8E8, dark: 0x3A1A1B)
        public static let success = dynamic(light: 0x1C8C52, dark: 0x4CC38A)
        public static let warning = dynamic(light: 0xB25E09, dark: 0xF0A44B)
        /// The floating Mac pill stays dark in both appearances so it reads over any app.
        public static let pill = Color(vqHex: 0x121419)
        public static let onPill = Color(vqHex: 0xF2F3F5)
        public static let onPillMuted = Color(vqHex: 0x8E929C)

        public static func dynamic(light: UInt32, dark: UInt32) -> Color {
            #if canImport(UIKit)
            Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(vqHex: dark) : UIColor(vqHex: light) })
            #else
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(vqHex: dark) : NSColor(vqHex: light)
            })
            #endif
        }
    }

    /// A 4-point grid.
    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 20
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
        #if os(iOS)
        public static let page: CGFloat = 20
        #else
        public static let page: CGFloat = 24
        #endif
    }

    public enum Radius {
        /// Mac list selection and small controls.
        public static let control: CGFloat = 10
        public static let card: CGFloat = 16
        public static let sheet: CGFloat = 28
        /// The Talk key: 20 on a 60 point square.
        public static let talkKey: CGFloat = 20
    }

    /// One type style: a Google Sans Flex size and variable weight.
    public struct TypeStyle: Sendable {
        public let size: CGFloat
        public let weight: CGFloat
    }

    /// The type scale. iPhone sizes are the Dynamic Type base; the Mac's are
    /// smaller for its denser windows.
    public enum TypeScale {
        #if os(iOS)
        public static let display = TypeStyle(size: 32, weight: 300)
        public static let title = TypeStyle(size: 26, weight: 300)
        public static let title2 = TypeStyle(size: 20, weight: 400)
        public static let headline = TypeStyle(size: 16, weight: 560)
        public static let body = TypeStyle(size: 16, weight: 400)
        public static let callout = TypeStyle(size: 15, weight: 400)
        public static let meta = TypeStyle(size: 13, weight: 400)
        public static let caption = TypeStyle(size: 12, weight: 500)
        #else
        public static let display = TypeStyle(size: 26, weight: 350)
        public static let title = TypeStyle(size: 22, weight: 350)
        public static let title2 = TypeStyle(size: 17, weight: 450)
        public static let headline = TypeStyle(size: 13.5, weight: 600)
        public static let body = TypeStyle(size: 14.5, weight: 400)
        public static let callout = TypeStyle(size: 13, weight: 400)
        public static let meta = TypeStyle(size: 12, weight: 400)
        public static let caption = TypeStyle(size: 11, weight: 500)
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(vqHex hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(vqHex hex: UInt32) { self.init(uiColor: UIColor(vqHex: hex)) }
}
#else
extension NSColor {
    convenience init(vqHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(vqHex hex: UInt32) { self.init(nsColor: NSColor(vqHex: hex)) }
}
#endif
