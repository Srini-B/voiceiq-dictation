import UIKit
import VoiceIQBridge

enum ShiftState: Equatable {
    case off, once, locked
}

/// What the key area reports; `TypingController` acts on it.
@MainActor
protocol KeyboardKeysDelegate: AnyObject {
    func keyDown(_ key: KeySpec)
    func keyTapped(_ key: KeySpec, text: String?)
    func deleteRepeated(words: Bool)
    /// The finger's path, with each point's `UITouch.timestamp`.
    func swiped(_ points: [CGPoint], times: [TimeInterval])
    /// Whether a slide may start a word here; mid-word only after a whole word.
    var canStartSwipe: Bool { get }
    func cursorMoved(by offset: Int)
    /// Sliding left from delete: `steps` words or characters, by `deleteSlide`.
    func deleteSlideBegan()
    func deleteSlid(steps: Int)
    func deleteSlideEnded()
    func shiftReleased()
}

/// The keys: drawn as plain views and driven by raw touches, so a press can
/// become a tap, an accent pick, a swipe through letters, or a cursor drag on
/// the space bar. A touch goes to the nearest key in its row, so the gaps
/// between keys type too.
final class KeyboardKeysView: UIView {
    weak var delegate: KeyboardKeysDelegate?
    weak var inputController: UIInputViewController?
    /// Called with the letter positions after each layout of the letter page.
    var onLayout: ((KeyGeometry) -> Void)?

    var rows: [[KeySpec]] = [] { didSet { if rows != oldValue { rebuild() } } }
    var shift: ShiftState = .off { didSet { if shift != oldValue { refreshLabels() } } }
    var slideToType = true
    var spaceSlide = KeyboardSpaceSlide.cursor
    var deleteSlide = KeyboardDeleteSlide.words
    var returnEnabled = true { didSet { if returnEnabled != oldValue { refreshLabels() } } }
    var theme = KeyTheme.standard { didSet { keys.forEach { $0.view.theme = theme } } }

    private struct Key {
        let spec: KeySpec
        let view: KeyCapView
        var frame: CGRect = .zero
        let row: Int
    }

    private enum Gesture {
        case press
        case accents(AccentPopup, selected: Int)
        case swipe([CGPoint], times: [TimeInterval])
        case cursor(anchorX: CGFloat)
        case delete(Timer?)
        case deleteSlide
    }

    private final class Tracked {
        /// The key a tap types: the one under the finger, once it is clearly on it.
        var key: Int
        let start: CGPoint
        /// `UITouch.timestamp` of the press.
        let began: TimeInterval
        /// Pressed within `fastTyping` of the last typed letter.
        let afterTyping: Bool
        var gesture: Gesture = .press
        var longPress: Timer?
        /// Every sample since the press, so a slide that starts late keeps
        /// the turns and timing before its threshold.
        var path: [CGPoint]
        var times: [TimeInterval]
        init(key: Int, start: CGPoint, began: TimeInterval, afterTyping: Bool) {
            self.key = key; self.start = start; self.began = began; self.afterTyping = afterTyping
            path = [start]; times = [began]
        }
    }

    private var keys: [Key] = []
    private var tracked: [ObjectIdentifier: Tracked] = [:]
    private var lastTypedAt: CFTimeInterval = 0
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
        // Held touches point into the old keys, and a held delete owns a timer.
        let held = tracked.values
        tracked = [:]
        held.forEach { finish($0, cancelled: true) }
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
                if spec.action != .globe, !spec.label.isEmpty {
                    view.onActivate = { [weak self] in self?.activate(spec) }
                }
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

