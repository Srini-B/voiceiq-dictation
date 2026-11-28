import UIKit
import XCTest

/// Words the typing model spells with capitals inside them (ChatGPT, iPhone) keep that
/// spelling at a sentence's start, where the keyboard's own capital would otherwise give
/// "Chatgpt" and "IPhone". Typed and swiped through the real keys, model and dictionary.
@MainActor
final class SpellingCaseTests: XCTestCase {
    func testSpellingsWithInnerCapitalsSurviveASentenceStart() throws {
        for (before, typed, want) in [
            ("", "chatgpt", "ChatGPT"), ("", "iphone", "iPhone"), ("", "hello", "Hello"),
            ("I said ", "chatgpt", "ChatGPT"), ("I said ", "iphone", "iPhone"), ("I said ", "hello", "hello"),
        ] {
            let field = Field(text: before)
            let keys = try engine(field)
            for letter in typed { tap(.character(String(letter)), keys) }
            tap(.space, keys)
            XCTAssertEqual(field.text, before + want + " ", "typed \(typed) after \"\(before)\"")
        }

        // A spelling that is only a capital ("Airbnb"), typed after the sentence's own capital,
        // is already right: space has nothing to replace.
        let airbnb = Field()
        let typing = try engine(airbnb)
        for letter in "airbnb" { tap(.character(String(letter)), typing) }
        XCTAssertFalse(typing.suggestions.contains { if case .primary(autoReplace: true) = $0.kind { true } else { false } },
                       "\(typing.suggestions.map(\.displayText))")
        tap(.space, typing)
        XCTAssertEqual(airbnb.text, "Airbnb ")

        for (word, want) in [("chatgpt", "ChatGPT"), ("iphone", "iPhone")] {
            XCTAssertEqual(try swiped(word, into: Field()), want, "swiped \(word)")
        }
    }

    /// Your own words: a word learned in lowercase ("chatgpt") still swipes as the model spells it,
    /// and a Contacts or Dictionary spelling of the same letters wins over the model's.
    func testYourOwnWordsAndTheModelsSpellings() throws {
        // Space never replaces a learned word, so this is the swipe.
        let learned = Field(text: "I said ")
        let keys = try engine(learned) { $0.learn("chatgpt") }
        XCTAssertEqual(try swiped("chatgpt", into: learned, keys: keys), "I said ChatGPT")

        // A contact, as UILexicon gives it (not the Dictionary, which space handles first).
        let contact = Field(text: "I said ")
        let typing = try engine(contact)
        typing.autocorrect.loadLexiconEntries([(userInput: "Fitzgerald", documentText: "Fitzgerald")])
        for letter in "fitzgerald" { tap(.character(String(letter)), typing) }
        tap(.space, typing)
        XCTAssertEqual(contact.text, "I said Fitzgerald ")
        let swipe = Field(text: "I said ")
        let swiping = try engine(swipe)
        swiping.autocorrect.loadLexiconEntries([(userInput: "Fitzgerald", documentText: "Fitzgerald")])
        XCTAssertEqual(try swiped("fitzgerald", into: swipe, keys: swiping), "I said Fitzgerald")
    }

    /// With Auto-capitalization off, Shift gives one capital and the model adds none.
    func testAutoCapitalizationOffAddsNoSpellingCapitals() throws {
        let field = Field(text: "I said ")
        let keys = try engine(field)
        keys.autoCapitalizes = false
        tap(.shift, keys)
        for letter in "iph" { tap(.character(String(letter)), keys) }
        let offered = keys.suggestions.map(\.displayText)
        XCTAssertTrue(offered.contains("Iphone"), "\(offered)")
        XCTAssertFalse(offered.contains("iPhone"), "\(offered)")

        let swipe = Field(text: "I said ")
        let swiping = try engine(swipe)
        swiping.autoCapitalizes = false
        tap(.shift, swiping)
        XCTAssertEqual(try swiped("iphone", into: swipe, keys: swiping), "I said Iphone")
    }

