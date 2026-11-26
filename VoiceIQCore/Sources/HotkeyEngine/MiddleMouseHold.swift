import CoreGraphics
import Foundation

/// The middle-mouse dictation trigger: holding the middle button still for
/// `holdDuration` starts or stops a dictation. A click, or a press that drags
/// (panning, autoscroll), is left to the app, which gets every middle press
/// either way. Hex reads the middle button the same way (anomalyco/hex, MIT).
///
/// Pure and clock-free: the tap reports presses, drags and releases, then
/// asks `fire(_:)` once `holdDuration` after the press.
public struct MiddleMouseHold: Sendable {
    public static let holdDuration: TimeInterval = 0.5
    /// How far the pointer may move before the press counts as a drag.
    public static let dragSlop: CGFloat = 4

    private var pressID = 0
    private var pending: (id: Int, at: CGPoint)?

    public init() {}

    /// A middle press at `point`. Returns the id `fire(_:)` takes; a new press
    /// replaces one whose release was missed.
    public mutating func down(at point: CGPoint) -> Int {
        pressID += 1
        pending = (pressID, point)
        return pressID
    }

    public mutating func dragged(to point: CGPoint) {
        guard let pending else { return }
        let dx = point.x - pending.at.x, dy = point.y - pending.at.y
        if dx * dx + dy * dy > Self.dragSlop * Self.dragSlop {
            self.pending = nil
        }
    }

    public mutating func up() {
        pending = nil
    }

    /// True once, when press `id` is still held and still in place.
    public mutating func fire(_ id: Int) -> Bool {
        guard pending?.id == id else { return false }
        pending = nil
        return true
    }
}
