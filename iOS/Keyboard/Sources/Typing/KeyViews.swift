import UIKit

/// One key: a face drawn by the theme, its label or symbol, and a
/// highlighted state while pressed.
final class KeyCapView: UIView {
    let spec: KeySpec
    private let face = CAGradientLayer()
    private let label = UILabel()
    private let image = UIImageView()
    private var shift: ShiftState = .off
    private var returnEnabled = true

    var theme = KeyTheme.standard {
        didSet { applyTheme() }
    }

    var labelAlpha: CGFloat = 1 {
        didSet { label.alpha = labelAlpha; image.alpha = labelAlpha }
    }

    var isHighlighted = false { didSet { if isHighlighted != oldValue { applyColors() } } }

    init(spec: KeySpec) {
        self.spec = spec
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.shadowOpacity = 1
        layer.addSublayer(face)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        image.contentMode = .center
        addSubview(label)
        addSubview(image)
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let faceFrame = bounds.inset(by: theme.faceInsets)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.frame = faceFrame
        CATransaction.commit()
        image.frame = faceFrame
        label.frame = faceFrame.insetBy(dx: 2, dy: 0).offsetBy(dx: 0, dy: labelOffset)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    /// UILabel centres the font's whole line box, which leaves letters low on
    /// the key. Centre capitals, digits and punctuation on the cap height and
    /// lowercase words on the x-height instead, as the iOS keyboard does.
    private var labelOffset: CGFloat {
        guard let text = label.text, let font = label.font else { return 0 }
        let lowercase = text.contains(where: \.isLowercase) && !text.contains(where: \.isUppercase)
        let visible = lowercase ? font.xHeight : font.capHeight
        // UILabel still draws about 1.2 pt below the line box centre
        // (measured on the Simulator at 3x), so lift by that too.
        return visible / 2 - (font.ascender - font.lineHeight / 2) - 1.2
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
    }

    private func applyTheme() {
        layer.cornerRadius = theme.cornerRadius
        layer.shadowOffset = CGSize(width: 0, height: theme.shadowOffset)
        layer.shadowRadius = theme.shadowRadius
        let inset = max(theme.faceInsets.left, theme.faceInsets.top)
        face.cornerRadius = max(2, theme.cornerRadius - inset / 2)
        face.borderWidth = theme.border == nil ? 0 : 1 / max(1, traitCollection.displayScale)
        update(shift: shift, returnEnabled: returnEnabled)
        setNeedsLayout()
    }

    private var isFunction: Bool {
        switch spec.action {
        case .insert, .space: return false
        default: return true
        }
    }

    func update(shift: ShiftState, returnEnabled: Bool) {
        self.shift = shift
        self.returnEnabled = returnEnabled
        label.text = nil
        image.image = nil
        let symbol = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        switch spec.action {
        case .insert(let text):
            let shown = spec.isLetter && shift != .off ? text.uppercased() : (spec.label.isEmpty ? text : spec.label)
            label.text = shown
            label.font = theme.font(size: shown.count == 1 ? 24 : 16)
            accessibilityLabel = shown
        case .shift:
            let name = shift == .locked ? "capslock.fill" : (shift == .once ? "shift.fill" : "shift")
            image.image = UIImage(systemName: name, withConfiguration: symbol)
            accessibilityLabel = shift == .locked ? "Caps Lock" : "Shift"
        case .delete:
            image.image = UIImage(systemName: "delete.left", withConfiguration: symbol)
            accessibilityLabel = "Delete"
        case .globe:
            image.image = UIImage(systemName: "globe", withConfiguration: symbol)
            accessibilityLabel = "Next keyboard"
        case .emoji:
            image.image = UIImage(systemName: "face.smiling", withConfiguration: symbol)
            accessibilityLabel = "Emoji"
        case .space:
            label.text = "space"
            label.font = theme.font(size: 16)
            accessibilityLabel = "Space"
        case .returnKey:
            if spec.label == "return" {
                image.image = UIImage(systemName: "return.left", withConfiguration: symbol)
            } else {
                label.text = spec.label
                label.font = theme.font(size: 16)
            }
            accessibilityLabel = spec.label
        case .page:
            label.text = spec.label
            label.font = theme.font(size: 16)
            accessibilityLabel = spec.label == "ABC" ? "Letters" : (spec.label == "123" ? "Numbers" : "Symbols")
        }
        applyColors()
        setNeedsLayout()
    }

    private func applyColors() {
        let shiftOn = spec.action == .shift && shift != .off
        let primaryReturn = spec.action == .returnKey && spec.label != "return" && returnEnabled
        var key = isFunction && !shiftOn ? theme.function : theme.character
        if isHighlighted { key = isFunction ? theme.character : theme.function }
        if primaryReturn { key = KeyFace(top: .tintColor, bottom: .tintColor, label: .white, body: key.body) }
        let traits = traitCollection
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.colors = [key.top.resolvedColor(with: traits).cgColor, key.bottom.resolvedColor(with: traits).cgColor]
        face.borderColor = theme.border?.resolvedColor(with: traits).cgColor
        layer.backgroundColor = key.body?.resolvedColor(with: traits).cgColor
        layer.shadowColor = theme.shadow.resolvedColor(with: traits).cgColor
        CATransaction.commit()
        let text = returnEnabled || spec.action != .returnKey ? key.label : key.label.withAlphaComponent(0.35)
        label.textColor = text
        image.tintColor = text
    }
}

/// The enlarged letter above a pressed key.
final class KeyPreview: UIView {
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String, over key: CGRect, in parent: UIView, theme: KeyTheme) {
        if superview !== parent { parent.addSubview(self) }
        parent.bringSubviewToFront(self)
        backgroundColor = theme.popup
        label.textColor = theme.character.label
        label.font = theme.font(size: 34)
        label.text = text
        let width = key.width + 18, height = key.height + 14
        frame = CGRect(x: key.midX - width / 2, y: key.minY - height - 4, width: width, height: height)
        // Keep it on screen at the edges.
        frame.origin.x = min(max(frame.minX, 0), parent.bounds.width - width)
        label.frame = bounds
        isHidden = false
    }
}

