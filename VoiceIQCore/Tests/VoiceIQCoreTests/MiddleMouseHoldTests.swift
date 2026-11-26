import CoreGraphics
import XCTest
@testable import VoiceIQCore

final class MiddleMouseHoldTests: XCTestCase {
    func testAPressHeldInPlaceFiresOnce() {
        var hold = MiddleMouseHold()
        let id = hold.down(at: CGPoint(x: 100, y: 100))
        hold.dragged(to: CGPoint(x: 102, y: 101)) // a hand's tremor, not a drag
        XCTAssertTrue(hold.fire(id))
        XCTAssertFalse(hold.fire(id), "one hold is one toggle")
    }

    func testAClickNeverFires() {
        var hold = MiddleMouseHold()
        let id = hold.down(at: .zero)
        hold.up()
        XCTAssertFalse(hold.fire(id), "a middle click (open in new tab) is the app's")
    }

    func testADraggedPressNeverFires() {
        var hold = MiddleMouseHold()
        let id = hold.down(at: .zero)
        hold.dragged(to: CGPoint(x: 0, y: 10))
        XCTAssertFalse(hold.fire(id), "panning and autoscroll are the app's")
    }

    func testANewPressReplacesOneWhoseReleaseWasMissed() {
        var hold = MiddleMouseHold()
        let first = hold.down(at: .zero)
        let second = hold.down(at: .zero)
        XCTAssertFalse(hold.fire(first))
        XCTAssertTrue(hold.fire(second))
    }
}
