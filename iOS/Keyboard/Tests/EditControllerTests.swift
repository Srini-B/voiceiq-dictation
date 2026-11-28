import UIKit
import XCTest

/// A text field as a keyboard sees it: text with a cursor or a selection,
/// and the keyboard's marked text, which the context includes, as UIKit's does.
final class Field: NSObject, UITextDocumentProxy {
    var text: [Character]
    private var start: Int
    private var length: Int
    /// Where the marked text is, in characters.
    private(set) var marked: Range<Int>?

    init(_ text: String, cursorAt offset: Int? = nil, selecting word: String? = nil) {
        self.text = Array(text)
        if let word, let range = text.range(of: word) {
            start = text.distance(from: text.startIndex, to: range.lowerBound)
            length = word.count
        } else {
            start = offset ?? text.count
            length = 0
        }
    }

    var string: String { String(text) }
    var cursor: Int { start }

    /// The user selects the last occurrence of `word`; the host commits marked text.
    func select(_ word: String) {
        guard let range = string.range(of: word, options: .backwards) else { return }
        start = string.distance(from: string.startIndex, to: range.lowerBound)
        length = word.count
        marked = nil
    }

    /// A host that leaves marked text out of the context until it is committed.
    var hidesMarkedText = false

    /// A host that shows only this many characters before the cursor.
    var window: Int?

    var documentContextBeforeInput: String? {
        let full = fullContextBefore
        guard let window else { return full }
        return String(full.suffix(window))
    }

    private var fullContextBefore: String {
        guard hidesMarkedText, let marked, marked.upperBound <= start else { return String(text[..<start]) }
        return String(text[..<marked.lowerBound]) + String(text[marked.upperBound..<start])
    }
    var documentContextAfterInput: String? { String(text[(start + length)...]) }
    var selectedText: String? { length > 0 ? String(text[start..<(start + length)]) : nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier: UUID { UUID() }
    var hasText: Bool { !text.isEmpty }

    func insertText(_ string: String) {
        let range = marked ?? start..<(start + length)
        text.replaceSubrange(range, with: string)
        start = range.lowerBound + string.count
        length = 0
        marked = nil
    }

    func deleteBackward() {
        marked = nil
        if length > 0 {
            text.removeSubrange(start..<(start + length))
        } else if start > 0 {
            text.remove(at: start - 1)
            start -= 1
        }
        length = 0
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        marked = nil
        start = min(max((offset < 0 ? start : start + length) + offset, 0), text.count)
        length = 0
    }

    /// The cursor goes to the end of the marked text: the keyboard always asks for that.
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {
        let range = marked ?? start..<(start + length)
        text.replaceSubrange(range, with: markedText)
        marked = markedText.isEmpty ? nil : range.lowerBound..<(range.lowerBound + markedText.count)
        start = range.lowerBound + markedText.count
        length = 0
    }

    func unmarkText() {
        marked = nil
    }
}

final class FieldController: UIInputViewController {
    let field: Field

    init(_ field: Field) {
        self.field = field
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var textDocumentProxy: UITextDocumentProxy { field }
}

@MainActor
final class EditControllerTests: XCTestCase {
    private var controller: FieldController!

    private func editor(for field: Field) -> EditController {
        controller = FieldController(field)
        let editor = EditController()
        editor.controller = controller
        editor.appeared()
        return editor
    }

    /// Undo takes back a whole dictation, then the deletes after it as one
    /// step, and redo puts them back in order.
    func testUndoAndRedoReplayDictationAndDeletes() {
        let field = Field("Dear Ana, ")
        let editor = editor(for: field)

        editor.type("see you at noon.")
        editor.deleteBackward()
        editor.deleteBackward()
        editor.deleteBackward()
        XCTAssertEqual(field.string, "Dear Ana, see you at no")

        editor.undo()
        XCTAssertEqual(field.string, "Dear Ana, see you at noon.")
        editor.undo()
        XCTAssertEqual(field.string, "Dear Ana, ")
        XCTAssertTrue(editor.undoStack.isEmpty)

        editor.redo()
        editor.redo()
        XCTAssertEqual(field.string, "Dear Ana, see you at no")
    }

