import UIKit
import XCTest

@MainActor
final class KeyboardDraftTests: XCTestCase {
    private let typedAt = Date(timeIntervalSince1970: 1_000_000)

    /// A space before the text when it would run into the previous word, as
    /// `SurroundingText.fitted` adds.
    private let fit: KeyboardDraft.Fit = { text, before, _ in
        before.isEmpty || before.last?.isWhitespace == true ? text : " " + text
    }

    private func type(_ transcript: String, into field: Field) -> KeyboardDraft? {
        KeyboardDraft.type(transcript, id: UUID(), documentID: UUID(), into: field, fit: fit, now: typedAt)
    }

    /// The transcript goes in marked and fitted; the written text takes its
    /// place, fitted the same way, and nothing stays marked.
    func testTheWrittenTextReplacesTheMarkedDraft() throws {
        let field = Field("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        XCTAssertEqual(field.string, "Dear Ana, see you at noon")
        XCTAssertNotNil(field.marked)

        XCTAssertEqual(draft.replace(with: "See you at noon.", in: field, fit: fit), .retyped(" See you at noon."))
        XCTAssertEqual(field.string, "Dear Ana, See you at noon.")
        XCTAssertNil(field.marked)
    }

    /// The host committed the draft without a word, right after it landed:
    /// the written text still replaces it and never goes in beside it.
    func testASilentHostCommitIsNotDuplicated() throws {
        let field = Field("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.unmarkText()

        XCTAssertEqual(draft.replace(with: "See you at noon.", in: field, fit: fit), .retyped(" See you at noon."))
        XCTAssertEqual(field.string, "Dear Ana, See you at noon.")
    }

    /// The host committed the draft when the user tapped the field, which
    /// left it right before the cursor: it is deleted and the written text
    /// typed, never typed beside it.
    func testAPlainDraftStillBeforeTheCursorIsRetyped() throws {
        let field = Field("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.unmarkText()

        XCTAssertEqual(draft.replace(with: "See you at noon.", in: field, fit: fit), .retyped(" See you at noon."))
        XCTAssertEqual(field.string, "Dear Ana, See you at noon.")
    }

    /// Once the user typed after the draft, it is no longer at the end of the
    /// text before the cursor: it stays as heard and their text is untouched.
    func testAnEditedDraftIsLeftAlone() throws {
        let field = Field("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        draft.commit(field)
        field.insertText(" ok")

        XCTAssertEqual(draft.replace(with: "See you at noon.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "Dear Ana, see you at noon ok")
    }

    /// The cursor moved into the draft: it stays, and nothing is deleted.
    func testADraftNoLongerBeforeTheCursorIsLeftAlone() throws {
        let field = Field("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.adjustTextPosition(byCharacterOffset: -5)

        XCTAssertEqual(draft.replace(with: "See you at noon.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "Dear Ana, see you at noon")
    }

    /// The cursor moved back to an earlier copy of the same words: that copy
    /// is the user's text and stays, and so does the draft.
    func testAnEarlierCopyOfTheSameWordsIsNeverTakenForTheDraft() throws {
        let field = Field("ok ok")
        let draft = try XCTUnwrap(type("ok", into: field))
        draft.commit(field)
        field.adjustTextPosition(byCharacterOffset: -3)

        XCTAssertEqual(draft.replace(with: "OK.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "ok ok ok")
    }

    /// The user deleted the draft and the space before it: the earlier copy
    /// now before the cursor is theirs, and is never deleted.
    func testADeletedDraftAfterTheSameWordsLeavesThemAlone() throws {
        let field = Field("ok ")
        let draft = try XCTUnwrap(type("ok", into: field))
        draft.commit(field)
        for _ in 0..<3 { field.deleteBackward() }
        XCTAssertEqual(field.string, "ok")

        XCTAssertEqual(draft.replace(with: "OK.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "ok")
    }

    /// A draft the swap could not take back out is never typed: Tamil,
    /// whose vowel signs a host may delete on their own, a line break, and
    /// a draft longer than hosts show before the cursor. The written text
    /// then goes in alone, as before drafts.
    func testADraftThatCouldNotBeSwappedIsNotTyped() {
        let field = Field("")
        XCTAssertNil(type("வணக்கம்", into: field))
        XCTAssertNil(type("first line\nsecond line", into: field))
        XCTAssertNil(type(String(repeating: "word ", count: 41), into: field))
        XCTAssertEqual(field.string, "")
        XCTAssertNil(field.marked)
        XCTAssertNotNil(type(String(repeating: "word ", count: 39), into: field))
    }

    /// A selection is the user's: the written text never replaces it.
    func testASelectionIsNeverReplaced() throws {
        let field = Field("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.select("noon")

        XCTAssertEqual(draft.replace(with: "See you at noon.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "Dear Ana, see you at noon")
        XCTAssertNil(type("see you", into: Field("call Srini tomorrow", selecting: "Srini")))
    }

    /// The keyboard going away leaves the transcript as plain text.
    func testCommitLeavesTheTranscript() throws {
        let field = Field("")
        let draft = try XCTUnwrap(type("hello", into: field))
        draft.commit(field)
        XCTAssertEqual(field.string, "hello")
        XCTAssertNil(field.marked)
        XCTAssertFalse(draft.isMarked)
    }
}
