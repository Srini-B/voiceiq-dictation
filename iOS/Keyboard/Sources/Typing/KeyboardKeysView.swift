import UIKit

enum ShiftState: Equatable {
    case off, once, locked
}

/// What the key area reports; `TypingController` acts on it.
@MainActor
protocol KeyboardKeysDelegate: AnyObject {
    func keyDown(_ key: KeySpec)
    func keyTapped(_ key: KeySpec, text: String?)
    func deleteRepeated(words: Bool)
    func swiped(_ points: [CGPoint])
    func cursorMoved(by offset: Int)
    func shiftReleased()
}

/// The keys: drawn as plain views and driven by raw touches, so a press can
/// become a tap, an accent pick, a swipe through letters, or a cursor drag on
/// the space bar. A touch goes to the nearest key in its row, so the gaps
/// between keys type too.
final class KeyboardKeysView: UIView, UIInputViewAudioFeedback {
    weak var delegate: KeyboardKeysDelegate?
    weak var inputController: UIInputViewController?
    /// Called with the letter positions after each layout of the letter page.
    var onLayout: ((KeyGeometry) -> Void)?

    var rows: [[KeySpec]] = [] { didSet { if rows != oldValue { rebuild() } } }
    var shift: ShiftState = .off { didSet { if shift != oldValue { refreshLabels() } } }
    var slideToType = true
    var returnEnabled = true { didSet { if returnEnabled != oldValue { refreshLabels() } } }
    var theme = KeyTheme.standard { didSet { keys.forEach { $0.view.theme = theme } } }

    var enableInputClicksWhenVisible: Bool { true }

    private struct Key {
        let spec: KeySpec
        let view: KeyCapView
        var frame: CGRect = .zero
        let row: Int
    }

    private enum Gesture {
        case press
        case accents(AccentPopup, selected: Int)
        case swipe([CGPoint])
        case cursor(anchorX: CGFloat)
        case delete(Timer?)
    }

    private final class Tracked {
        let key: Int
        let start: CGPoint
        var gesture: Gesture = .press
        var longPress: Timer?
        init(key: Int, start: CGPoint) { self.key = key; self.start = start }
    }

    private var keys: [Key] = []
    private var tracked: [ObjectIdentifier: Tracked] = [:]
    private let preview = KeyPreview()
    private let trail = CAShapeLayer()
    private var globe: UIButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        trail.strokeColor = UIColor.tintColor.withAlphaComponent(0.55).cgColor
        trail.fillColor = nil
        trail.lineWidth = 6
        trail.lineCap = .round
        trail.lineJoin = .round
        // Above the keys, as on the iOS keyboard.
        trail.zPosition = 1
        layer.addSublayer(trail)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private static let horizontalGap: CGFloat = 6
    private static let verticalGap: CGFloat = 11
    private static let sideInset: CGFloat = 3

    /// Letter key centres for corrections and slide to type.
    var geometry: KeyGeometry? {
        var centers: [Character: CGPoint] = [:]
        var width: CGFloat = 0, height: CGFloat = 0
        for key in keys where key.spec.isLetter {
            if case .insert(let text) = key.spec.action, let c = text.first {
                centers[c] = CGPoint(x: key.frame.midX, y: key.frame.midY)
                width = key.frame.width + Self.horizontalGap
                height = key.frame.height + Self.verticalGap
            }
        }
        return centers.count >= 20 ? KeyGeometry(centers: centers, keyWidth: width, keyHeight: height) : nil
    }

