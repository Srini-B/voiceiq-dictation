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

        draft.fieldChanged(field, now: typedAt.addingTimeInterval(0.1))
        XCTAssertEqual(draft.replace(with: "See you at noon.", in: field, fit: fit), .replacedMarked(" See you at noon."))
        XCTAssertEqual(field.string, "Dear Ana, See you at noon.")
        XCTAssertNil(field.marked)
    }

    /// The host committed the draft when the user tapped the field, which
    /// left it right before the cursor: it is deleted and the written text
    /// typed, never typed beside it.
    func testAPlainDraftStillBeforeTheCursorIsRetyped() throws {
        let field = Field("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.unmarkText()
        draft.fieldChanged(field, now: typedAt.addingTimeInterval(2))

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
        draft.fieldChanged(field, now: typedAt.addingTimeInterval(2))

        XCTAssertEqual(draft.replace(with: "See you at noon.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "Dear Ana, see you at noon ok")
    }

    /// The cursor moved into the draft: it stays, and nothing is deleted.
    func testADraftNoLongerBeforeTheCursorIsLeftAlone() throws {
        let field = Field("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.adjustTextPosition(byCharacterOffset: -5)
        draft.fieldChanged(field, now: typedAt.addingTimeInterval(2))

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
        draft.fieldChanged(field, now: typedAt.addingTimeInterval(2))

        XCTAssertEqual(draft.replace(with: "OK.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "ok ok ok")
    }

    /// A committed Tamil draft is not retyped: Delete may take one code
    /// point at a time and leave pieces of it.
    func testADraftWithCombiningMarksIsNotRetyped() throws {
        let field = Field("")
        let draft = try XCTUnwrap(type("வணக்கம்", into: field))
        draft.commit(field)
        draft.fieldChanged(field, now: typedAt.addingTimeInterval(2))
        XCTAssertEqual(draft.replace(with: "வணக்கம்.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "வணக்கம்")
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

    /// The draft's own landing, reported late by the host, does not count as
    /// the user's change; a change after the grace does, and the swap then
    /// goes through the plain-text check.
    func testOnlyChangesAfterTheLandingCountAsTheUsers() throws {
        let field = Field("")
        let draft = try XCTUnwrap(type("hello", into: field))
        draft.fieldChanged(field, now: typedAt.addingTimeInterval(0.1))
        XCTAssertFalse(draft.touched)
        draft.fieldChanged(field, now: typedAt.addingTimeInterval(KeyboardDraft.landingGrace + 0.1))
        XCTAssertTrue(draft.touched)
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
