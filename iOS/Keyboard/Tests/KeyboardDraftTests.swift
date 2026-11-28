import UIKit
import XCTest

/// The draft against `HostField`, where the field and the keyboard's view of
/// it are two texts. Every expectation is on the field (`string`).
@MainActor
final class KeyboardDraftTests: XCTestCase {
    private let typedAt = Date(timeIntervalSince1970: 1_000_000)

    /// A space before the text when it would run into the previous word, as
    /// `SurroundingText.fitted` adds.
    private let fit: KeyboardDraft.Fit = { text, before, _ in
        before.isEmpty || before.last?.isWhitespace == true ? text : " " + text
    }

    /// Types a draft and ends the turn, as the keyboard's poll does.
    private func type(_ transcript: String, into field: HostField) -> KeyboardDraft? {
        defer { field.endTurn() }
        return KeyboardDraft.type(transcript, id: UUID(), documentID: UUID(), into: field, fit: fit, now: typedAt)
    }

    /// Swaps in the written text of the draft's first dictation, or of
    /// `part`, and ends the turn.
    private func swap(_ draft: KeyboardDraft, part: Int = 0, for written: String,
                      in field: HostField) -> KeyboardDraft.Swap {
        defer { field.endTurn() }
        return draft.replace(draft.parts[part].id, with: written, in: field, fit: fit)
    }

    /// Adds a later dictation's transcript to the held draft and ends the turn.
    private func add(_ transcript: String, to draft: KeyboardDraft, in field: HostField) -> Bool {
        defer { field.endTurn() }
        return draft.add(transcript, id: UUID(), to: field, fit: fit, now: typedAt)
    }

