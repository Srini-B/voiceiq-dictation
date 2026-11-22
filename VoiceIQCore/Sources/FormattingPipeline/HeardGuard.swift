import Foundation

/// Rejects a dictation's written text that answers the speaker or adds a
/// preamble instead of writing down what was said.
///
/// The dictation call answers `{"heard": ..., "text": ...}`: `heard` is what
/// the speaker said, word for word, and `text` is the written text. The rules
/// compare the two and stay conservative, because the writing rules
/// legitimately drop fillers and corrected words, reword, make lists, and
/// write numbers as digits. When one fires, `heard` is inserted instead.
///
/// Adapted from Hex's cleanup check (`src/dictation/apple_cleanup.rs`, MIT;
/// see THIRD_PARTY_NOTICES.md). Hex's number, negation and length checks are
/// left out: VoiceiQ's rules rewrite numbers and apply spoken corrections,
/// and a too-long answer is caught by the added-word rule.
public enum HeardGuard {
    /// The rule a rejected text broke. Logged; never shows the text.
    public enum Rule: String, Sendable {
        case replyOpener = "reply opener"
        case preamblePhrase = "preamble phrase"
        case preambleColon = "preamble colon"
        case newSpeaker = "new first- or second-person pronoun"
        case addedWords = "added words"
        case notTheSpeakersWords = "not the speaker's words"
        case droppedMostWords = "dropped most words"
    }

    /// The rule `text` breaks against `heard`, or nil when it may be inserted.
    public static func rejection(heard: String, text: String) -> Rule? {
        let said = words(heard)
        let written = words(text)
        guard !said.isEmpty, !written.isEmpty else { return nil }
        let saidSet = Set(said)
        let writtenSet = Set(written)

        // "Sure, …" or "Yes, …" the speaker did not start with. A leading
        // "hear" written as "here" is a homophone fix, not a reply.
        if let reply = opener(written),
           reply != opener(said.filter { !fillers.contains($0) }),
           !(reply == "here" && said.first == "hear") {
            return .replyOpener
        }
        // "Here's the cleaned text" the speaker never said.
        if preambles.contains(where: { contains(written, $0) && !contains(said, $0) }) {
            return .preamblePhrase
        }
        // A colon in the first clause ("Cleaned version: …", "Answer: …"),
        // led in by words the speaker never said. A list's own lead-in ("A
        // few things for tomorrow:") is the speaker's words and passes, and
        // so does a time such as 3:30.
        let clause = firstClause(text)
        if hasRealColon(clause), !hasRealColon(heard), !saidSet.contains("colon"),
           let colon = clause.firstIndex(where: { $0 == ":" || $0 == "：" }),
           words(String(clause[..<colon])).contains(where: { !hasDigit($0) && !saidSet.contains($0) }) {
            return .preambleColon
        }
        // An answer brings its own speaker ("I can help with that"). Pronouns
        // are counted per person, so "us" reworded as "our" passes.
        if people.contains(where: { group in
            written.count(where: { group.contains($0) }) > said.count(where: { group.contains($0) })
        }) {
            return .newSpeaker
        }
        // New words beyond a quarter of what was said (at least two), unless
        // each replaces a word that was dropped (a misheard word, a reworded
        // phrase, a number written as digits).
        let added = written.count(where: { !saidSet.contains($0) })
        let dropped = said.count(where: { !writtenSet.contains($0) })
        if added > max(2, said.count / 4), added > dropped {
            return .addedWords
        }
        // Mostly words the speaker never said, such as "Paris" for a
        // dictated question. Digits are left out: numbers are rewritten.
        var remaining = said.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var sharedWords = 0
        var sharedNumbers = 0
        for word in written where remaining[word, default: 0] > 0 {
            remaining[word, default: 0] -= 1
            if hasDigit(word) { sharedNumbers += 1 } else { sharedWords += 1 }
        }
        let writtenWords = written.count(where: { !hasDigit($0) })
        if writtenWords > 0, sharedWords * 2 < writtenWords {
            return .notTheSpeakersWords
        }
        // Under half of what was said kept, with no spoken correction to
        // explain it. Number words written as digits are not counted as
        // dropped: "five five five one two" is one token, "55512".
        let writesDigits = written.contains(where: hasDigit)
        let content = said.filter {
            !fillers.contains($0) && !(writesDigits && numberWords.contains($0) && !writtenSet.contains($0))
        }
        let kept = sharedWords + sharedNumbers + written.count(where: { hasDigit($0) && !saidSet.contains($0) })
        if content.count > 6 || written.count > 3, kept * 2 < content.count,
           !corrections.contains(where: { contains(said, $0) }) {
            return .droppedMostWords
        }
        return nil
    }

