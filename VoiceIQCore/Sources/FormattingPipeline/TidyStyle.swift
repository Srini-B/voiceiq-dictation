// Adapted from Hex (github.com/anomalyco/hex, src/dictation/style.rs and style/notes.rs at
// 012bdbbe). MIT licence, Copyright (c) 2026 Christopher Langton; see THIRD_PARTY_NOTICES.md.
import Foundation

/// How an on-device dictation is tidied when Writing rules and notes is
/// Off: punctuation, capitals and word lists only, with no model, so the
/// words never leave the device and nothing waits on a network.
public enum TidyStyle: String, CaseIterable, Sendable, Identifiable {
    /// Full sentences: hesitations dropped, each sentence capitalized and
    /// ended, English "gonna" and "wanna" written out.
    case sentences
    /// Like a text message: lowercase starts, English "i", no comma after an
    /// opening "yeah", no final full stop on a short message.
    case messages
    /// Short lines, and a bulleted list when several things are said.
    case lists
    /// The model's words as heard: only extra spaces go.
    case asSpoken

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sentences: return "Sentences"
        case .messages: return "Messages"
        case .lists: return "Lists"
        case .asSpoken: return "As spoken"
        }
    }

    public var summary: String {
        switch self {
        case .sentences: return "Full sentences, with um and uh dropped."
        case .messages: return "Like a text message: lowercase, no final full stop."
        case .lists: return "Short lines, and a bulleted list when you say several things."
        case .asSpoken: return "The words exactly as transcribed."
        }
    }
}

/// The writing-Off path for an on-device dictation. `spoken` runs first, on
/// the transcript as heard; the Dictionary's replacements come next; then
/// `styled` writes the result in the chosen style. `language` is the
/// dictation's BCP 47 tag ("en-US"); the English-only rules ("I", "gonna",
/// opening "yeah", hesitations) need English, and other languages drop only
/// their own hesitation sounds.
public enum Tidy {
    /// Spoken layout and symbols ("new line", "comma") become the marks. In
    /// English, spoken email addresses join, hesitations go, a spoken
    /// self-correction keeps only the correction, and an unpunctuated
    /// question gets its mark. "As spoken" keeps every word.
    public static func spoken(_ text: String, style: TidyStyle, language: String?) -> String {
        guard style != .asSpoken else { return text }
        let english = isEnglish(language)
        let addressed = english ? SpokenAddresses.joining(in: text) : text
        // Symbols first: "open quote are you ready question mark close quote"
        // converts the mark inside the quotation it opens.
        // A spoken comma survives the line break after it ("Dear Sam comma new
        // paragraph"); a comma the model wrote before "new line" does not.
        let placeholder: Character = "\u{E000}"
        let symbols = SpokenMarks.symbols(in: addressed.replacingOccurrences(of: String(placeholder), with: ""),
                                          language: language, comma: placeholder)
        let marked = SpokenMarks.layout(in: symbols, language: language)
            .replacingOccurrences(of: String(placeholder), with: ",")
        guard english else { return marked }
        return SpokenRepairs.askingQuestions(SpokenRepairs.correcting(Hesitations.removing(from: marked)))
    }

    /// `text` in `style`. Trimmed first; an empty dictation stays empty.
    public static func styled(_ text: String, style: TidyStyle, language: String?) -> String {
        let trimmed = TidyText.trimmed(text)
        guard !trimmed.isEmpty else { return "" }
        let english = isEnglish(language)
        guard style != .asSpoken else { return TidyText.collapsingSpaces(trimmed) }
        let words = Hesitations.removingStandalone(from: trimmed, language: FillerLanguage(language))
        // Only hesitations ("Euh.") leave marks with no words: an empty dictation.
        // A mark dictated on its own ("question mark" → "?") stays.
        if !words.contains(where: TidyText.isWordCharacter), trimmed.contains(where: TidyText.isWordCharacter) { return "" }
        switch style {
        case .asSpoken: return words
        case .sentences: return sentences(words, english: english)
        case .messages: return message(words, english: english)
        case .lists: return notes(words, english: english)
        }
    }

