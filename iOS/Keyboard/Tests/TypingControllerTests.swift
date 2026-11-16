import UIKit
import XCTest

/// A text field as a keyboard sees it: text with a cursor or a selection.
private final class Field: NSObject, UITextDocumentProxy {
    private var text: [Character]
    private var start: Int
    private var length: Int

    init(_ text: String, selecting word: String) {
        let range = text.range(of: word)!
        self.text = Array(text)
        start = text.distance(from: text.startIndex, to: range.lowerBound)
        length = word.count
    }

    /// The user taps in the field, which collapses the selection.
    func tap(at offset: Int) { start = offset; length = 0 }

    var documentContextBeforeInput: String? { String(text[..<start]) }
    var documentContextAfterInput: String? { String(text[(start + length)...]) }
    var selectedText: String? { length > 0 ? String(text[start..<(start + length)]) : nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier: UUID { UUID() }
    var hasText: Bool { !text.isEmpty }

    func insertText(_ string: String) {
        text.replaceSubrange(start..<(start + length), with: string)
        start += string.count
        length = 0
    }

    func deleteBackward() {
        if length > 0 {
            text.removeSubrange(start..<(start + length))
        } else if start > 0 {
            text.remove(at: start - 1)
            start -= 1
        }
        length = 0
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        start = min(max((offset < 0 ? start : start + length) + offset, 0), text.count)
        length = 0
    }

    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
}

private final class FieldController: UIInputViewController {
    let field: Field

    init(_ field: Field) {
        self.field = field
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var textDocumentProxy: UITextDocumentProxy { field }
}

@MainActor
final class TypingControllerTests: XCTestCase {
    /// The bar shows "Add to Dictionary" while `selection` holds a word.
    /// iOS does not report the keyboard's own typing and deletes, so each
    /// one that ends the selection has to end it here too, or the chip
    /// stays and predictions never come back.
    func testEveryWayOfEndingASelectionClearsIt() {
        let endings: [(String, (TypingController, Field) -> Void)] = [
            ("typing a letter", { typing, _ in typing.keyTapped(KeySpec(action: .insert("x"), label: "x"), text: nil) }),
            ("Delete", { typing, _ in typing.keyTapped(KeySpec(action: .delete, label: "delete"), text: nil) }),
            ("space", { typing, _ in typing.keyTapped(KeySpec(action: .space, label: "space"), text: nil) }),
            ("return", { typing, _ in typing.keyTapped(KeySpec(action: .returnKey, label: "return"), text: nil) }),
            ("tapping elsewhere in the field", { typing, field in field.tap(at: 0); typing.selectionChanged() }),
        ]
        for (name, end) in endings {
            let field = Field("call Srini tomorrow", selecting: "Srini")
            let controller = FieldController(field)
            let typing = TypingController()
            typing.controller = controller
            typing.appeared()
            XCTAssertEqual(typing.selection, "Srini", name)

            end(typing, field)

            XCTAssertNil(field.selectedText, name)
            XCTAssertEqual(typing.selection, "", "\(name) left the selection behind")
        }
    }
}
