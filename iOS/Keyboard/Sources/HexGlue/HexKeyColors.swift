import SwiftUI
import UIKit

/// Hex's key colours for VoiceiQ's own panels (edit, emoji, mini keys), so they
/// match the keys they replace in light and dark.
enum HexKeyColors {
    static let key = Color(dynamic { $0.keyFill })
    static let pressed = Color(dynamic { $0.keyPressedFill })
    static let function = Color(dynamic { $0.functionFill })
    static let popup = Color(dynamic { $0.popupFill })

    private static func dynamic(_ color: @escaping @Sendable (FullKeyboardPalette) -> UIColor) -> UIColor {
        UIColor { traits in
            MainActor.assumeIsolated { color(FullKeyboardPalette(isDark: FullKeyboardPalette.isDark(traits: traits))) }
        }
    }
}
