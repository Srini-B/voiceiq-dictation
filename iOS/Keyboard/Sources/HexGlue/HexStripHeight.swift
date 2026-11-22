import CoreGraphics

/// VoiceiQ's one row above the keys is as tall as Apple's suggestion bar in
/// portrait, its buttons and suggestions centred with equal room above and
/// below, instead of Hex's 27 pt strip. Landscape keeps Hex's 42 pt strip,
/// already Apple's size there. Hex's metrics take it through the patch's
/// `KeyboardMetrics.phoneOverride`.
enum HexStripHeight {
    static let portrait: CGFloat = 44

    static func install() {
        KeyboardMetrics.phoneOverride = { metrics, orientation in
            guard orientation == .portrait else { return metrics }
            return KeyboardMetrics(
                side: metrics.side, gap: metrics.gap, rowGap: metrics.rowGap, keyHeight: metrics.keyHeight,
                stripTop: metrics.stripTop, stripHeight: portrait, stripBottom: metrics.stripBottom,
                keysTop: metrics.keysTop, keysBottom: metrics.keysBottom, cornerRadius: metrics.cornerRadius
            )
        }
    }
}