    /// What is inserted when the text is rejected: `heard` without its
    /// hesitation sounds. The Dictionary's replacements still apply after.
    public static func withoutFillers(_ heard: String) -> String {
        var text = heard.replacingOccurrences(
            of: #"(?:,\s*)?\b(?:um+|uh+|uhm|erm|hmm+|mm+)\b,?"#, with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        if let first = text.first, first.isLowercase, heard.first(where: \.isLetter)?.isUppercase == true {
            text = first.uppercased() + text.dropFirst()
        }
        return text
    }

    // MARK: - Words

    /// Lowercased words of letters and digits, apostrophes kept inside a
    /// word, pronoun contractions read as their two words so "I'm" and "I am"
    /// compare the same. Scripts written without spaces (Chinese, Japanese,
    /// Thai, …) count each character as a word, so punctuation added between
    /// them doesn't make the whole sentence a new word.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            while current.hasSuffix("'") { current.removeLast() }
            if !current.isEmpty { result += contractions[current] ?? [current] }
            current = ""
        }
        for character in text.lowercased() {
            if isUnspaced(character) {
                flush()
                result.append(String(character))
            } else if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "\u{2019}" {
                if !current.isEmpty { current.append("'") }
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    private static let unspacedScripts: [ClosedRange<UInt32>] = [
        0x0E00...0x0EFF, // Thai, Lao
        0x1000...0x109F, // Myanmar
        0x1780...0x17FF, // Khmer
        0x3040...0x30FF, // Hiragana, Katakana
        0x3400...0x4DBF, // CJK Extension A
        0x4E00...0x9FFF, // CJK Unified Ideographs
        0xF900...0xFAFF, // CJK Compatibility Ideographs
        0xFF66...0xFF9F, // Halfwidth Katakana
        0x20000...0x3134F, // CJK Extensions B–G
    ]

    private static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return unspacedScripts.contains { $0.contains(scalar) }
    }

    private static let contractions: [String: [String]] = [
        "i'm": ["i", "am"], "i've": ["i", "have"], "i'll": ["i", "will"], "i'd": ["i", "would"],
        "you're": ["you", "are"], "you've": ["you", "have"], "you'll": ["you", "will"], "you'd": ["you", "would"],
        "we're": ["we", "are"], "we've": ["we", "have"], "we'll": ["we", "will"], "we'd": ["we", "would"],
        "let's": ["let", "us"],
    ]

    private static let people: [Set<String>] = [
        ["i", "me", "my", "mine", "myself"],
        ["we", "us", "our", "ours", "ourselves"],
        ["you", "your", "yours", "yourself", "yourselves"],
    ]

    private static let openers: Set<String> = [
        "yes", "yeah", "yep", "no", "nope", "sure", "okay", "ok", "certainly", "absolutely", "here", "here's", "sorry",
    ]

    /// Sounds a dictation may start with before its first real word.
    private static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm", "oh", "so", "well", "like",
    ]

    private static let preambles: [[String]] = [
        ["here's", "the"], ["here", "is", "the"], ["here's", "your"], ["here", "is", "your"],
        ["cleaned", "transcript"], ["cleaned", "text"],
    ]

    /// Spoken self-corrections, which may leave less than half the words.
    private static let corrections: [[String]] = [
        ["no", "wait"], ["wait"], ["i", "mean"], ["i", "meant"], ["actually"], ["scratch", "that"], ["sorry"],
        ["rather"], ["never", "mind"], ["forget", "that"], ["delete", "that"], ["start", "over"],
        ["changed", "my", "mind"], ["second", "thought"], ["make", "that"],
    ]

    private static func opener(_ words: [String]) -> String? {
        guard let first = words.first else { return nil }
        if first == "of", words.count > 1, words[1] == "course" { return "of course" }
        guard openers.contains(first) else { return nil }
        return first == "ok" ? "okay" : first
    }

    private static func contains(_ words: [String], _ phrase: [String]) -> Bool {
        guard words.count >= phrase.count else { return false }
        return (0...(words.count - phrase.count)).contains { words[$0..<($0 + phrase.count)].elementsEqual(phrase) }
    }

    static let numberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "point", "double", "triple",
    ]

    private static func hasDigit(_ word: String) -> Bool { word.contains(where: \.isNumber) }

    /// A colon that is not between two digits, as in 3:30.
    private static func hasRealColon(_ text: String) -> Bool {
        let characters = Array(text)
        return characters.indices.contains { index in
            guard characters[index] == ":" || characters[index] == "：" else { return false }
            let isTime = index > 0 && index + 1 < characters.count
                && characters[index - 1].isNumber && characters[index + 1].isNumber
            return !isTime
        }
    }

    /// The text up to its first sentence end or line break.
    private static func firstClause(_ text: String) -> String {
        let end = text.firstIndex(where: { ".!?;\n。！？；".contains($0) }) ?? text.endIndex
        return String(text[..<end])
    }
}
