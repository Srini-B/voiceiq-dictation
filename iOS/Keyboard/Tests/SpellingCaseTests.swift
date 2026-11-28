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

        let field = Field()
        let keys = try engine(field)
        let plane = KeyboardKeyPlaneView(engine: keys)
        plane.swipe = SwipeTyping(engine: keys, model: try XCTUnwrap(keys.letterOdds))
        let points = swipePath("chatgpt", keys: keys.swipeKeys)
        plane.began(id: 50, sample: TypingLogTouchSample(point: points[0], timestamp: 0))
        for point in points.dropFirst() { plane.moved(id: 50, sample: TypingLogTouchSample(point: point, timestamp: 0)) }
        plane.ended(id: 50, sample: TypingLogTouchSample(point: points[points.count - 1], timestamp: 0))
        XCTAssertEqual(field.text.trimmingCharacters(in: .whitespaces), "ChatGPT", "swiped chatgpt")
    }

    /// The engine with the English model attached as `FullKeyboardView.syncSpatialAutocorrect`
    /// attaches it with Spatial autocorrect on (the default).
    private func engine(_ field: Field) throws -> FullKeyboardEngine {
        let defaults = UserDefaults(suiteName: "spelling-case-\(UUID().uuidString)")!
        let keys = FullKeyboardEngine(target: field, autocorrect: AutocorrectEngine(learnedWords: LearnedWordsStore(defaults: defaults)))
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
