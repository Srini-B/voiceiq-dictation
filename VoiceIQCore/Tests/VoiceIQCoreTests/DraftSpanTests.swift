import XCTest
import VoiceIQBridge

final class DraftSpanTests: XCTestCase {
    private let draft = DraftSpan(location: 6, text: " see you at 3")

    func testFoundAtItsPlace() {
        XCTAssertEqual(draft.located(in: "Hello, see you at 3 and more"), draft)
    }

    /// The user typed before the draft: it moved, and is still unique.
    func testFollowsTypingBeforeIt() {
        let span = DraftSpan(location: 5, text: " see you at 3")
        XCTAssertEqual(span.located(in: "Hey! Hello see you at 3"), DraftSpan(location: 10, text: " see you at 3"))
    }

    /// One edited word inside the draft makes it the user's text.
    func testAnEditedDraftIsNotFound() {
        let span = DraftSpan(location: 5, text: " see you at 3")
        XCTAssertNil(span.located(in: "Hello see you at 4"))
        XCTAssertNil(span.located(in: "Hello"))
    }

    /// Two copies away from its place: which one is the draft can't be told.
    func testTwoCopiesAwayFromItsPlaceAreLeftAlone() {
        let span = DraftSpan(location: 0, text: "ok")
        XCTAssertNil(span.located(in: "Ook ok"))
        XCTAssertEqual(span.located(in: "ok ok"), span, "its own place still wins")
    }

    func testReplacingCountsUTF16() {
        let span = DraftSpan(location: 3, text: "hi")
        XCTAssertEqual(span.replacing(in: "😀 hi there", with: "Hello"), "😀 Hello there")
        XCTAssertNil(span.replacing(in: "😀 ho there", with: "Hello"))
    }

    func testSelectionMovesWithTheText() {
        let span = DraftSpan(location: 4, text: "abc")  // 4..<7, becomes 5 long
        XCTAssertEqual(span.selection((2, 1), afterReplacingWith: 5).location, 2, "before stays")
        XCTAssertEqual(span.selection((4, 0), afterReplacingWith: 5).location, 4, "at its start stays")
        XCTAssertEqual(span.selection((7, 0), afterReplacingWith: 5).location, 9, "at its end follows the new end")
        XCTAssertEqual(span.selection((10, 2), afterReplacingWith: 5).location, 12, "after shifts")
        let inside = span.selection((5, 1), afterReplacingWith: 5)
        XCTAssertEqual(inside.location, 9); XCTAssertEqual(inside.length, 0)
    }

    /// The written text is fitted against the field without the draft, so
    /// the draft's own leading space is not doubled.
    func testSurroundingLeavesTheDraftOut() {
        let span = DraftSpan(location: 5, text: " see you")
        let around = span.surrounding(in: "Hello see you. Bye")
        XCTAssertEqual(around?.before, "Hello")
        XCTAssertEqual(around?.after, ". Bye")
    }
}
