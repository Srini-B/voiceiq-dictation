import Foundation

/// The text around the cursor of the field a dictation is inserted into.
/// Selected text is in neither half: the insert replaces it.
public struct SurroundingText: Codable, Equatable, Sendable {
    public var before: String
    public var after: String

    public init(before: String, after: String) {
        self.before = before
        self.after = after
    }

    /// What an iPhone keyboard reads around the cursor
    /// (`documentContextBeforeInput`, `documentContextAfterInput`). Hosts
    /// show a keyboard only part of the field, often the last sentence or
    /// so; the ends next to the cursor are exact, which is all the fitting
    /// reads. Nil when the field has text the host shows none of (a web
    /// view, a secure field): its text could need anything, so the text
    /// goes in as written.
    public init?(keyboardBefore before: String?, after: String?, fieldHasText: Bool) {
        let before = before ?? "", after = after ?? ""
        guard !(before.isEmpty && after.isEmpty && fieldHasText) else { return nil }
        self.init(before: before, after: after)
    }

    /// The part the writing model reads (`PromptV1.fieldContext`), and all
    /// a keyboard hands the app: the App Group keeps no more of the field.
    public var excerpt: SurroundingText {
        SurroundingText(before: String(before.suffix(300)), after: String(after.prefix(100)))
    }

    /// Splits a field's value at a UTF-16 selection, the unit Accessibility
    /// reports ranges in. Nil when the range does not fit the value.
    public init?(value: String, selectionLocation: Int, selectionLength: Int) {
        let utf16 = value.utf16
        guard selectionLocation >= 0, selectionLength >= 0,
              selectionLocation + selectionLength <= utf16.count,
              let start = utf16.index(utf16.startIndex, offsetBy: selectionLocation).samePosition(in: value),
              let end = utf16.index(utf16.startIndex, offsetBy: selectionLocation + selectionLength).samePosition(in: value)
        else { return nil }
        self.init(before: String(value[..<start]), after: String(value[end...]))
    }

    /// Whether either side holds anything but whitespace.
    public var hasText: Bool {
        before.contains { !$0.isWhitespace } || after.contains { !$0.isWhitespace }
    }

    /// The gap before the result (a space when it would otherwise run into
    /// the previous word, "button.Please", or a line break when its layout
    /// needs one, such as the next item of a list; `FieldLayout`), plus: a
    /// capital first letter at the start of a sentence,
    /// punctuation the field already has dropped from the front of the
    /// result, and the gap after it that the text after the cursor needs.
    /// Mid-sentence, a first word that is only an ordinary word ("And",
    /// "The", `midSentenceWords`) is lowercased, as the writing model is
    /// asked to; any other capital (a name, "I", "iPhone") stays.
    public func fitted(_ text: String) -> String {
        var text = text
        let lastMark = before.last { !$0.isWhitespace }
        // A result written to follow unpunctuated text (". Next") can be
        // pasted again later at the start of a sentence.
        if startsSentence || lastMark.map(Self.joiners.contains) == true,
           let first = text.first, Self.joiners.contains(first) || Self.terminators.contains(first) {
            text = String(text.drop { Self.joiners.contains($0) || Self.terminators.contains($0) || $0.isWhitespace })
        }
        guard !text.isEmpty else { return text }
        // The gap reads the writing model's casing: a capital it wrote can
        // start a new paragraph, one added here only starts a sentence.
        let gap = FieldLayout.leadingGap(before: before, text: text)
        if startsSentence {
            text = Self.capitalizingFirstWord(text)
        } else if before.contains(where: { !$0.isWhitespace }), !gap.contains(where: \.isNewline) {
            // On the same line only: after a heading, quote or table row
            // the layout starts a new line, and the model's capital stays.
            text = Self.lowercasingFirstWord(text)
        }
        text = gap + text
        return text + FieldLayout.trailingGap(before: before, text: text, after: after)
    }

