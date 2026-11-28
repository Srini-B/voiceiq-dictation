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

    /// The host deleted the draft and its space without this keyboard, after
    /// the draft was seen: what is before the cursor still ends like the
    /// draft's surroundings, and is still never deleted.
    func testADraftTheHostDeletedAfterItLandedLeavesTheSameWordsAlone() throws {
        let field = Field("ok ok ")
        let draft = try XCTUnwrap(type("ok", into: field))
        XCTAssertTrue(draft.follow(field))
        draft.commit(field)
        for _ in 0..<3 { field.deleteBackward() }
        XCTAssertEqual(field.string, "ok ok")

        XCTAssertFalse(draft.follow(field))
        XCTAssertEqual(draft.replace(with: "OK.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "ok ok")
    }

    /// The same deletion before the draft was ever seen, in a host that
    /// leaves marked text out of the context: the few characters still
    /// before the cursor are not enough to take an earlier copy for it.
    func testADraftDeletedBeforeItWasSeenLeavesTheSameWordsAlone() throws {
        let field = Field("ok ok ")
        field.hidesMarkedText = true
        let draft = try XCTUnwrap(type("ok", into: field))
        XCTAssertEqual(field.documentContextBeforeInput, "ok ok ")
        for _ in 0..<3 { field.deleteBackward() }
        XCTAssertEqual(field.string, "ok ok")

        XCTAssertEqual(draft.replace(with: "OK.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "ok ok")
    }

    /// Also with a long run of the same words before it, in a host that
    /// leaves marked text out of the context; an untouched draft there is
    /// still swapped.
    func testOnlyTheExactContextSwapsADraftTheHostShowedLate() throws {
        let repeated = String(repeating: "ok ", count: 8)
        let field = Field(repeated)
        field.hidesMarkedText = true
        let deleted = try XCTUnwrap(type("ok", into: field))
        for _ in 0..<3 { field.deleteBackward() }
        XCTAssertEqual(deleted.replace(with: "OK.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, String(repeating: "ok ", count: 7) + "ok")

        let untouched = Field("Dear Ana,")
        untouched.hidesMarkedText = true
        let draft = try XCTUnwrap(type("see you at noon", into: untouched))
        XCTAssertEqual(draft.replace(with: "See you at noon.", in: untouched, fit: fit), .retyped(" See you at noon."))
        XCTAssertEqual(untouched.string, "Dear Ana, See you at noon.")
    }

    /// The text before the cursor already ends like the draft, in a host
    /// that leaves marked text out: that text is not taken for the draft.
    /// Deleted, the draft leaves the user's words alone; untouched, it is
    /// swapped once committed.
    func testTextEndingLikeTheDraftIsNotTakenForIt() throws {
        let deletedField = Field("ok ok")
        deletedField.hidesMarkedText = true
        let deleted = try XCTUnwrap(type("ok", into: deletedField))
        XCTAssertEqual(deleted.text, " ok")
        for _ in 0..<3 { deletedField.deleteBackward() }
        XCTAssertEqual(deleted.replace(with: "OK.", in: deletedField, fit: fit), .kept)
        XCTAssertEqual(deletedField.string, "ok ok")

        let untouchedField = Field("ok ok")
        untouchedField.hidesMarkedText = true
        let untouched = try XCTUnwrap(type("ok", into: untouchedField))
        XCTAssertEqual(untouched.replace(with: "OK.", in: untouchedField, fit: fit), .retyped(" OK."))
        XCTAssertEqual(untouchedField.string, "ok ok OK.")
    }

    /// A host that shows only the last few characters before the cursor,
    /// with repeated words: deleting the draft leaves the same window, so
    /// a draft there is never swapped and the user's words stay.
    func testAShortWindowOverRepeatedWordsNeverSwaps() throws {
        let field = Field("ok ok ok ")
        field.window = 4
        let draft = try XCTUnwrap(type("ok", into: field))
        XCTAssertEqual(field.documentContextBeforeInput, "k ok")
        XCTAssertTrue(draft.follow(field))
        draft.commit(field)
        for _ in 0..<3 { field.deleteBackward() }
        XCTAssertEqual(field.string, "ok ok ok")
        XCTAssertEqual(field.documentContextBeforeInput, "k ok")

        XCTAssertTrue(draft.follow(field))
        XCTAssertEqual(draft.replace(with: "OK.", in: field, fit: fit), .kept)
        XCTAssertEqual(field.string, "ok ok ok")
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
