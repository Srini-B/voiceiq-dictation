import XCTest
import VoiceIQBridge

/// Each dictation swaps only its own draft. Earlier dictations' text and
/// anything the user typed stay as they are.
final class DraftLedgerTests: XCTestCase {
    private let a = UUID(), b = UUID()

    /// A field the way two dictations leave it: "Intro." then A's draft,
    /// then B's draft right after it, B spoken before A's writer finished.
    private func twoDrafts() -> DraftLedger {
        var ledger = DraftLedger(value: "Intro.")
        XCTAssertNotNil(ledger.add(a, text: " so um the build is green", at: 6, over: 0,
                                   landedIn: "Intro. so um the build is green"))
        XCTAssertNotNil(ledger.add(b, text: " and ship it", at: 31, over: 0,
                                   landedIn: "Intro. so um the build is green and ship it"))
        return ledger
    }

    /// Swaps `id` the way the app does: writes over exactly its range.
    private func swap(_ id: UUID, with written: String, in ledger: inout DraftLedger) {
        guard let span = ledger.draft(id), let new = span.replacing(in: ledger.value, with: written) else {
            return XCTFail("draft \(id) not found in \(ledger.value.debugDescription)")
        }
        ledger.replace(id, with: written, landedIn: new)
    }

    func testBackToBackDictationsEachSwapOnlyTheirOwnText() {
        var ledger = twoDrafts()
        swap(a, with: " The build is green.", in: &ledger)
        XCTAssertEqual(ledger.value, "Intro. The build is green. and ship it")
        XCTAssertEqual(ledger.draft(b), DraftSpan(location: 26, text: " and ship it"), "B moved by A's change")
        swap(b, with: " Ship it.", in: &ledger)
        XCTAssertEqual(ledger.value, "Intro. The build is green. Ship it.")
    }

    /// The later dictation's writer can finish first.
    func testTheLaterDictationCanSwapFirst() {
        var ledger = twoDrafts()
        swap(b, with: " Ship it.", in: &ledger)
        XCTAssertEqual(ledger.draft(a), DraftSpan(location: 6, text: " so um the build is green"), "A did not move")
        swap(a, with: " The build is green.", in: &ledger)
        XCTAssertEqual(ledger.value, "Intro. The build is green. Ship it.")
    }

    /// Two dictations of the same words are told apart by where each went,
    /// not by searching for the text.
    func testIdenticalDraftsKeepTheirOwnPlaces() {
        var ledger = DraftLedger(value: "")
        _ = ledger.add(a, text: "ok", at: 0, over: 0, landedIn: "ok")
        _ = ledger.add(b, text: " ok", at: 2, over: 0, landedIn: "ok ok")
        swap(b, with: " Okay.", in: &ledger)
        swap(a, with: "OK,", in: &ledger)
        XCTAssertEqual(ledger.value, "OK, Okay.")
    }

    /// A's written text ends with B's words: a diff of the field would slide
    /// B onto A's text. The swap moves B by exactly A's change.
    func testAWrittenTextEndingLikeTheNextDraftDoesNotCaptureIt() {
        var ledger = DraftLedger(value: "")
        _ = ledger.add(a, text: "Hello", at: 0, over: 0, landedIn: "Hello")
        _ = ledger.add(b, text: " there", at: 5, over: 0, landedIn: "Hello there")
        swap(a, with: "Hello there", in: &ledger)
        XCTAssertEqual(ledger.draft(b), DraftSpan(location: 11, text: " there"))
        swap(b, with: " friend.", in: &ledger)
        XCTAssertEqual(ledger.value, "Hello there friend.")
    }

    /// Typing between and before the drafts moves them; the typed text stays.
    func testTypingAroundDraftsMovesThemAndIsKept() {
        var ledger = twoDrafts()
        ledger.observe("Hi! Intro. so um the build is green and ship it")          // before A
        ledger.observe("Hi! Intro. so um the build is green, OK, and ship it")     // between A and B
        ledger.observe("Hi! Intro. so um the build is green, OK, and ship it :)")  // after B
        swap(b, with: " ship it.", in: &ledger)
        swap(a, with: " The build is green.", in: &ledger)
        XCTAssertEqual(ledger.value, "Hi! Intro. The build is green., OK, ship it. :)")
    }

    /// An edit inside A makes A the user's text; B still swaps.
    func testAnEditedDraftIsDroppedAndTheOtherStillSwaps() {
        var ledger = twoDrafts()
        ledger.observe("Intro. so um the build is red and ship it")
        XCTAssertNil(ledger.draft(a))
        swap(b, with: " Ship it.", in: &ledger)
        XCTAssertEqual(ledger.value, "Intro. so um the build is red Ship it.")
    }

    /// Deleting text that ends where a draft starts moves it; deleting into it drops it.
    func testDeletionsBeforeAndIntoADraft() {
        var ledger = twoDrafts()
        ledger.observe(" so um the build is green and ship it")  // "Intro." deleted
        XCTAssertEqual(ledger.draft(a)?.location, 0)
        ledger.observe(" so um the build is green and ship")     // into B
        XCTAssertNil(ledger.draft(b))
        XCTAssertNotNil(ledger.draft(a))
    }

    /// A change that is not exactly this dictation's insert records nothing.
    func testAddRejectsAChangeThatIsNotItsInsert() {
        var ledger = DraftLedger(value: "Hi")
        XCTAssertNil(ledger.add(a, text: " there", at: 2, over: 0, landedIn: "Hi there!"))
        XCTAssertEqual(ledger.value, "Hi there!")
        XCTAssertNil(ledger.draft(a))
        XCTAssertNotNil(ledger.add(b, text: "Hey", at: 0, over: 2, landedIn: "Hey there!"), "over a selection")
    }
}

final class DraftSpanTests: XCTestCase {
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