    private func rebuild() {
        keys.forEach { $0.view.removeFromSuperview() }
        globe?.removeFromSuperview()
        globe = nil
        keys = []
        for (r, row) in rows.enumerated() {
            for spec in row {
                if spec.action == .globe, let inputController {
                    let button = UIButton(type: .custom)
                    button.addTarget(inputController, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
                    button.accessibilityLabel = "Next keyboard"
                    globe = button
                }
                let view = KeyCapView(spec: spec)
                view.theme = theme
                addSubview(view)
                keys.append(Key(spec: spec, view: view, row: r))
            }
        }
        if let globe { addSubview(globe) }
        bringSubviewToFront(preview)
        setNeedsLayout()
        refreshLabels()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !rows.isEmpty else { return }
        let rowHeight = (bounds.height - Self.verticalGap * CGFloat(rows.count - 1) - 4) / CGFloat(rows.count)
        let available = bounds.width - Self.sideInset * 2
        let widest = rows.map { $0.filter { $0.width == .unit }.count }.max() ?? 10
        let unit = (available - Self.horizontalGap * CGFloat(max(widest, 10) - 1)) / CGFloat(max(widest, 10))
        var index = 0
        for (r, row) in rows.enumerated() {
            let y = 4 + CGFloat(r) * (rowHeight + Self.verticalGap)
            let fixed = row.reduce(CGFloat(0)) { total, spec in
                switch spec.width {
                case .unit: return total + unit
                case .units(let n): return total + unit * n
                case .flexible: return total
                }
            }
            let gaps = Self.horizontalGap * CGFloat(row.count - 1)
            let flexibleCount = row.filter { $0.width == .flexible }.count
            let flexible = flexibleCount > 0 ? max(0, (available - fixed - gaps) / CGFloat(flexibleCount)) : 0
            // A row too wide for the screen shrinks evenly; a short one is centred.
            let total = fixed + gaps + flexible * CGFloat(flexibleCount)
            let scale = total > available ? (available - gaps) / (total - gaps) : 1
            var x = Self.sideInset + (total < available ? (available - total) / 2 : 0)
            for spec in row {
                var width: CGFloat
                switch spec.width {
                case .unit: width = unit
                case .units(let n): width = unit * n
                case .flexible: width = flexible
                }
                width *= scale
                let frame = CGRect(x: x, y: y, width: width, height: rowHeight)
                keys[index].frame = frame
                keys[index].view.frame = frame
                if spec.action == .globe { globe?.frame = frame.insetBy(dx: -3, dy: -5) }
                x += width + Self.horizontalGap
                index += 1
            }
        }
        trail.frame = bounds
        if let geometry { onLayout?(geometry) }
    }

    private func refreshLabels() {
        for key in keys {
            key.view.update(shift: shift, returnEnabled: returnEnabled)
        }
    }

    /// Dims the letters while the space bar moves the cursor, as iOS does.
    private func setCursorMode(_ on: Bool) {
        UIView.animate(withDuration: 0.15) {
            for key in self.keys { key.view.labelAlpha = on ? 0 : 1 }
        }
    }

    // MARK: - Hit testing

    private func keyIndex(at point: CGPoint) -> Int? {
        guard !keys.isEmpty else { return nil }
        let rowCount = rows.count
        let pitch = bounds.height / CGFloat(rowCount)
        let row = min(rowCount - 1, max(0, Int(point.y / pitch)))
        var best: Int?, bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, key) in keys.enumerated() where key.row == row {
            let dx = max(key.frame.minX - point.x, 0, point.x - key.frame.maxX)
            if dx < bestDistance { best = i; bestDistance = dx }
        }
        return best
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            guard let index = keyIndex(at: point) else { continue }
            let spec = keys[index].spec
            if spec.action == .globe || spec.label.isEmpty { continue }
            // Rolling over: a new key commits the one still held.
            for (id, other) in tracked where !(keys[other.key].spec.action == .shift) {
                if case .press = other.gesture, keys[other.key].spec.isLetter || isCharacter(keys[other.key].spec) {
                    finish(other, cancelled: false)
                    tracked[id] = nil
                }
            }
            let state = Tracked(key: index, start: point)
            tracked[ObjectIdentifier(touch)] = state
            keys[index].view.isHighlighted = true
            delegate?.keyDown(spec)
            switch spec.action {
            case .delete:
                delegate?.keyTapped(spec, text: nil)
                state.gesture = .delete(startDeleteRepeat())
            case .shift:
                delegate?.keyTapped(spec, text: nil)
            case .insert:
                if rows.count > 4 || isCharacter(spec) { showPreview(for: index) }
                if !spec.alternates.isEmpty {
                    state.longPress = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self, weak state] _ in
                        MainActor.assumeIsolated {
                            guard let self, let state, case .press = state.gesture else { return }
                            self.hidePreview()
                            let popup = AccentPopup(key: self.keys[index].frame, options: spec.alternates.map { self.cased($0) }, in: self.bounds, theme: self.theme)
                            self.addSubview(popup)
                            state.gesture = .accents(popup, selected: 0)
                        }
                    }
                }
            default:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = tracked[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            let spec = keys[state.key].spec
            switch state.gesture {
            case .press:
                let moved = hypot(point.x - state.start.x, point.y - state.start.y)
                let width = keys[state.key].frame.width
                // A finger that is sliding is not holding for accents.
                if moved > 8 { state.longPress?.invalidate() }
                // A slide starts once the finger reaches another key, so a
                // touch near the edge of the first letter still slides to
                // its neighbour; a long move anywhere counts too.
                let leftKey = moved > width * 0.35 && keyIndex(at: point) != state.key
                if spec.action == .space, abs(point.x - state.start.x) > 12 {
                    state.gesture = .cursor(anchorX: point.x)
                    keys[state.key].view.isHighlighted = false
                    setCursorMode(true)
                } else if spec.isLetter, slideToType, tracked.count == 1, leftKey || moved > width * 0.75 {
                    state.longPress?.invalidate()
                    hidePreview()
                    keys[state.key].view.isHighlighted = false
                    state.gesture = .swipe([state.start, point])
                    drawTrail([state.start, point])
                }
            case .accents(let popup, _):
                state.gesture = .accents(popup, selected: popup.select(at: convert(point, to: popup)))
            case .swipe(var points):
                if let last = points.last, hypot(point.x - last.x, point.y - last.y) > 3 { points.append(point) }
                state.gesture = .swipe(points)
                drawTrail(points)
            case .cursor(let anchorX):
                let step: CGFloat = 9
                let offset = Int((point.x - anchorX) / step)
                if offset != 0 {
                    delegate?.cursorMoved(by: offset)
                    state.gesture = .cursor(anchorX: anchorX + CGFloat(offset) * step)
                }
            case .delete:
                break
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            finish(state, cancelled: false)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            finish(state, cancelled: true)
        }
    }

