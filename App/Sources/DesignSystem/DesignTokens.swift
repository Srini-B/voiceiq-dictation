import SwiftUI
import AppKit
import VoiceIQCore

/// VoiceIQUI — the VoiceiQ design tokens. Every color, type style, radius,
/// spacing and state-layer value in the app comes from here; views contain no
/// magic values. Colours and the display sizes come from the shared `VQ`
/// tokens in VoiceIQCore; contract: docs/design/redesign-2026-11.md.
enum VoiceIQUI {

    // MARK: - Color

    enum Colors {
        // Accent — the shared VQ tokens (docs/design/redesign-2026-11.md).
        static let primary = VQ.Colors.accent
        static let onPrimary = VQ.Colors.onAccent
        static let primaryContainer = VQ.Colors.accentSoft
        static let onPrimaryContainer = VQ.Colors.accent
        /// A selected sidebar row: the brand blue in light mode; in dark mode
        /// the system's selection, as the lists beside it show, not the pale
        /// `primary` (Fable, M6).
        static let selection = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .selectedContentBackgroundColor : NSColor(hex: 0x2252BC)
        })
        static let onSelection = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .alternateSelectedControlTextColor : .white
        })

        // Surfaces (never pure black)
        static let surface = VQ.Colors.surface
        static let surfaceContainer = VQ.Colors.fill
        static let windowBackground = VQ.Colors.grouped
        static let onSurface = VQ.Colors.ink
        static let onSurfaceVariant = VQ.Colors.ink2
        static let outline = VQ.Colors.muted
        static let outlineVariant = VQ.Colors.hairline

        // Status
        static let error = VQ.Colors.record
        static let errorContainer = VQ.Colors.recordSoft
        static let onErrorContainer = VQ.Colors.record
        /// Fills under white text in both modes: `primary` and `error` turn
        /// pale in dark mode, and white on the brand red reads under 4.5:1.
        static let primaryFill = Color(hex: 0x2252BC)
        static let errorFill = Color(hex: 0xC4343A)
        static let success = VQ.Colors.success

        // Brand quad — waveform, processing sweep, and celebration ONLY.
        static let gBlue = Color(hex: 0x4285F4)
        static let gRed = Color(hex: 0xEA4335)
        static let gYellow = Color(hex: 0xFBBC04)
        static let gGreen = Color(hex: 0x34A853)
        static let brandQuad: [Color] = [gBlue, gRed, gYellow, gGreen]
        /// The classic "AI shimmer" — appears exclusively in the processing state.
        static let aiShimmer: [Color] = [Color(hex: 0x4285F4), Color(hex: 0x9B72CB), Color(hex: 0xD96570)]
    }

    // MARK: - State layers (opacity of the on-color)

    enum StateLayer {
        static let hover: Double = 0.08
        static let focus: Double = 0.10
        static let pressed: Double = 0.10
        static let dragged: Double = 0.16
    }

    // MARK: - Shape

    enum Radius {
        static let xs: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xl: CGFloat = 28
        /// Stadium/pill — pass the view's height/2.
        static func full(for height: CGFloat) -> CGFloat { height / 2 }
    }

    // MARK: - Spacing (4pt grid)

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 40
    }

    // MARK: - Type (Google Sans Flex / Google Sans Code, variable axes)

    enum TypeScale {
        // ROND stays 0 everywhere (the font's straight default) — dogfood verdict:
        // the rounded terminals read too soft; straight is the look.
        static func display(grad: CGFloat = 0) -> Font { GTFont.flex(VQ.TypeScale.display.size, weight: VQ.TypeScale.display.weight, grad: grad) }
        static func headline(grad: CGFloat = 0) -> Font { GTFont.flex(VQ.TypeScale.title.size, weight: VQ.TypeScale.title.weight, grad: grad) }
        static func title(grad: CGFloat = 0) -> Font { GTFont.flex(16, weight: 500, grad: grad) }
        /// History transcripts (16/24).
        static func bodyLarge(grad: CGFloat = 0) -> Font { GTFont.flex(16, weight: 400, grad: grad) }
        static func body(grad: CGFloat = 0) -> Font { GTFont.flex(14, weight: 400, grad: grad) }
        /// Pill status text.
        static func label(grad: CGFloat = 0) -> Font { GTFont.flex(12, weight: 500, grad: grad) }
        static func labelSmall(grad: CGFloat = 0) -> Font { GTFont.flex(11, weight: 500, grad: grad) }
        /// Timers/stats — label + tabular figures (apply .monospacedDigit()).
        static func numeric(grad: CGFloat = 0) -> Font { GTFont.flex(12, weight: 500, grad: grad).monospacedDigit() }
        /// API key / endpoint fields.
        static let code: Font = GTFont.sansCode(13, weight: 400)
    }
}

// MARK: - Variable-font plumbing

enum GTFont {
    // OpenType variation axis tags.
    private static let wght: UInt32 = 0x77676874
    private static let opsz: UInt32 = 0x6F70737A
    private static let GRAD: UInt32 = 0x47524144
    private static let ROND: UInt32 = 0x524F4E44

    static let flexPostScriptName = "GoogleSansFlex-Regular"
    static let codePostScriptName = "GoogleSansCode-Regular"

    /// Google Sans Flex with explicit axes. opsz is FLOORED at 17: the low-opsz
    /// masters that size-tracking would select for 11–14pt UI text are deliberately
    /// chunkier and rounder for small print — flooring keeps every UI size on the
    /// straighter text master (dogfood + google-design.md "UI at opsz ~17").
    /// Pass grad +25 in dark mode to thicken strokes without layout shift.
    static func flex(_ size: CGFloat, weight: CGFloat, grad: CGFloat = 0, rond: CGFloat = 0) -> Font {
        variable(flexPostScriptName, size: size, variations: [
            wght: weight,
            opsz: min(max(size, 17), 144),
            GRAD: grad,
            ROND: rond,
        ])
    }

    static func sansCode(_ size: CGFloat, weight: CGFloat) -> Font {
        variable(codePostScriptName, size: size, variations: [wght: weight])
    }

    /// The same faces as NSFont, for AppKit text views.
    static func nsFlex(_ size: CGFloat, weight: CGFloat) -> NSFont {
        nsVariable(flexPostScriptName, size: size, variations: [wght: weight, opsz: min(max(size, 17), 144)])
    }

    static func nsSansCode(_ size: CGFloat, weight: CGFloat) -> NSFont {
        nsVariable(codePostScriptName, size: size, variations: [wght: weight])
    }

    private static func variable(_ postScriptName: String, size: CGFloat, variations: [UInt32: CGFloat]) -> Font {
        Font(nsVariable(postScriptName, size: size, variations: variations))
    }

    private static func nsVariable(_ postScriptName: String, size: CGFloat, variations: [UInt32: CGFloat]) -> NSFont {
        let axes = variations.reduce(into: [NSNumber: NSNumber]()) { dict, entry in
            dict[NSNumber(value: entry.key)] = NSNumber(value: Double(entry.value))
        }
        let attributes: [CFString: Any] = [
            kCTFontNameAttribute: postScriptName,
            kCTFontVariationAttribute: axes,
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }
}

// MARK: - Hex helpers

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}
