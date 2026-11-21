import UIKit

/// VoiceiQ's buttons in Hex's suggestion strip, so the keyboard has one row above
/// the keys: the voice panel and Mini Keyboard at the leading end, Edit and the mic
/// at the trailing end, the three suggestions between them. Under 360 pt (iPad's
/// floating keyboard) the suggestions keep room by dropping Mini Keyboard here; the
/// voice panel's bar has it instead.
enum StripButton: CaseIterable {
    case voice, mini, edit, mic

    /// Each button's touch target is as wide as this and as tall as the strip, as
    /// Hex's strip pills are.
    static let width: CGFloat = 36
    static let narrowBar: CGFloat = 360

    static func ends(barWidth: CGFloat) -> (leading: [StripButton], trailing: [StripButton]) {
        barWidth < narrowBar ? ([.voice], [.edit, .mic]) : ([.voice, .mini], [.edit, .mic])
    }

    /// The buttons' frames, and the strip and its three slots between them, in the
    /// keys view's coordinates. The outer buttons line up with the keys' edges.
    static func layout(bar: CGRect, side: CGFloat) -> (buttons: [StripButton: CGRect], strip: CGRect, slots: [CGRect]) {
        let ends = ends(barWidth: bar.width)
        var buttons: [StripButton: CGRect] = [:]
        var x = bar.minX + side
        for button in ends.leading {
            buttons[button] = CGRect(x: x, y: bar.minY, width: width, height: bar.height)
            x += width
        }
        var end = bar.maxX - side
        for button in ends.trailing.reversed() {
            end -= width
            buttons[button] = CGRect(x: end, y: bar.minY, width: width, height: bar.height)
        }
        let strip = CGRect(x: x, y: bar.minY, width: max(0, end - x), height: bar.height)
        let third = strip.width / 3
        let slots = (0..<3).map { CGRect(x: strip.minX + CGFloat($0) * third, y: strip.minY, width: third, height: strip.height) }
        return (buttons, strip, slots)
    }

    var symbol: String {
        switch self {
        case .voice: "waveform"
        case .mini: "arrow.down.right.and.arrow.up.left"
        case .edit: "character.cursor.ibeam"
        case .mic: "mic.fill"
        }
    }

    var label: String {
        switch self {
        case .voice: "VoiceiQ"
        case .mini: "Mini Keyboard"
        case .edit: "Edit"
        case .mic: "Dictate"
        }
    }
}

extension UIImage {
    static func stripSymbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
    }
}

/// The strip's mic: the same touch as Hex's key it replaces (`HexKeyGesture`). A tap
/// dictates, a still hold dictates until the finger lifts, and the finger landing
/// already arms the keyboard's capture (`onPress`). Sliding off drops the press.
final class DictationKeyControl: UIControl {
    var onPress: ((TimeInterval) -> Void)?
    var onTap: (() -> Void)?
    var onHold: (() -> Void)?
    var onHoldRelease: (() -> Void)?
    var onAbandon: (() -> Void)?

    private var gesture = HexKeyGesture()
    private var holdWork: DispatchWorkItem?
    private let glyph = UIImageView(image: .stripSymbol(StripButton.mic.symbol))

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.tintColor = KeyboardPalette.accentUIColor
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
        isAccessibilityElement = true
        accessibilityLabel = StripButton.mic.label
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = bounds
    }

    override var isHighlighted: Bool { didSet { glyph.alpha = isHighlighted ? 0.4 : 1 } }

    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        gesture.touchDown(at: touch.location(in: self))
        isHighlighted = true
        holdWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.holdElapsed() }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HexKeyGesture.holdDuration, execute: work)
        onPress?(Date().timeIntervalSince1970 - max(0, ProcessInfo.processInfo.systemUptime - touch.timestamp))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        // Hex opens its style menu here; VoiceiQ has none, so the press is dropped.
        if gesture.touchMoved(to: touch.location(in: self)) == .openMenu {
            stopTimer()
            isHighlighted = false
            onAbandon?()
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        stopTimer()
        isHighlighted = false
        switch gesture.touchUp() {
        case .tap: onTap?()
        case .release: onHoldRelease?()
        default: break
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        stopTimer()
        isHighlighted = false
        if gesture.cancel() == .abandon { onAbandon?() }
    }

    private func holdElapsed() {
        holdWork = nil
        guard gesture.holdElapsed() == .hold else { return }
        isHighlighted = false
        onHold?()
    }

    private func stopTimer() {
        holdWork?.cancel()
        holdWork = nil
    }
}