    private func swiped(_ word: String, into field: Field, keys given: FullKeyboardEngine? = nil) throws -> String {
        let keys = try given ?? engine(field)
        let plane = KeyboardKeyPlaneView(engine: keys)
        plane.swipe = SwipeTyping(engine: keys, model: try XCTUnwrap(keys.letterOdds))
        let points = swipePath(word, keys: keys.swipeKeys)
        plane.began(id: 50, sample: TypingLogTouchSample(point: points[0], timestamp: 0))
        for point in points.dropFirst() { plane.moved(id: 50, sample: TypingLogTouchSample(point: point, timestamp: 0)) }
        plane.ended(id: 50, sample: TypingLogTouchSample(point: points[points.count - 1], timestamp: 0))
        return field.text.trimmingCharacters(in: .whitespaces)
    }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    /// The engine with the English model attached as `FullKeyboardView.syncSpatialAutocorrect`
    /// attaches it with Spatial autocorrect on (the default).
    private func engine(_ field: Field, learned: (LearnedWordsStore) -> Void = { _ in }) throws -> FullKeyboardEngine {
        let suite = "spelling-case-\(UUID().uuidString)"
        suites.append(suite)
        let store = LearnedWordsStore(defaults: UserDefaults(suiteName: suite)!)
        learned(store)
        let keys = FullKeyboardEngine(target: field, autocorrect: AutocorrectEngine(learnedWords: store))
        keys.width = 393
        keys.language = .english
        let model = try XCTUnwrap(TypingDecoderModel.bundled("en"))
        keys.letterOdds = model
        keys.autocorrect.decoder = TypingDecoder(model: model)
        keys.configureForField()
        return keys
    }

    private func tap(_ kind: KeyKind, _ keys: FullKeyboardEngine) {
        var key = keys.layout.key(kind)
        if key == nil, case .character(let letter) = kind { key = keys.layout.key(.character(letter.uppercased())) }
        guard let frame = key?.frame else { return XCTFail("no key \(kind)") }
        let at = CGPoint(x: frame.midX, y: frame.midY)
        keys.touchBegan(id: 1, at: at)
        keys.touchEnded(id: 1, at: at)
    }

    /// Hex's SwipePath.through (ios/HEXMobileTests/SwipeDecoderTests.swift, MIT): straight
    /// lines between the word's key centres, a point every 6 pt.
    private func swipePath(_ word: String, keys: TypingDecoder.Keys) -> [CGPoint] {
        var centres: [CGPoint] = []
        for letter in word {
            guard let centre = keys.centres[letter] else { continue }
            if centres.last != centre { centres.append(centre) }
        }
        var points = Array(centres.prefix(1))
        for (a, b) in zip(centres, centres.dropFirst()) {
            let count = max(1, Int((hypot(b.x - a.x, b.y - a.y) / 6).rounded(.up)))
            for i in 1...count {
                let t = CGFloat(i) / CGFloat(count)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return points
    }
}

/// A text field that capitalises sentences, as most do.
@MainActor
private final class Field: KeyboardTextTarget {
    private(set) var text: String
    private var cursor: Int
    let keyboardAppearance: UIKeyboardAppearance? = nil
    var autocapitalizationType: UITextAutocapitalizationType? = .sentences
    var autocorrectionType: UITextAutocorrectionType? = .default
    var keyboardType: UIKeyboardType? = .default
    var returnKeyType: UIReturnKeyType? = .default
    var enablesReturnKeyAutomatically: Bool? = false
    var smartQuotesType: UITextSmartQuotesType?
    var smartDashesType: UITextSmartDashesType?
    var isSecureTextEntry: Bool?
    var textContentType: UITextContentType?
    var selectedText: String?
    var documentIdentifier: UUID?

    init(text: String = "") { self.text = text; cursor = text.count }
    var documentContextBeforeInput: String? { String(text.prefix(cursor)) }
    var documentContextAfterInput: String? { String(text.dropFirst(cursor)) }
    var hasText: Bool { !text.isEmpty }
    func insertText(_ string: String) {
        text.insert(contentsOf: string, at: text.index(text.startIndex, offsetBy: cursor))
        cursor += string.count
    }
    func deleteBackward() {
        guard cursor > 0 else { return }
        text.remove(at: text.index(text.startIndex, offsetBy: cursor - 1))
        cursor -= 1
    }
    func adjustTextPosition(byCharacterOffset offset: Int) { cursor = max(0, min(text.count, cursor + offset)) }
}