    private func finish(_ state: Tracked, cancelled: Bool) {
        state.longPress?.invalidate()
        let spec = keys[state.key].spec
        keys[state.key].view.isHighlighted = false
        hidePreview()
        switch state.gesture {
        case .press:
            if cancelled { break }
            switch spec.action {
            case .delete, .shift, .globe: break
            default: delegate?.keyTapped(spec, text: nil)
            }
        case .accents(let popup, let selected):
            popup.removeFromSuperview()
            if !cancelled { delegate?.keyTapped(spec, text: spec.alternates[selected]) }
        case .swipe(let points):
            trail.path = nil
            if !cancelled { delegate?.swiped(points) }
        case .cursor:
            setCursorMode(false)
        case .delete(let timer):
            timer?.invalidate()
        }
        if spec.action == .shift { delegate?.shiftReleased() }
    }

    private func startDeleteRepeat() -> Timer {
        var ticks = 0
        return Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // After about a second of letters, whole words go.
                let timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        ticks += 1
                        self?.delegate?.deleteRepeated(words: ticks > 12)
                    }
                }
                for state in self.tracked.values where self.keys[state.key].spec.action == .delete {
                    state.gesture = .delete(timer)
                }
            }
        }
    }

    // MARK: - Feedback

    private func isCharacter(_ spec: KeySpec) -> Bool {
        if case .insert(let text) = spec.action { return text.count == 1 }
        return false
    }

    private func cased(_ text: String) -> String { shift == .off ? text : text.uppercased() }

    private func showPreview(for index: Int) {
        guard case .insert(let text) = keys[index].spec.action, text.count == 1 else { return }
        preview.show(text: keys[index].spec.isLetter ? cased(text) : text, over: keys[index].frame, in: self, theme: theme)
    }

    private func hidePreview() { preview.isHidden = true }

    private func drawTrail(_ points: [CGPoint]) {
        let path = UIBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.addLine(to: $0) }
        trail.path = path.cgPath
    }
}
