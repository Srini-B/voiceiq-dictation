import Foundation

/// The text around the cursor of the field a dictation is inserted into.
/// Selected text is in neither half: the insert replaces it.
public struct SurroundingText: Equatable, Sendable {
    public var before: String
    public var after: String

    public init(before: String, after: String) {
        self.before = before
        self.after = after
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

    /// Only the space before the result, when it would otherwise run into the
    /// previous word ("button.Please").
    public func spaced(_ text: String) -> String {
        Self.needsSpace(after: before, and: text.first) ? " " + text : text
    }

    /// `spaced`, plus: a capital first letter at the start of a sentence,
    /// punctuation the field already has dropped from the front of the
    /// result, and a space after it when the text after the cursor would
    /// otherwise run into it. Whether a result continues the sentence before
    /// it is left to the writing model, which can tell a name from an
    /// ordinary word.
    public func fitted(_ text: String) -> String {
        var text = text
        let lastMark = before.last { !$0.isWhitespace }
        // A result written to follow unpunctuated text (". Next") can be
        // pasted again later at the start of a sentence.
        if startsSentence || lastMark.map(Self.joiners.contains) == true,
           let first = text.first, Self.joiners.contains(first) || Self.terminators.contains(first) {
            text = String(text.drop { Self.joiners.contains($0) || Self.terminators.contains($0) || $0.isWhitespace })
        }
        if startsSentence { text = Self.capitalizingFirstWord(text) }
        guard !text.isEmpty else { return text }
        text = spaced(text)
        if Self.needsSpace(after: before + text, and: after.first) { text += " " }
        return text
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
