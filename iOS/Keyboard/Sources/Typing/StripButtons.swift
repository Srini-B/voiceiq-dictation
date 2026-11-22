import UIKit

/// VoiceiQ's buttons around Hex's keys: the voice panel at the strip's leading end and
/// the mic at its trailing end, the three suggestions between them, and Mini Keyboard
/// and Edit either side of the space bar. Where the bottom row has no room for them (an
/// email or URL field's extra keys) they go back to the strip, beside the voice panel
/// and the mic; under 360 pt (iPad's floating keyboard) Mini Keyboard then stays out,
/// and the voice panel's bar has it instead.
enum StripButton: CaseIterable {
    case voice, mini, edit, mic

    /// Each strip button's touch target is as wide as this and as tall as the strip,
    /// as Hex's strip pills are.
    static let width: CGFloat = 36
    static let narrowBar: CGFloat = 360

    static func ends(barWidth: CGFloat, besideSpace: Bool) -> (leading: [StripButton], trailing: [StripButton]) {
        if besideSpace { return ([.voice], [.mic]) }
        return barWidth < narrowBar ? ([.voice], [.edit, .mic]) : ([.voice, .mini], [.edit, .mic])
    }

    /// The room Hex's bottom row leaves on each side of the space bar
    /// (`KeyboardLayout.spaceSideRoom`, from the patch): a letter key and a gap for
    /// Mini Keyboard and for Edit, as long as the space bar keeps two letters' width
    /// and a gap; otherwise none.
    static func spaceSideRoom(spaceWidth: CGFloat, keyWidth: CGFloat, gap: CGFloat) -> CGFloat {
        let room = keyWidth + gap
        return spaceWidth - 2 * room >= minimumSpace(keyWidth: keyWidth, gap: gap) ? room : 0
    }

    static func minimumSpace(keyWidth: CGFloat, gap: CGFloat) -> CGFloat { 2 * keyWidth + gap }

    /// Mini Keyboard's and Edit's keys either side of the space bar, where the layout
    /// left them room, in the layout's coordinates.
    static func besideSpace(in layout: KeyboardLayout) -> (mini: CGRect, edit: CGRect)? {
        guard !layout.isSplit, let space = layout.key(.space)?.frame else { return nil }
        let row = layout.keys.filter { $0.row == 3 && $0.kind != .space }.map(\.frame)
        guard let before = row.filter({ $0.maxX <= space.minX }).max(by: { $0.maxX < $1.maxX }),
              let after = row.filter({ $0.minX >= space.maxX }).min(by: { $0.minX < $1.minX })
        else { return nil }
        let gap = layout.metrics.gap
        let miniWidth = space.minX - before.maxX - 2 * gap
        let editWidth = after.minX - space.maxX - 2 * gap
        guard miniWidth > 1, editWidth > 1 else { return nil }
        return (CGRect(x: before.maxX + gap, y: space.minY, width: miniWidth, height: space.height),
                CGRect(x: space.maxX + gap, y: space.minY, width: editWidth, height: space.height))
    }

    /// The buttons' frames, and the strip and its three slots between them, in the
    /// keys view's coordinates. The outer buttons line up with the keys' edges.
    static func layout(
        bar: CGRect, side: CGFloat, besideSpace: (mini: CGRect, edit: CGRect)? = nil
    ) -> (buttons: [StripButton: CGRect], strip: CGRect, slots: [CGRect]) {
        let ends = ends(barWidth: bar.width, besideSpace: besideSpace != nil)
        var buttons: [StripButton: CGRect] = [:]
        if let besideSpace {
            buttons[.mini] = besideSpace.mini
            buttons[.edit] = besideSpace.edit
        }
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

/// Mini Keyboard or Edit: a bare glyph in the strip, or a key like Hex's emoji key
/// beside the space bar.
final class StripKeyButton: UIButton {
    var isKey = false { didSet { if isKey != oldValue { applyStyle() } } }
    var cornerRadius: CGFloat = FullKeyboardPalette.cornerRadius { didSet { layer.cornerRadius = cornerRadius } }

    private static let keyFill = UIColor { FullKeyboardPalette(isDark: $0.userInterfaceStyle == .dark).keyFill }
    private static let keyPressedFill = UIColor { FullKeyboardPalette(isDark: $0.userInterfaceStyle == .dark).keyPressedFill }
    private static let keyGlyph = UIColor { FullKeyboardPalette(isDark: $0.userInterfaceStyle == .dark).textBase }

    convenience init(_ button: StripButton) {
        self.init(type: .custom)
        setImage(.stripSymbol(button.symbol), for: .normal)
        accessibilityLabel = button.label
        layer.cornerCurve = .continuous
        applyStyle()
    }

    override var isHighlighted: Bool { didSet { applyStyle() } }

    private func applyStyle() {
        layer.cornerRadius = isKey ? cornerRadius : 0
        backgroundColor = isKey ? (isHighlighted ? Self.keyPressedFill : Self.keyFill) : .clear
        tintColor = isKey ? Self.keyGlyph : KeyboardPalette.accentUIColor
        imageView?.alpha = !isKey && isHighlighted ? 0.4 : 1
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