    /// The primary language subtag, lowercase; nil while unknown.
    static func primaryLanguage(_ language: String?) -> String? {
        guard let language = language?.trimmingCharacters(in: .whitespaces), !language.isEmpty,
              language.lowercased() != "auto" else { return nil }
        let code = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        return code.isEmpty ? nil : code
    }

    static func isEnglish(_ language: String?) -> Bool { primaryLanguage(language) == "en" }

    // MARK: Sentences

    private static func sentences(_ text: String, english: Bool) -> String {
        guard !text.isEmpty else { return "" }
        var written = TidyText.tighteningPunctuation(TidyText.collapsingSpaces(text))
        if english { written = expandingInformalContractions(written) }
        written = TidyText.capitalizingSentenceStarts(written)
        if english { written = TidyText.recasingPronounI(written, from: "i", to: "I") }
        return written.split(separator: "\n", omittingEmptySubsequences: false)
            .map { TidyText.endingSentence(String($0)) }.joined(separator: "\n")
    }

    private static let informalContractions = [
        ("gonna", "going to"), ("wanna", "want to"), ("gotta", "got to"), ("kinda", "kind of"), ("lemme", "let me"),
    ]

    /// "I'm gonna call" → "I'm going to call". Never inside quotes, in an
    /// address ("gonna@gmail.com", "wanna.com"), or on a capitalized word
    /// mid-sentence, which is a name or a title.
    private static func expandingInformalContractions(_ text: String) -> String {
        let lowered = text.lowercased()
        guard informalContractions.contains(where: { lowered.contains($0.0) }) else { return text }
        var output = ""
        var word = ""
        var inStraightQuote = false
        var curlyQuotes = 0
        let chars = Array(text)
        let address = TidyText.addressMask(chars)
        var inAddress = false
        func flush() {
            let lower = word.lowercased()
            if let expansion = informalContractions.first(where: { $0.0 == lower })?.1, !inStraightQuote, curlyQuotes == 0,
               !inAddress {
                if word == lower {
                    output += expansion
                } else if word == TidyText.capitalizingFirst(lower), TidyText.startsSentenceOrItem(after: output) {
                    output += TidyText.capitalizingFirst(expansion)
                } else {
                    output += word
                }
            } else {
                output += word
            }
            word = ""
        }
        for (index, c) in chars.enumerated() {
            // "_" and "-" join an identifier: "server_gonna_value" and "server-gonna-value" are one word.
            if TidyText.isWordCharacter(c) || c == "'" || c == "’" || c == "_" || c == "-" {
                if word.isEmpty { inAddress = address[index] }
                word.append(c)
                continue
            }
            flush()
            switch c {
            case "\"": inStraightQuote.toggle()
            case "“": curlyQuotes += 1
            case "”": curlyQuotes = max(0, curlyQuotes - 1)
            default: break
            }
            output.append(c)
        }
        flush()
        return output
    }

    // MARK: Messages

    private static let interjections: Set<String> = [
        "yeah", "yes", "yep", "yup", "no", "nope", "nah", "ok", "okay", "oh", "hey", "hi", "hello",
        "so", "well", "sure", "alright", "cool", "thanks",
    ]

    private static func message(_ text: String, english: Bool) -> String {
        var message = TidyText.tighteningPunctuation(TidyText.collapsingSpaces(text))
        if english { message = droppingInterjectionCommas(message) }
        message = TidyText.lowercasingSentenceStarts(message)
        if english { message = TidyText.recasingPronounI(message, from: "I", to: "i") }
        // A short message drops its final full stop; a question or an exclamation keeps its mark.
        let chars = Array(message)
        let sentences = chars.indices.filter { TidyText.endsSentence(chars, at: $0) }.count
        // "Well..." keeps its ellipsis.
        // "U.S." and "p.m." keep their last full stop.
        if !message.contains("\n"), sentences <= 3, message.last == "." || message.last == "。", !message.hasSuffix(".."),
           !TidyText.endsWithInitialism(message) {
            message.removeLast()
        }
        return TidyText.trimmed(message)
    }

