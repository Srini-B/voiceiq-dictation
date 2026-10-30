import UIKit

enum KeyColors {
    /// Letter keys: white in light mode, light grey in dark.
    static let character = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
    /// Shift, delete, 123, return: a shade darker than the letters.
    static let function = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1) }
    static let shadow = UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.6) : UIColor(red: 0.53, green: 0.54, blue: 0.56, alpha: 1) }
    static let popup = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
}

/// One key: a rounded cap with a one-point shadow, its label or symbol, and
/// a highlighted state while pressed.
final class KeyCapView: UIView {
    let spec: KeySpec
    private let label = UILabel()
    private let image = UIImageView()
    private var shift: ShiftState = .off
    private var returnEnabled = true

    var labelAlpha: CGFloat = 1 {
        didSet { label.alpha = labelAlpha; image.alpha = labelAlpha }
    }

    var isHighlighted = false { didSet { if isHighlighted != oldValue { applyColors() } } }

    init(spec: KeySpec) {
        self.spec = spec
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = 5.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        layer.shadowOpacity = 1
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        image.contentMode = .center
        image.tintColor = .label
        addSubview(label)
        addSubview(image)
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        image.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
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
            label.font = .systemFont(ofSize: shown.count == 1 ? 24 : 16, weight: .regular)
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
            label.font = .systemFont(ofSize: 16)
            accessibilityLabel = "Space"
        case .returnKey:
            if spec.label == "return" {
                image.image = UIImage(systemName: "return.left", withConfiguration: symbol)
            } else {
                label.text = spec.label
                label.font = .systemFont(ofSize: 16)
            }
            accessibilityLabel = spec.label
        case .page:
            label.text = spec.label
            label.font = .systemFont(ofSize: 16)
            accessibilityLabel = spec.label == "ABC" ? "Letters" : (spec.label == "123" ? "Numbers" : "Symbols")
        }
        label.textColor = returnEnabled || spec.action != .returnKey ? .label : .tertiaryLabel
        applyColors()
    }

    private func applyColors() {
        let shiftOn = spec.action == .shift && shift != .off
        let primaryReturn = spec.action == .returnKey && spec.label != "return" && returnEnabled
        var fill = isFunction ? KeyColors.function : KeyColors.character
        if shiftOn { fill = KeyColors.character }
        if primaryReturn { fill = .tintColor }
        if isHighlighted { fill = isFunction ? KeyColors.character : KeyColors.function }
        backgroundColor = fill
        layer.shadowColor = KeyColors.shadow.resolvedColor(with: traitCollection).cgColor
        label.textColor = primaryReturn ? .white : (returnEnabled || spec.action != .returnKey ? .label : .tertiaryLabel)
    }
}

/// The enlarged letter above a pressed key.
final class KeyPreview: UIView {
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        backgroundColor = KeyColors.popup
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.font = .systemFont(ofSize: 34)
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String, over key: CGRect, in parent: UIView) {
        if superview !== parent { parent.addSubview(self) }
        parent.bringSubviewToFront(self)
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

    init(key: CGRect, options: [String], in bounds: CGRect) {
        cell = CGSize(width: max(key.width, 30), height: key.height + 8)
        let width = cell.width * CGFloat(options.count)
        var x = key.midX - cell.width / 2
        if x + width > bounds.width - 2 { x = key.maxX - width }
        x = max(2, x)
        super.init(frame: CGRect(x: x, y: key.minY - cell.height - 6, width: width, height: cell.height))
        isUserInteractionEnabled = false
        backgroundColor = KeyColors.popup
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        for (i, option) in options.enumerated() {
            let label = UILabel(frame: CGRect(x: CGFloat(i) * cell.width, y: 0, width: cell.width, height: cell.height))
            label.text = option
            label.textAlignment = .center
            label.font = .systemFont(ofSize: option.count > 2 ? 16 : 24)
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
            label.textColor = i == index ? .white : .label
        }
        return index
    }
}