    /// A key's plain tap, as touches deliver it, for VoiceOver.
    private func activate(_ spec: KeySpec) {
        delegate?.keyDown(spec)
        delegate?.keyTapped(spec, text: nil)
        if spec.action == .shift { delegate?.shiftReleased() }
    }

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
            let state = Tracked(key: index, start: point, began: touch.timestamp,
                                afterTyping: CACurrentMediaTime() - lastTypedAt < Self.fastTyping)
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
                if spec.isLetter, slideToType { record(touch, event, into: &state.path, &state.times) }
                let moved = hypot(point.x - state.start.x, point.y - state.start.y)
                // A finger that is sliding is not holding for accents.
                if moved > 8 { state.longPress?.invalidate() }
                if spec.action == .space, spaceSlide == .cursor, abs(point.x - state.start.x) > 12 {
                    state.gesture = .cursor(anchorX: point.x)
                    keys[state.key].view.isHighlighted = false
                    setCursorMode(true)
                } else if spec.isLetter, slideToType, tracked.count == 1, startsSwipe(state, at: point, time: touch.timestamp),
                          delegate?.canStartSwipe ?? true {
                    state.longPress?.invalidate()
                    hidePreview()
                    keys[state.key].view.isHighlighted = false
                    state.gesture = .swipe(state.path, times: state.times)
                    drawTrail(state.path)
                } else if isCharacter(spec), let index = keyIndex(at: point), index != state.key,
                          isCharacter(keys[index].spec), distanceOutside(keys[state.key].frame, point) > Self.hysteresis {
                    // The tap follows the finger to the key it lifts on, as on iOS.
                    keys[state.key].view.isHighlighted = false
                    state.key = index
                    keys[index].view.isHighlighted = true
                    showPreview(for: index)
                }
            case .accents(let popup, _):
                state.gesture = .accents(popup, selected: popup.select(at: convert(point, to: popup)))
            case .swipe(var points, var times):
                record(touch, event, into: &points, &times)
                state.gesture = .swipe(points, times: times)
                drawTrail(points)
            case .cursor(let anchorX):
                let step: CGFloat = 9
                let offset = Int((point.x - anchorX) / step)
                if offset != 0 {
                    delegate?.cursorMoved(by: offset)
                    state.gesture = .cursor(anchorX: anchorX + CGFloat(offset) * step)
                }
            case .delete(let timer):
                if deleteSlide != .off, state.start.x - point.x > 12 {
                    timer?.invalidate()
                    state.gesture = .deleteSlide
                    delegate?.deleteSlideBegan()
                }
            case .deleteSlide:
                let step: CGFloat = deleteSlide == .characters ? 9 : 22
                delegate?.deleteSlid(steps: max(0, Int((state.start.x - point.x) / step)))
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
            default:
                delegate?.keyTapped(spec, text: nil)
                if isCharacter(spec) { lastTypedAt = CACurrentMediaTime() }
            }
        case .accents(let popup, let selected):
            popup.removeFromSuperview()
            if !cancelled { delegate?.keyTapped(spec, text: spec.alternates[selected]) }
        case .swipe(let points, let times):
            trail.path = nil
            if cancelled { break }
            // Under most of a key of travel is a tap that drifted, not a word.
            let travel = zip(points, points.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            if travel < (keys[state.key].frame.width + Self.horizontalGap) * 0.8 {
                let index = points.last.flatMap(keyIndex(at:)).flatMap { isCharacter(keys[$0].spec) ? $0 : nil } ?? state.key
                delegate?.keyTapped(keys[index].spec, text: nil)
                lastTypedAt = CACurrentMediaTime()
            } else {
                delegate?.swiped(points, times: times)
            }
        case .cursor:
            setCursorMode(false)
        case .delete(let timer):
            timer?.invalidate()
        case .deleteSlide:
            delegate?.deleteSlideEnded()
        }
        if spec.action == .shift { delegate?.shiftReleased() }
    }

    // MARK: - Tap or slide

    /// AOSP LatinIME's gesture start with the values it ships
    /// (`config-common.xml`): within half a second of a typed letter, a slide
    /// must last about 185 ms and cross about 3.7 keys to count, easing to
    /// half a key by 450 ms, so a fast typist's drifting tap stays a tap.
    private static let fastTyping: CFTimeInterval = 0.5
    private static let thresholdDecay: CFTimeInterval = 0.45
    /// How far past a key's edge a tap must go to type the next key instead.
    private static let hysteresis: CGFloat = 8

    private func startsSwipe(_ state: Tracked, at point: CGPoint, time: TimeInterval) -> Bool {
        let keyWidth = keys[state.key].frame.width + Self.horizontalGap
        let distance = hypot(point.x - state.start.x, point.y - state.start.y) / keyWidth
        let elapsed = time - state.began
        guard state.afterTyping, elapsed < Self.thresholdDecay else { return elapsed >= 0.02 && distance >= 0.5 }
        let decay = elapsed / Self.thresholdDecay
        return elapsed >= 0.3 - 0.28 * decay && distance >= 6 - 5.5 * decay
    }

    /// Every sample the screen took, not one per frame: the model reads speed.
    private func record(_ touch: UITouch, _ event: UIEvent?, into points: inout [CGPoint], _ times: inout [TimeInterval]) {
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let p = sample.location(in: self)
            if hypot(p.x - points[points.count - 1].x, p.y - points[points.count - 1].y) > 1 {
                points.append(p)
                times.append(sample.timestamp)
            }
        }
    }

    private func distanceOutside(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
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
                    if case .delete = state.gesture { state.gesture = .delete(timer) } else { timer.invalidate() }
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