    /// A draft swapped for its written text is one undo step, like a
    /// dictation typed in: undo leaves the field as it was before it.
    func testUndoTakesBackADraftDictation() throws {
        let field = Field("Dear Ana,")
        let editor = editor(for: field)
        let draft = try XCTUnwrap(KeyboardDraft.type("see you at noon", id: UUID(), documentID: UUID(), into: field,
                                                     fit: { text, _, _ in " " + text }))
        guard case .retyped(let fitted) = draft.replace(with: "See you at noon.", in: field,
                                                               fit: { text, _, _ in " " + text }) else {
            return XCTFail("not swapped")
        }
        editor.recordDictation(inserted: fitted)
        XCTAssertEqual(field.string, "Dear Ana, See you at noon.")
        editor.undo()
        XCTAssertEqual(field.string, "Dear Ana,")
    }

    /// Typing over a selection ends it, and undo brings the selected word back.
    func testTypingOverASelectionEndsItAndUndoRestoresTheWord() {
        let field = Field("call Srini tomorrow", selecting: "Srini")
        let editor = editor(for: field)
        XCTAssertEqual(editor.selection, "Srini")

        editor.type("\n", as: .typing)
        XCTAssertEqual(editor.selection, "")
        XCTAssertEqual(field.string, "call \n tomorrow")

        editor.undo()
        XCTAssertEqual(field.string, "call Srini tomorrow")
    }

    /// Word steps stop at the near edge of the next word; line steps stop at
    /// a line break.
    func testWordAndLineSteps() {
        let field = Field("one two\nthree four", cursorAt: 11)
        let editor = editor(for: field)

        editor.moveCursor(.lineStart)
        XCTAssertEqual(field.cursor, 8)
        editor.moveCursor(.wordLeft)
        XCTAssertEqual(field.cursor, 4, "the line break counts as space before \"two\"")
        editor.moveCursor(.wordRight)
        XCTAssertEqual(field.cursor, 7)
        editor.moveCursor(.right)
        editor.moveCursor(.lineEnd)
        XCTAssertEqual(field.cursor, 18)
    }

    /// When the app itself changes the text, the keyboard's undo would
    /// replay at the wrong place, so it is dropped.
    func testAnEditByTheAppDropsUndo() {
        let field = Field("Hi")
        let editor = editor(for: field)
        editor.type(" there")
        field.insertText("!")
        editor.textChanged()
        XCTAssertTrue(editor.undoStack.isEmpty)
    }

    /// Undo replays at the cursor, so moving it from the edit panel drops
    /// undo instead of deleting text at the new place.
    func testMovingTheCursorDropsUndo() {
        let field = Field("hello ")
        let editor = editor(for: field)
        editor.type("world")
        editor.moveCursor(.lineStart)
        editor.textChanged()
        editor.undo()
        XCTAssertEqual(field.string, "hello world")
    }

    /// Hex's auto-correction deletes the typed word and types the fix in one
    /// turn: undo takes back the fix alone, then the typing. Backspaces on a
    /// later turn are their own step.
    func testAutocorrectionFromTheKeysIsOneUndoStep() {
        let field = Field("I said ")
        let editor = editor(for: field)
        for letter in "teh" { editor.typeFromKeyboard(String(letter)) }
        for _ in 0..<3 { editor.deleteFromKeyboard() }
        editor.typeFromKeyboard("the")
        XCTAssertEqual(field.string, "I said the")

        editor.undo()
        XCTAssertEqual(field.string, "I said teh")
        editor.undo()
        XCTAssertEqual(field.string, "I said ")

        editor.redo()
        editor.redo()
        XCTAssertEqual(field.string, "I said the")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        editor.deleteFromKeyboard()
        editor.deleteFromKeyboard()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(field.string, "I said t")
        editor.undo()
        XCTAssertEqual(field.string, "I said the")
    }
}
