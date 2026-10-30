import UIKit
import VoiceIQBridge

/// One kind of key in a theme: a face shaded from top to bottom, its label,
/// and the key body that shows around the face (a keycap's skirt, or the
/// side of a raised key).
struct KeyFace {
    var top: UIColor
    var bottom: UIColor
    var label: UIColor
    var body: UIColor?
}

/// How the typing keys and the keyboard behind them look. Colors are dynamic,
/// so a theme follows light and dark; a forced key tone pins the whole
/// keyboard to one of them (`style`).
struct KeyTheme {
    var character: KeyFace
    var function: KeyFace
    var cornerRadius: CGFloat
    /// Where the face sits inside the key; the body shows around it.
    var faceInsets = UIEdgeInsets.zero
    var shadow: UIColor
    var shadowOffset: CGFloat = 1
    var shadowRadius: CGFloat = 0
    var border: UIColor?
    /// Painted behind the whole keyboard; nil keeps the system's backdrop.
    var background: (top: UIColor, bottom: UIColor)?
    var style: UIUserInterfaceStyle = .unspecified
    var fontName: String?
    var fontWeight: UIFont.Weight = .regular

    /// The key preview and accent popup; defaults to the letter key face.
    var popupFill: UIColor?
    var popup: UIColor { popupFill ?? character.top }

    func font(size: CGFloat) -> UIFont {
        fontName.flatMap { UIFont(name: $0, size: size - 2) } ?? .systemFont(ofSize: size, weight: fontWeight)
    }

    static func make(_ preferences: KeyboardPreferences) -> KeyTheme {
        var theme: KeyTheme
        switch preferences.theme {
        case .standard: theme = standard
        case .clear: theme = clear
        case .physical: theme = physical
        case .mechanical: theme = mechanical
        case .classic: theme = classic
        }
        if preferences.theme.hasKeyTone {
            switch preferences.keyTone {
            case .automatic: theme.style = .unspecified
            case .light: theme.style = .light
            case .dark: theme.style = .dark
            }
        }
        return theme
    }

    /// The iOS keyboard.
    static let standard = KeyTheme(
        character: KeyFace(top: color(0xFFFFFF, dark: 0x6B6B6B), bottom: color(0xFFFFFF, dark: 0x6B6B6B), label: .label),
        function: KeyFace(top: color(0xABB0BA, dark: 0x454545), bottom: color(0xABB0BA, dark: 0x454545), label: .label),
        cornerRadius: 5.5,
        shadow: color(0x888A8E, dark: 0x000000, darkAlpha: 0.6))

    /// Glass keys over the system backdrop.
    static let clear = KeyTheme(
        character: KeyFace(top: color(0xFFFFFF, alpha: 0.55, dark: 0xFFFFFF, darkAlpha: 0.16),
                           bottom: color(0xFFFFFF, alpha: 0.4, dark: 0xFFFFFF, darkAlpha: 0.1), label: .label),
        function: KeyFace(top: color(0xFFFFFF, alpha: 0.22, dark: 0xFFFFFF, darkAlpha: 0.07),
                          bottom: color(0xFFFFFF, alpha: 0.15, dark: 0xFFFFFF, darkAlpha: 0.04), label: .label),
        cornerRadius: 9,
        shadow: .clear, shadowOffset: 0,
        border: color(0xFFFFFF, alpha: 0.75, dark: 0xFFFFFF, darkAlpha: 0.2),
        popupFill: color(0xFFFFFF, dark: 0x6B6B6B))

    /// Raised keys with a visible side.
    static let physical = KeyTheme(
        character: KeyFace(top: color(0xFFFFFF, dark: 0x5E5E62), bottom: color(0xF1F2F4, dark: 0x515155),
                           label: .label, body: color(0xB4B8C0, dark: 0x2A2A2D)),
        function: KeyFace(top: color(0xCDD1D8, dark: 0x3E3E42), bottom: color(0xBFC3CB, dark: 0x343437),
                          label: .label, body: color(0x8E939C, dark: 0x1B1B1D)),
        cornerRadius: 8,
        faceInsets: UIEdgeInsets(top: 0, left: 0, bottom: 3.5, right: 0),
        shadow: color(0x000000, alpha: 0.18, dark: 0x000000, darkAlpha: 0.5), shadowOffset: 1.5, shadowRadius: 1.5,
        background: (color(0xD7DAE0, dark: 0x2C2C2F), color(0xC9CCD3, dark: 0x1E1E20)))

    /// Keycaps: a sculpted top inside a wider skirt, on a plate.
    static let mechanical = KeyTheme(
        character: KeyFace(top: color(0xFCFCFC, dark: 0x2E2E31), bottom: color(0xEEEFF1, dark: 0x222225),
                           label: color(0x1C1C1E, dark: 0xF2F2F2), body: color(0xC3C6CC, dark: 0x0E0E0F)),
        function: KeyFace(top: color(0xDEE0E4, dark: 0x1F1F22), bottom: color(0xD0D3D8, dark: 0x171719),
                          label: color(0x3A3A3C, dark: 0xC7C7CC), body: color(0xA4A8AF, dark: 0x080809)),
        cornerRadius: 7,
        faceInsets: UIEdgeInsets(top: 1.5, left: 3, bottom: 6, right: 3),
        shadow: color(0x000000, alpha: 0.25, dark: 0x000000, darkAlpha: 0.7), shadowOffset: 1.5, shadowRadius: 1.5,
        background: (color(0xE6E7EA, dark: 0x1E1E20), color(0xD8DADE, dark: 0x141415)),
        fontWeight: .medium)

    /// The iOS 5 keyboard: shaded keys on a slate gradient, Helvetica Bold.
    static let classic = KeyTheme(
        character: KeyFace(top: color(0xFDFDFE), bottom: color(0xDCDDE1), label: color(0x111111)),
        function: KeyFace(top: color(0xA9AFBB), bottom: color(0x8A919E), label: color(0xFFFFFF)),
        cornerRadius: 5,
        shadow: color(0x2C2F36, alpha: 0.9), shadowOffset: 1.2,
        background: (color(0x9AA0AB), color(0x6E7480)),
        style: .light,
        fontName: "Helvetica-Bold")

    private static func color(_ light: UInt32, alpha: CGFloat = 1, dark: UInt32? = nil, darkAlpha: CGFloat? = nil) -> UIColor {
        func make(_ hex: UInt32, _ a: CGFloat) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        let lightColor = make(light, alpha)
        let darkColor = make(dark ?? light, darkAlpha ?? alpha)
        return UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor }
    }
}