    /// The transcript goes in marked and fitted; the written text takes its
    /// place, fitted the same way, and nothing stays marked.
    func testTheWrittenTextReplacesTheMarkedDraft() throws {
        let field = HostField("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        XCTAssertEqual(field.string, "Dear Ana, see you at noon")
        XCTAssertEqual(field.marked, " see you at noon")
        // The keyboard's view leaves the marked draft out.
        XCTAssertEqual(field.documentContextBeforeInput, "Dear Ana,")

        XCTAssertEqual(swap(draft, for: "See you at noon.", in: field), .replaced(" See you at noon."))
        XCTAssertEqual(field.string, "Dear Ana, See you at noon.")
        XCTAssertNil(field.marked)
        XCTAssertFalse(draft.isMarked)
    }

    /// The case that lost text in Messages: a dictation, typed text, then a
    /// second dictation. The second swap replaces its own draft and leaves
    /// the first dictation and the typed text as they are.
    func testASecondDictationLeavesEarlierTextAlone() throws {
        let field = HostField("")
        let first = try XCTUnwrap(type("the build is green", into: field))
        XCTAssertEqual(swap(first, for: "The build is green.", in: field), .replaced("The build is green."))
        field.insertText(" Noted")
        field.endTurn()
        XCTAssertEqual(field.string, "The build is green. Noted")

        let second = try XCTUnwrap(type("and i'll ship it tomorrow", into: field))
        XCTAssertEqual(field.string, "The build is green. Noted and i'll ship it tomorrow")
        XCTAssertEqual(swap(second, for: "And I'll ship it tomorrow.", in: field),
                       .replaced(" And I'll ship it tomorrow."))
        XCTAssertEqual(field.string, "The build is green. Noted And I'll ship it tomorrow.")
        XCTAssertNil(field.marked)
    }

    /// A dictation stopped while the one before it is still being written:
    /// its transcript joins the marked draft, after the first. Each written
    /// text takes its place as it comes, in either order, and the whole goes
    /// in once both have come. The earlier text stays as it was.
    func testADictationStoppedWhileTheOneBeforeIsWrittenJoinsItsDraft() throws {
        for secondWrittenFirst in [false, true] {
            let field = HostField("Earlier line.")
            let draft = try XCTUnwrap(type("the build is green", into: field))
            XCTAssertTrue(add("ship it today", to: draft, in: field))
            XCTAssertEqual(field.string, "Earlier line. the build is green ship it today")
            XCTAssertEqual(field.marked, " the build is green ship it today")
            XCTAssertEqual(draft.textBefore(field), "Earlier line. the build is green ship it today")

            if secondWrittenFirst {
                XCTAssertEqual(swap(draft, part: 1, for: "Ship it today.", in: field), .waiting)
                XCTAssertEqual(field.marked, " the build is green Ship it today.")
                XCTAssertEqual(swap(draft, part: 0, for: "The build is green.", in: field),
                               .replaced(" The build is green. Ship it today."))
            } else {
                XCTAssertEqual(swap(draft, part: 0, for: "The build is green.", in: field), .waiting)
                XCTAssertEqual(field.marked, " The build is green. ship it today")
                XCTAssertEqual(swap(draft, part: 1, for: "Ship it today.", in: field),
                               .replaced(" The build is green. Ship it today."))
            }
            XCTAssertEqual(field.string, "Earlier line. The build is green. Ship it today.")
            XCTAssertNil(field.marked)
        }
    }

    /// A draft the field changed around takes no later dictation: that one's
    /// written text comes alone, and the draft stays as it is.
    func testADraftTheFieldChangedAroundTakesNoLaterDictation() throws {
        let field = HostField("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.hostDid { $0.select("Ana") }
        XCTAssertFalse(add("bring the deck", to: draft, in: field))
        XCTAssertEqual(field.string, "Dear Ana, see you at noon")
        XCTAssertEqual(draft.parts.count, 1)
    }

    /// `HostField` is the host that lost that text. The swap as it was
    /// (`unmarkText`, then a Delete per character of the draft, then the
    /// insert, all in one turn) leaves only the written text in it, while the
    /// keyboard's view reads the whole expected text: 27 against 52
    /// characters, as measured.
    func testTheHostTakesAMarkedDraftWholeOnDeleteAndTheKeyboardCannotSeeIt() {
        let field = HostField("The build is green. Noted")
        let draft = " And I'll ship it tomorrow."
        field.setMarkedText(draft, selectedRange: NSRange(location: draft.utf16.count, length: 0))
        field.endTurn()

        field.unmarkText()
        for _ in 0..<draft.count { field.deleteBackward() }
        field.insertText(draft)
        field.endTurn()
        XCTAssertEqual(field.string, " And I'll ship it tomorrow.")
        XCTAssertEqual(field.documentContextBeforeInput, "The build is green. Noted And I'll ship it tomorrow.")
    }

    /// A key right after `unmarkText` reaches the host first and would
    /// replace the draft. So before the keyboard's own edit the draft is
    /// committed by an insert of its own text, and the key goes in after it.
    func testAKeyTypedWhileTheDraftIsMarkedGoesInAfterIt() throws {
        let field = HostField("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        draft.keep(field, .beforeEdit)
        field.insertText("!")
        field.endTurn()
        XCTAssertEqual(field.string, "Dear Ana, see you at noon!")
        XCTAssertNil(field.marked)

        // The same two calls with `unmarkText` lose the draft in this host.
        let lost = HostField("Dear Ana,")
        _ = try XCTUnwrap(type("see you at noon", into: lost))
        lost.unmarkText()
        lost.insertText("!")
        lost.endTurn()
        XCTAssertEqual(lost.string, "Dear Ana,!")
    }

    private var controller: FieldController?

    private func editor(for field: HostField) -> EditController {
        let controller = FieldController(field)
        self.controller = controller
        let editor = EditController()
        editor.controller = controller
        editor.appeared()
        return editor
    }

    /// Lets the main queue run once, which is the next run loop turn.
    private func nextTurn() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    /// A key pressed in the turn the poll marked a draft, or made one plain
    /// with `unmarkText`, would reach the host before that call: it would
    /// land before the new draft, which then went in a second time ("Dear
    /// Ana, see you at noon! see you at noon"), or replace the one made plain
    /// ("Dear Ana,!"). The key waits for the next turn instead.
    func testAKeyInTheTurnOfAMarkedTextCallGoesInOnTheNextTurn() async throws {
        let marked = HostField("Dear Ana,")
        var draft = KeyboardDraft.type("see you at noon", id: UUID(), documentID: UUID(), into: marked, fit: fit,
                                       now: typedAt)
        var markedThisTurn = true
        let first = editor(for: marked)
        first.markedTextThisTurn = { markedThisTurn }
        first.willEdit = {
            draft?.keep(marked, .beforeEdit)
            draft = nil
        }
        first.type("!")
        marked.endTurn()
        XCTAssertEqual(marked.string, "Dear Ana, see you at noon")
        markedThisTurn = false
        await nextTurn()
        marked.endTurn()
        XCTAssertEqual(marked.string, "Dear Ana, see you at noon!")
        XCTAssertNil(marked.marked)

        let plain = HostField("Dear Ana,")
        let held = try XCTUnwrap(type("see you at noon", into: plain))
        var unmarkedThisTurn = false
        let second = editor(for: plain)
        second.markedTextThisTurn = { unmarkedThisTurn }
        held.keep(plain, .alone)
        unmarkedThisTurn = true
        second.type("!?")
        second.deleteBackward()
        // The keys plan their next edit from the text as it will be.
        XCTAssertEqual(second.projected("Dear Ana, see you at noon"), "Dear Ana, see you at noon!")
        plain.endTurn()
        XCTAssertEqual(plain.string, "Dear Ana, see you at noon")
        unmarkedThisTurn = false
        await nextTurn()
        plain.endTurn()
        XCTAssertEqual(plain.string, "Dear Ana, see you at noon!")
    }

    /// Delete while the draft is marked takes one character, not the draft,
    /// and a cursor move leaves it whole.
    func testDeleteAndACursorMoveWhileTheDraftIsMarkedLeaveItsText() throws {
        let deleted = HostField("Dear Ana,")
        let first = try XCTUnwrap(type("see you at noon", into: deleted))
        first.keep(deleted, .beforeEdit)
        deleted.deleteBackward()
        deleted.endTurn()
        XCTAssertEqual(deleted.string, "Dear Ana, see you at noo")

        let moved = HostField("Dear Ana,")
        let second = try XCTUnwrap(type("see you at noon", into: moved))
        second.keep(moved, .beforeEdit)
        moved.adjustTextPosition(byCharacterOffset: -4)
        moved.endTurn()
        moved.insertText("12 ")
        moved.endTurn()
        XCTAssertEqual(moved.string, "Dear Ana, see you at 12 noon")
    }

    /// Autocorrect on the keys counts its Deletes from the text before the
    /// cursor, read before its first edit. With the draft in that text it
    /// corrects the draft's last word, and the word before the draft is not
    /// touched. The proxy alone answers "Lets meet tomorow".
    func testAnEditPlannedFromTheTextBeforeTheCursorStaysInsideTheDraft() throws {
        let field = HostField("Lets meet tomorow")
        let draft = try XCTUnwrap(type("see you thier", into: field))
        let read = draft.textBefore(field)
        XCTAssertEqual(read, "Lets meet tomorow see you thier")
        let word = read.split(separator: " ").last.map(String.init) ?? ""

        draft.keep(field, .beforeEdit)
        for _ in word { field.deleteBackward() }
        field.insertText("there ")
        field.endTurn()
        XCTAssertEqual(field.string, "Lets meet tomorow see you there ")
        XCTAssertNil(field.marked)
        XCTAssertEqual(draft.textBefore(field), "Lets meet tomorow see you there ")
    }

    /// The keyboard going away, or a dictation that ends with no written
    /// text, leaves the transcript as plain text; what is typed next goes in
    /// after it.
    func testADraftKeptAloneBecomesPlainText() throws {
        let field = HostField("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        draft.keep(field, .alone)
        field.endTurn()
        XCTAssertEqual(field.string, "Dear Ana, see you at noon")
        XCTAssertNil(field.marked)

        field.insertText("!")
        field.endTurn()
        XCTAssertEqual(field.string, "Dear Ana, see you at noon!")
        // Kept once: a written text that comes late changes nothing.
        XCTAssertEqual(swap(draft, for: "See you at noon.", in: field), .kept)
        XCTAssertEqual(field.string, "Dear Ana, see you at noon!")
    }

    /// A host that made the draft plain text without telling the keyboard
    /// gets the written text beside it. The draft's text is there twice; the
    /// text before it is whole.
    func testAHostThatCommittedTheDraftKeepsAllTextAndGetsTheWrittenTextBesideIt() throws {
        let field = HostField("The build is green. Noted")
        field.commitsMarkedText = true
        let draft = try XCTUnwrap(type("and i'll ship it tomorrow", into: field))
        XCTAssertNil(field.marked)

        XCTAssertEqual(swap(draft, for: "And I'll ship it tomorrow.", in: field),
                       .replaced(" And I'll ship it tomorrow."))
        XCTAssertEqual(field.string, "The build is green. Noted and i'll ship it tomorrow And I'll ship it tomorrow.")
    }

    /// The host reports its own text, with the marked draft in it, after a
    /// change on its side that left the draft where it was. The draft is
    /// still swapped.
    func testADraftTheHostReportsInItsTextIsStillSwapped() throws {
        let field = HostField("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.hostDid { _ in }
        XCTAssertEqual(field.documentContextBeforeInput, "Dear Ana, see you at noon")
        XCTAssertTrue(draft.isInPlace(field))

        XCTAssertEqual(swap(draft, for: "See you at noon.", in: field), .replaced(" See you at noon."))
        XCTAssertEqual(field.string, "Dear Ana, See you at noon.")
    }

    /// The user selected text while the writer ran: an insert would replace
    /// the selection, so the draft stays as heard and nothing is typed.
    func testASelectionMadeMeanwhileIsNeverReplaced() throws {
        let field = HostField("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.hostDid { $0.select("Ana") }
        XCTAssertFalse(draft.isInPlace(field))

        XCTAssertEqual(swap(draft, for: "See you at noon.", in: field), .kept)
        XCTAssertEqual(field.string, "Dear Ana, see you at noon")
        XCTAssertEqual(field.selectedText, "Ana")
    }

    /// Send took the message, draft and all: the written text is not typed
    /// into the empty field, also when the draft was all the field held.
    func testAMessageSentWithItsDraftGetsNoWrittenText() throws {
        let field = HostField("")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.hostDid { $0.send() }

        XCTAssertEqual(swap(draft, for: "See you at noon.", in: field), .kept)
        XCTAssertEqual(field.string, "")
    }

    /// A key typed after the field changed: the draft's text is not inserted
    /// a second time somewhere else.
    func testAnEditAfterTheFieldChangedDoesNotTypeTheDraftAgain() throws {
        let field = HostField("Dear Ana,")
        let draft = try XCTUnwrap(type("see you at noon", into: field))
        field.hostDid { $0.select("Dear") }
        draft.keep(field, .beforeEdit)
        field.insertText("Hi")
        field.endTurn()
        XCTAssertEqual(field.string, "Hi Ana, see you at noon")
    }

    /// The swap is one insert, so a draft of any script and length is typed
    /// and replaced whole: Tamil, whose vowel signs a host may delete on
    /// their own, an emoji of several code points, and 400 characters.
    func testADraftOfAnyScriptAndLengthIsReplacedWhole() throws {
        let field = HostField("Note:")
        let heard = "வணக்கம் நண்பரே 👨‍👩‍👧 " + String(repeating: "word ", count: 80) + "end"
        let draft = try XCTUnwrap(type(heard, into: field))
        XCTAssertEqual(field.string, "Note: " + heard)

        XCTAssertEqual(swap(draft, for: "வணக்கம், நண்பரே.", in: field), .replaced(" வணக்கம், நண்பரே."))
        XCTAssertEqual(field.string, "Note: வணக்கம், நண்பரே.")
    }

    /// No draft over a selection, which it would replace, and none with a
    /// line break. The written text then goes in alone, as before drafts.
    func testNoDraftOverASelectionOrWithALineBreak() {
        let field = HostField("call Srini tomorrow")
        field.hostDid { $0.select("Srini") }
        XCTAssertNil(type("see you", into: field))
        XCTAssertEqual(field.string, "call Srini tomorrow")

        let empty = HostField("")
        XCTAssertNil(type("first line\nsecond line", into: empty))
        XCTAssertEqual(empty.string, "")
        XCTAssertNil(empty.marked)
    }
}
