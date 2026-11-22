import CoreGraphics

/// VoiceiQ's one row above the keys: the strip runs from the keyboard view's top
/// edge down to the keys, with its content centred, so the content has as much
/// room above it, up to the keyboard's edge, as below it, down to the keys.
/// 44 pt in portrait (Apple's suggestion bar), Hex's 50 pt turned.
///
/// iOS 26 and later draw about 17 pt of their own panel above a third-party
/// keyboard in some presentations and nothing in others, and a keyboard can't
/// tell which (Hex's measurements, iPhone 17 Pro, iOS 27.2; the iOS 27.0
/// Simulator drew it in one run and not in the next). Where it is drawn, the
/// room above the content is that much larger. Hex's metrics take this through
/// the patch's `KeyboardMetrics.phoneOverride`.
enum HexStripHeight {
    static let portrait: CGFloat = 44
    static let landscape: CGFloat = 50

    static func install() {
        KeyboardMetrics.phoneOverride = { metrics, orientation in
            let area = orientation == .landscape ? landscape : portrait
            return KeyboardMetrics(
                side: metrics.side, gap: metrics.gap, rowGap: metrics.rowGap, keyHeight: metrics.keyHeight,
                stripTop: metrics.stripTop, stripHeight: area - metrics.stripTop, stripBottom: 0,
                keysTop: metrics.keysTop, keysBottom: metrics.keysBottom, cornerRadius: metrics.cornerRadius
            )
        }
    }
}