    /// "Yeah, sounds good. Ok, see you." → "Yeah sounds good. Ok see you."
    private static func droppingInterjectionCommas(_ text: String) -> String {
        var words = text.components(separatedBy: " ")
        var atStart = true
        for index in words.indices {
            let word = words[index]
            if atStart, word.hasSuffix(","), index + 1 < words.count, interjections.contains(String(word.dropLast()).lowercased()) {
                words[index].removeLast()
            }
            let chars = Array(word)
            atStart = word.contains("\n") || (!chars.isEmpty && TidyText.endsSentence(chars + [" "], at: chars.count - 1))
        }
        return words.joined(separator: " ")
    }

    // MARK: Lists

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "vs", "etc", "inc", "ltd", "approx", "e.g", "i.e",
    ]

    /// Words that open a spoken note but add nothing to a written one, longest first.
    private static let connectives = [
        "and then", "and also", "and", "also", "then", "plus", "so", "okay", "ok", "yeah", "oh", "well", "anyway",
        "alright", "basically", "first", "firstly", "second", "secondly", "third", "thirdly", "next", "finally", "lastly",
    ]

    /// Of those, the ones that may open a note without a comma after them.
    private static let bareConnectives: Set<String> = ["and then", "and also", "and", "also", "then", "plus"]

    private static func notes(_ text: String, english: Bool) -> String {
        guard !text.isEmpty else { return "" }
        let bareBullets = saysBareBullets(text)
        var working = ""
        // Quoted words are literal: Type "red bullet point blue".
        for (segment, quoted) in TidyText.quoteSegments(text) {
            // "bullet" is an English command; "Bullet Journal" in German is a name.
            working += quoted || !english ? segment : bulletLines(segment, bareBullets: bareBullets)
        }
        var lines = working.components(separatedBy: "\n")
        // Without spoken markers, one dictation of several things becomes a list.
        if lines.count == 1 {
            let line = TidyText.tighteningPunctuation(TidyText.collapsingSpaces(lines[0]))
            let sentences = noteSentences(line)
            if sentences.count >= 2 {
                lines = sentences.map { "- " + $0 }
            } else if let (intro, items) = colonList(line, english: english) {
                lines = ["\(intro):"] + items.map { "- " + $0 }
            }
        }
        let written = lines.map { raw -> String in
            let line = TidyText.collapsingSpaces(raw)
            guard line.hasPrefix("- ") else { return conciseNote(line, english: english) }
            let note = conciseNote(TidyText.trimmed(line.dropFirst(2)), english: english)
            return note.isEmpty ? "" : "- " + note
        }
        return TidyText.trimmed(written.joined(separator: "\n"))
    }

    /// One note: no opening "so," or "and then" (English), no final full
    /// stop, and a capital first letter.
    private static func conciseNote(_ line: String, english: Bool) -> String {
        var note = TidyText.tighteningPunctuation(line)
        if english { note = droppingConnectives(note) }
        if note.last == "." || note.last == "。", !note.hasSuffix("..."), !TidyText.endsWithInitialism(note) { note.removeLast() }
        return TidyText.capitalizingFirstLetter(TidyText.trimmed(note))
    }

    private static func droppingConnectives(_ line: String) -> String {
        var note = line
        var changed = true
        while changed {
            changed = false
            let lowered = note.lowercased()
            for connective in connectives where lowered.hasPrefix(connective) {
                let rest = note.dropFirst(connective.count)
                let next: Substring
                if rest.hasPrefix(", ") {
                    next = rest.dropFirst(2)
                } else if rest.hasPrefix(" "), bareConnectives.contains(connective) {
                    next = rest.dropFirst()
                } else {
                    continue
                }
                // Never the whole note, and never into a closing mark ("And?").
                guard let first = next.first, TidyText.isWordCharacter(first) else { continue }
                note = String(next)
                changed = true
                break
            }
        }
        return note
    }

    /// `line`'s sentences, each with its mark; one sentence or none returns `[line]`.
    private static func noteSentences(_ line: String) -> [String] {
        let chars = Array(line)
        // A mark inside a quotation ends nothing: The password is "red. blue".
        let quoted = TidyText.quoteMask(chars)
        var sentences: [String] = []
        var start = 0
        for index in chars.indices where !quoted[index] && TidyText.endsSentence(chars, at: index) {
            if chars[index] == "." {
                var wordStart = index
                while wordStart > start, !chars[wordStart - 1].isWhitespace { wordStart -= 1 }
                let word = String(chars[wordStart..<index]).lowercased()
                // "Dr.", an initial ("J. K.") or an initialism ("U.S.") ends nothing.
                let initials = word.split(separator: ".", omittingEmptySubsequences: false)
                    .allSatisfy { $0.count == 1 && $0.first?.isLetter == true }
                if abbreviations.contains(word) || initials { continue }
            }
            let sentence = TidyText.trimmed(String(chars[start...index]))
            if !sentence.isEmpty { sentences.append(sentence) }
            start = index + 1
        }
        let rest = TidyText.trimmed(String(chars[start...]))
        if !rest.isEmpty { sentences.append(rest) }
        return sentences.isEmpty ? [line] : sentences
    }

    /// Spoken "bullet point" and "next bullet" start list items, and so does
    /// a bare "bullet" in a dictation that opens with one and says it again.
    private static func bulletLines(_ text: String, bareBullets: Bool) -> String {
        // A standalone word only: never part of an address ("bullet@gmail.com"),
        // and never after an article ("a bullet point summary").
        var patterns = [#"(?:^|(?<!\b(?:a|an|the))\s+)(?:bullet point|next bullet)(?![\w@.-]*@)(?=[\s:,]|-\s|$)[:,-]?\s*"#]
        // "Bullet trains are fast" opens with the word, once.
        if bareBullets { patterns.append(#"(?:^|\s+)bullet(?![\w@.-]*@)(?=[\s:,]|-\s|$)[:,-]?\s*"#) }
        var working = text
        for pattern in patterns {
            working = working.replacingOccurrences(of: pattern, with: "\n- ", options: [.regularExpression, .caseInsensitive])
        }
        return working
    }

    private static func saysBareBullets(_ text: String) -> Bool {
        let opens = text.range(of: #"^\s*bullet\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let count = text.ranges(of: #/(?i)\bbullet\b(?! point)/#).count
        return opens && count >= 2
    }

    /// "Shopping list: eggs, milk and bread." → ("Shopping list", ["eggs",
    /// "milk", "bread"]): three or more short items (four words at most)
    /// after a colon. English splits the last "and" off too; a choice ("milk
    /// or bread") stays a sentence.

    private static func colonList(_ line: String, english: Bool) -> (String, [String])? {
        guard let colon = line.range(of: ": ") else { return nil }
        let intro = TidyText.trimmed(line[..<colon.lowerBound])
        var body = TidyText.trimmed(line[colon.upperBound...])
        // Quoted words are literal: Type: "eggs, milk, bread".
        guard !intro.isEmpty, !body.contains(": "), !body.contains(where: { "\"“”«»".contains($0) }) else { return nil }
        if body.last == "." || body.last == "。" { body.removeLast() }
        var items = body.components(separatedBy: ", ").map { TidyText.trimmed($0) }
        // "milk or bread", "milk, or bread": a choice, which a list would turn into two requests.
        if english, items.contains(where: { $0.lowercased().hasPrefix("or ") || $0.range(of: " or ") != nil }) { return nil }
        if english, var tail = items.popLast() {
            if tail.lowercased().hasPrefix("and ") { tail = String(tail.dropFirst(4)) }
            if let split = tail.range(of: " and ") {
                items.append(TidyText.trimmed(tail[..<split.lowerBound]))
                items.append(TidyText.trimmed(tail[split.upperBound...]))
            } else {
                items.append(tail)
            }
        }
        let short = items.allSatisfy { (1...4).contains($0.split(whereSeparator: \.isWhitespace).count) }
        let punctuated = items.contains { $0.contains(where: { ".!?。！？".contains($0) }) }
        return items.count >= 3 && short && !punctuated ? (intro, items) : nil
    }
}