    /// The field is empty before the cursor, or its last sentence is closed.
    var startsSentence: Bool {
        var trailing = before.reversed().drop { $0.isWhitespace && !$0.isNewline }
        if trailing.first?.isNewline == true { return true }
        trailing = trailing.drop { $0.isWhitespace || Self.closingQuotes.contains($0) }
        guard let last = trailing.first else { return true }
        return Self.terminators.contains(last)
    }

    static func needsSpace(after text: String, and next: Character?) -> Bool {
        guard let previous = text.last, let next else { return false }
        if previous.isWhitespace || isOpening(previous, after: text.dropLast().last) { return false }
        if next.isWhitespace || closers.contains(next) { return false }
        return !isSpaceless(previous) && !isSpaceless(next)
    }

    /// A straight quote opens when nothing or whitespace comes before it, and
    /// closes after a word: `said "stop."` ends a quotation.
    static func isOpening(_ character: Character, after previous: Character?) -> Bool {
        guard straightQuotes.contains(character) else { return openers.contains(character) }
        return previous.map { $0.isWhitespace || openers.contains($0) } ?? true
    }

    /// "hello there" → "Hello there". A word with a capital inside ("iPhone",
    /// "eBay") is a spelling, not a sentence start, and is left alone.
    static func capitalizingFirstWord(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        let word = text.prefix { $0.isLetter }
        guard !word.dropFirst().contains(where: \.isUppercase) else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// "And I'll" → "and I'll" after "Noted". Only a word from
    /// `midSentenceWords` written with one capital: a name, an acronym
    /// ("IT") or "I" is left as it is.
    static func lowercasingFirstWord(_ text: String) -> String {
        let word = text.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        // The whole word only: "A/B", "A4" and "In-N-Out" are spellings.
        let next = text.dropFirst(word.count).first
        guard let first = word.first, first.isUppercase, !word.dropFirst().contains(where: \.isUppercase),
              next.map({ $0.isWhitespace || ",.;:!?".contains($0) }) ?? true,
              midSentenceWords.contains(word.lowercased()) else { return text }
        return word.lowercased() + text.dropFirst(word.count)
    }

    /// Words that are never a name, so a capital on them mid-sentence is
    /// only a sentence start. Names that are also words ("Will", "May",
    /// "Grace") are left out.
    static let midSentenceWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "so", "yet", "then", "also", "because", "if", "when",
        "while", "though", "although", "unless", "until", "since", "as", "than", "that", "which", "who",
        "whom", "whose", "where", "what", "how", "why", "this", "these", "those", "it", "it's", "its", "we",
        "we'll", "we're", "they", "they'll", "they're", "he", "she", "you", "you'll", "you're", "me", "us",
        "them", "my", "our", "your", "their", "his", "her", "to", "of", "in", "on", "at", "for", "with",
        "from", "by", "about", "into", "after", "before", "is", "are", "was", "were", "be", "been", "has",
        "have", "had", "do", "does", "did", "can", "could", "would", "should", "might", "must", "not",
        "just", "maybe", "please", "plus", "there", "here", "too", "very", "still", "even", "only",
    ]

    static let terminators: Set<Character> = [".", "!", "?", "…"]
    static let joiners: Set<Character> = [",", ";", ":"]
    static let closingQuotes: Set<Character> = ["\"", "'", "”", "’", "»", "›", ")", "]", "}"]
    static let straightQuotes: Set<Character> = ["\"", "'"]
    static let openers: Set<Character> = ["(", "[", "{", "<", "“", "‘", "«", "‹", "¿", "¡", "/", "@", "#"]
    static let closers: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "…", "%", "”", "’", "»", "›"]

    /// Thai, and the Chinese and Japanese scripts and their punctuation, which
    /// put no spaces between words. Character sets follow Parrot's `Spacing`
    /// (humanitas-labs/parrot, MIT).
    static func isSpaceless(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0E00...0x0E7F, 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
