import UIKit
import VoiceIQBridge
import XCTest

/// A text field as a keyboard sees it: text with a cursor or a selection.
private final class Field: NSObject, UITextDocumentProxy {
    private var characters: [Character]
    private var start: Int
    private var length: Int

    init(_ text: String = "", selecting word: String? = nil) {
        characters = Array(text)
        if let word, let range = text.range(of: word) {
            start = text.distance(from: text.startIndex, to: range.lowerBound)
            length = word.count
        } else {
            start = characters.count
            length = 0
        }
    }

    var text: String { String(characters) }
    var textContentType: UITextContentType!

    /// The user taps in the field, which collapses the selection.
    func tap(at offset: Int) { start = offset; length = 0 }

    var documentContextBeforeInput: String? { String(characters[..<start]) }
    var documentContextAfterInput: String? { String(characters[(start + length)...]) }
    var selectedText: String? { length > 0 ? String(characters[start..<(start + length)]) : nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier: UUID { UUID() }
    var hasText: Bool { !characters.isEmpty }

    func insertText(_ string: String) {
        characters.replaceSubrange(start..<(start + length), with: string)
        start += string.count
        length = 0
    }

    func deleteBackward() {
        if length > 0 {
            characters.removeSubrange(start..<(start + length))
        } else if start > 0 {
            characters.remove(at: start - 1)
            start -= 1
        }
        length = 0
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        start = min(max((offset < 0 ? start : start + length) + offset, 0), characters.count)
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

/// The keyboard as the user drives it: Hex's keys under VoiceiQ's typing
/// controller, touched where the keys are drawn, read back from the field.
@MainActor
final class KeyboardTypingTests: XCTestCase {
    private var field: Field!
    private var controller: FieldController!
    private var typing: TypingController!
    private var keyboard: FullKeyboardView!

    private func open(_ text: String = "", selecting word: String? = nil, width: CGFloat = 402) {
        // Words learned in earlier runs would change the suggestions.
        UserDefaults(suiteName: KeyboardBridge.appGroup)?.removeObject(forKey: LearnedWordsStore.defaultsKey)
        field = Field(text, selecting: word)
        controller = FieldController(field)
        typing = TypingController()
        typing.controller = controller
        keyboard = typing.makeKeyboard()
        keyboard.frame = CGRect(x: 0, y: 0, width: width, height: typing.keysHeight)
        keyboard.layoutIfNeeded()
        typing.appeared()
        keyboard.layoutIfNeeded()
    }

    private var plane: KeyboardKeyPlaneView { keyboard.plane }

    private func sample(_ point: CGPoint) -> TypingLogTouchSample {
        TypingLogTouchSample(point: point, timestamp: CACurrentMediaTime())
    }

    private func tap(_ kind: KeyKind, id: Int = 60) {
        let key = plane.engine.layout.key(kind)!
        let centre = CGPoint(x: key.frame.midX, y: key.frame.midY)
        plane.began(id: id, sample: sample(centre))
        plane.ended(id: id, sample: sample(centre))
    }

    private func type(_ text: String) {
        for character in text {
            tap(character == " " ? .space : .character(String(character).lowercased()))
        }
    }

    /// A finger drawn through the centres of `word`'s keys, a point every 6 pt.
    private func slide(_ word: String, id: Int = 50) {
        let centres = plane.engine.swipeKeys.centres
        var stops: [CGPoint] = []
        for letter in word {
            let centre = centres[letter]!
            if stops.last != centre { stops.append(centre) }
        }
        var points = [stops[0]]
        for (a, b) in zip(stops, stops.dropFirst()) {
            let count = max(1, Int((hypot(b.x - a.x, b.y - a.y) / 6).rounded(.up)))
            for i in 1...count {
                let t = CGFloat(i) / CGFloat(count)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        plane.began(id: id, sample: sample(points[0]))
        for point in points.dropFirst() { plane.moved(id: id, sample: sample(point)) }
        plane.ended(id: id, sample: sample(points[points.count - 1]))
    }

    func testTypedLettersReachTheFieldCapitalisedAtTheStart() {
        open()
        type("hello there")
        XCTAssertEqual(field.text, "Hello there")
        tap(.delete)
        XCTAssertEqual(field.text, "Hello ther")
    }

    func testSpaceCorrectsAMistypedWord() {
        open()
        type("i thibk ")
        XCTAssertEqual(field.text, "I think ")
    }

    func testASlidWordIsTyped() {
        open()
        slide("hello")
        XCTAssertEqual(field.text, "Hello")
        slide("world")
        XCTAssertEqual(field.text, "Hello world")
    }

    func testTheStripSuggestsAndAPickTypesIt() throws {
        open()
        type("we shoud")
        let words = plane.engine.suggestions.map(\.replacement)
        let pick = try XCTUnwrap(plane.engine.suggestions.first { $0.replacement == "should" }, "strip shows \(words)")
        plane.engine.acceptSuggestion(pick)
        XCTAssertTrue(field.text.hasPrefix("We should"), field.text)

        type(" go ")
        XCTAssertFalse(plane.engine.suggestions.isEmpty, "a next word after \"\(field.text)\"")
    }

    /// One row above the keys: VoiceiQ's buttons at the strip's ends, the
    /// suggestions between them, and no Hex key.
    func testTheStripHoldsVoiceiQsButtonsBesideTheSuggestions() {
        for (width, expected) in [(402.0, ["VoiceiQ", "Mini Keyboard", "Edit", "Dictate"]), (320.0, ["VoiceiQ", "Edit", "Dictate"])] {
            open(width: width)
            type("we shoud")
            XCTAssertNil(keyboard.hexKey.superview, "the Hex key is gone")
            let buttons = keyboard.subviews
                .filter { !$0.isHidden && $0.alpha > 0 && StripButton.allCases.map(\.label).contains($0.accessibilityLabel ?? "") }
                .sorted { $0.frame.minX < $1.frame.minX }
            XCTAssertEqual(buttons.map(\.accessibilityLabel), expected, "at \(width) pt")
            let slots = (keyboard.stripView.slotFrames ?? []).map { $0.offsetBy(dx: keyboard.stripView.frame.minX, dy: keyboard.stripView.frame.minY) }
            XCTAssertEqual(slots.count, 3)
            // Apple's bar height, the keys below it, and everything in it
            // centred with equal room above and below.
            let strip = keyboard.stripView.frame
            XCTAssertEqual(strip.minY, 0)
            XCTAssertEqual(strip.height, 44)
            XCTAssertGreaterThanOrEqual(plane.engine.layout.key(.character("q"))!.frame.minY, strip.maxY)
            XCTAssertEqual(keyboard.stripView.pillInset * 2 + plane.engine.layout.metrics.stripPillHeight, strip.height, accuracy: 0.01)
            for button in buttons {
                XCTAssertEqual(button.frame.minY, strip.minY, "\(button.accessibilityLabel!) top")
                XCTAssertEqual(button.frame.maxY, strip.maxY, "\(button.accessibilityLabel!) bottom")
                button.layoutIfNeeded()
                let glyph = button.subviews.first { $0 is UIImageView }!
                XCTAssertEqual(glyph.frame.midY, button.bounds.midY, accuracy: 0.5, "\(button.accessibilityLabel!) centred")
                for slot in slots { XCTAssertFalse(button.frame.intersects(slot), "\(button.accessibilityLabel!) over a suggestion at \(width) pt") }
            }
            for slot in slots { XCTAssertEqual(slot.minY, strip.minY); XCTAssertEqual(slot.maxY, strip.maxY) }
            // The suggestions share what is left equally, and still get a word.
            XCTAssertEqual(slots[0].width, slots[2].width, accuracy: 0.5)
            XCTAssertGreaterThan(slots[1].width, width < 360 ? 65 : 80)
            XCTAssertFalse(plane.engine.suggestions.isEmpty)
        }
    }

    func testTheEmojiSearchTakesTheLettersInsteadOfTheField() {
        open("hi ")
        typing.emojiQuery = ""
        type("pizza")
        XCTAssertEqual(typing.emojiQuery, "pizza")
        XCTAssertEqual(field.text, "hi ")
    }

    func testUndoTakesBackAWordAndRedoPutsItBack() {
        open()
        type("hello there")
        typing.undo()
        XCTAssertEqual(field.text, "Hello ")
        typing.redo()
        XCTAssertEqual(field.text, "Hello there")
    }

    /// iOS makes a new controller each time the keyboard appears; the old one
    /// and Hex's keys must go when it lets go of them.
    func testTheTypingControllerGoesWithItsKeyboard() {
        weak var released: TypingController?
        autoreleasepool {
            let typing = TypingController()
            _ = typing.makeKeyboard()
            released = typing
        }
        XCTAssertNil(released)
    }

    /// The bar shows "Add to Dictionary" while `selection` holds a word.
    /// iOS does not report the keyboard's own typing and deletes, so each
    /// one that ends the selection has to end it here too, or the offer stays.
    func testEveryWayOfEndingASelectionClearsIt() {
        let endings: [(String, (KeyboardTypingTests) -> Void)] = [
            ("typing a letter", { $0.tap(.character("x")) }),
            ("Delete", { $0.tap(.delete) }),
            ("space", { $0.tap(.space) }),
            ("return", { $0.tap(.returnKey) }),
            ("tapping elsewhere in the field", { $0.field.tap(at: 0); $0.typing.textChanged() }),
        ]
        for (name, end) in endings {
            open("call Srini tomorrow", selecting: "Srini")
            XCTAssertEqual(typing.selection, "Srini", name)

            end(self)

            XCTAssertNil(field.selectedText, name)
            XCTAssertEqual(typing.selection, "", "\(name) left the selection behind")
        }
    }

    /// A text replacement is one undo step: Undo brings the shortcut back.
    func testATextReplacementIsOneUndoStep() {
        open()
        typing.setSupplementaryLexicon([("omw", "On my way!")])
        type("omw ")
        XCTAssertEqual(field.text, "On my way! ")
        typing.undo()
        XCTAssertEqual(field.text, "Omw")
    }

    /// A one-time code field leaves autocorrection at its default, yet a
    /// text replacement must not expand in it.
    func testATextReplacementDoesNotExpandInAOneTimeCodeField() {
        open()
        field.textContentType = .oneTimeCode
        typing.setSupplementaryLexicon([("omw", "On my way!")])
        type("omw ")
        XCTAssertFalse(field.text.contains("On my way"), field.text)
    }

    /// A dictation typed by the model after the keys typed: Undo must not
    /// take back the keys' word from the dictation's characters.
    func testUndoAfterADictationLeavesTheDictationAlone() {
        open()
        type("abc")
        controller.textDocumentProxy.insertText(" Testing dictation.")
        typing.modelWroteToField()
        typing.undo()
        XCTAssertEqual(field.text, "Abc Testing dictation.")
    }

    /// A Backspace run right before a replacement stays its own undo step.
    func testABackspaceBeforeAReplacementIsItsOwnUndoStep() {
        open()
        typing.setSupplementaryLexicon([("omw", "On my way!")])
        type("so omwx")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        tap(.delete)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        type(" ")
        XCTAssertEqual(field.text, "So On my way! ")
        typing.undo()
        XCTAssertEqual(field.text, "So omw")
        typing.undo()
        XCTAssertEqual(field.text, "So omwx")
    }

    /// A cursor move between a delete and typing starts undo afresh: Undo
    /// never brings back text from before the move.
    func testACursorMoveAfterADeleteForgetsItsUndo() {
        open()
        type("ab")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        typing.deleteBackward()
        typing.adjustTextPosition(byCharacterOffset: -1)
        typing.insertText("x")
        XCTAssertEqual(field.text, "xA")
        typing.undo()
        XCTAssertEqual(field.text, "A")
    }

    /// Undo replays edits before the cursor, so moving the cursor ends them.
    func testMovingTheCursorForgetsUndo() {
        open()
        type("ab")
        typing.adjustTextPosition(byCharacterOffset: -1)
        XCTAssertTrue(typing.undoStack.isEmpty)
        typing.undo()
        XCTAssertEqual(field.text, "Ab")
    }

    /// The emoji key closes the emoji search and shows the emoji.
    func testTheEmojiKeyClosesTheSearch() {
        open()
        typing.startEmojiSearch()
        type("piz")
        plane.engine.onEmojiKey?()
        XCTAssertNil(typing.emojiQuery)
        XCTAssertTrue(typing.showsEmoji)
    }

    /// Reset Keyboard Learning applies once, stamped when applied, so words a
    /// keyboard loaded in between are dropped; later appearances keep words
    /// learned since.
    func testResetKeyboardLearningAppliesOnce() throws {
        let suite = "reset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = KeyboardPreferences()
        preferences.learningResetAt = Date().addingTimeInterval(-60)
        defaults.set(Data("old".utf8), forKey: LearnedWordsStore.defaultsKey)

        HexKeyboardSettings.apply(preferences, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: LearnedWordsStore.defaultsKey))
        XCTAssertGreaterThan(TypingJournalSettings(defaults: defaults).erasedAt, preferences.learningResetAt!.timeIntervalSince1970)

        defaults.set(Data("new".utf8), forKey: LearnedWordsStore.defaultsKey)
        HexKeyboardSettings.apply(preferences, defaults: defaults)
        XCTAssertNotNil(defaults.object(forKey: LearnedWordsStore.defaultsKey), "a later appearance erased new words")
    }
}