/// The accents or alternates shown by holding a key; sliding picks one.
final class AccentPopup: UIView {
    private var labels: [UILabel] = []
    private let cell: CGSize

    private let theme: KeyTheme

    init(key: CGRect, options: [String], in bounds: CGRect, theme: KeyTheme) {
        self.theme = theme
        cell = CGSize(width: max(key.width, 30), height: key.height + 8)
        let width = cell.width * CGFloat(options.count)
        var x = key.midX - cell.width / 2
        if x + width > bounds.width - 2 { x = key.maxX - width }
        x = max(2, x)
        super.init(frame: CGRect(x: x, y: key.minY - cell.height - 6, width: width, height: cell.height))
        isUserInteractionEnabled = false
        backgroundColor = theme.popup
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        for (i, option) in options.enumerated() {
            let label = UILabel(frame: CGRect(x: CGFloat(i) * cell.width, y: 0, width: cell.width, height: cell.height))
            label.text = option
            label.textAlignment = .center
            label.font = theme.font(size: option.count > 2 ? 16 : 24)
            label.layer.cornerRadius = 6
            label.clipsToBounds = true
            addSubview(label)
            labels.append(label)
        }
        _ = select(at: CGPoint(x: key.midX - x, y: 0))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Highlights the option under the finger and returns its index.
    func select(at point: CGPoint) -> Int {
        let index = min(labels.count - 1, max(0, Int(point.x / cell.width)))
        for (i, label) in labels.enumerated() {
            label.backgroundColor = i == index ? .tintColor : .clear
            label.textColor = i == index ? .white : theme.character.label
        }
        return index
    }
}
