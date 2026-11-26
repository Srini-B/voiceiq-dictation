import SwiftUI
import UIKit

/// Dynamic SwiftUI colors matching Hex's keycap palette for VoiceiQ's Edit panel.
enum HexKeyColors {
    static let key = Color(dynamic { $0.keyFill })
    static let pressed = Color(dynamic { $0.keyPressedFill })
    static let function = Color(dynamic { $0.functionFill })

    private static func dynamic(_ color: @escaping @Sendable (FullKeyboardPalette) -> UIColor) -> UIColor {
        UIColor { traits in color(FullKeyboardPalette(isDark: traits.userInterfaceStyle == .dark)) }
    }
}
