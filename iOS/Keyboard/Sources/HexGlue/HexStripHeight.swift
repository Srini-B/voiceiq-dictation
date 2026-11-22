import CoreGraphics

/// VoiceiQ's room around the strip. Hex's portrait strip is its 38 pt bar with the
/// words 26 pt above row 1, which leaves 20 pt above them and 26 pt below; VoiceiQ
/// keeps the bar and its chips and widens the gap under it to 14 pt, so the words
/// sit midway between the keyboard's top edge and the keys (row 1 at 52 pt). Turned,
/// the strip is 50 pt on the keys with its content centred, the same height as Hex's.
///
/// iOS 26 and later draw about 17 pt of their own panel above a third-party
/// keyboard in some presentations and nothing in others, and a keyboard can't
/// tell which (Hex's measurements, iPhone 17 Pro, iOS 27.2; the iOS 27.0
/// Simulator drew it in one run and not in the next). Where it is drawn, the
/// room above the content is that much larger. Hex's metrics take this through
/// the patch's `KeyboardMetrics.phoneOverride`.
enum HexStripHeight {
    static let portraitGap: CGFloat = 2 * KeyboardMetrics.barTextAboveKeys - KeyboardMetrics.stripBarHeight
    static let landscape: CGFloat = 50

    static func install() {
        KeyboardMetrics.phoneOverride = { m, orientation in
            let turned = orientation == .landscape
            var out = KeyboardMetrics(
                side: m.side, gap: m.gap, rowGap: m.rowGap, keyHeight: m.keyHeight,
                stripTop: 0,
                stripHeight: turned ? landscape : KeyboardMetrics.stripBarHeight,
                stripBottom: turned ? 0 : portraitGap,
                keysTop: m.keysTop, keysBottom: m.keysBottom, cornerRadius: m.cornerRadius,
                bottomRowTrim: m.bottomRowTrim
            )
            out.bottomRowReturnColumn = m.bottomRowReturnColumn
            out.modifierLetterRatio = m.modifierLetterRatio
            out.pad = m.pad
            return out
        }
    }
}
