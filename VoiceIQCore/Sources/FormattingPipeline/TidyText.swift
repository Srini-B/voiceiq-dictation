// Adapted from Hex (github.com/anomalyco/hex, src/dictation/style/spacing.rs at 012bdbbe).
// MIT licence, Copyright (c) 2026 Christopher Langton; see THIRD_PARTY_NOTICES.md.
import Foundation

/// Spacing, punctuation and capitals shared by the tidy styles (`TidyStyle`).
/// Every rule works on characters, with no model.
enum TidyText {
    static func isSpace(_ c: Character) -> Bool { c.isWhitespace && c != "\n" }
    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// Which characters sit inside a quotation: "Type \"um\"" quotes a word,
    /// which is kept as said.
    static func quoteMask(_ chars: [Character]) -> [Bool] {
        var mask = Array(repeating: false, count: chars.count)
        var straight = false
        var curly = 0
        for (index, c) in chars.enumerated() {
            switch c {
            case "\"": straight.toggle()
            case "“", "«": curly += 1
            case "”", "»": curly = max(0, curly - 1)
            default: mask[index] = straight || curly > 0
            }
        }
        return mask
    }

    /// `text` cut into runs inside and outside quotation marks, the marks
    /// themselves counting as inside.
    static func quoteSegments(_ text: String) -> [(String, Bool)] {
        let chars = Array(text)
        let mask = quoteMask(chars)
        var segments: [(String, Bool)] = []
        for (index, c) in chars.enumerated() {
            let inside = mask[index] || "\"“”«»".contains(c)
            if let last = segments.last, last.1 == inside {
                segments[segments.count - 1].0.append(c)
            } else {
                segments.append((String(c), inside))
            }
        }
        return segments
    }

    /// Which characters belong to a written address or domain, a word with
    /// "@" or "." between letters ("john@underscore.com", "wanna.com"),
    /// whose parts are never read as spoken words.
    static func addressMask(_ chars: [Character]) -> [Bool] {
        var mask = Array(repeating: false, count: chars.count)
        var start = 0
        for index in 0...chars.count where index == chars.count || chars[index].isWhitespace {
            var joined = false
            for k in start..<index where chars[k] == "@" || chars[k] == "." {
                let between = k > start && k + 1 < index && isWordCharacter(chars[k - 1]) && isWordCharacter(chars[k + 1])
                if chars[k] == "@" || between { joined = true }
            }
            if joined { for k in start..<index { mask[k] = true } }
            start = index + 1
        }
        return mask
    }

    static func upper(_ c: Character) -> Character {
        let upper = String(c).uppercased()
        return upper.count == 1 ? Character(upper) : c
    }

    static func lower(_ c: Character) -> Character {
        let lower = String(c).lowercased()
        return lower.count == 1 ? Character(lower) : c
    }

    static func trimmed<S: StringProtocol>(_ text: S) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each line without runs of spaces or tabs, and without the spaces at its
    /// ends; the lines stay separate.
    static func collapsingSpaces(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var collapsed = ""
            var afterSpace = false
            for c in line {
                if c == " " || c == "\t" {
                    if !afterSpace { collapsed.append(" ") }
                    afterSpace = true
                } else {
                    collapsed.append(c)
                    afterSpace = false
                }
            }
            return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        return trimmed(lines.joined(separator: "\n"))
    }

    /// The text without whitespace before `, . ; : ! ?`, and without a
    /// leading run of `, ; :`. The space before an emoticon such as `:-)` stays.
    static func tighteningPunctuation(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var index = 0
        while index < chars.count {
            if isSpace(chars[index]) {
                var end = index
                while end < chars.count, isSpace(chars[end]) { end += 1 }
                // ".env", "./build.sh", ":wq" start a word of their own.
                // "../scripts", "!important" too.
                let startsWord = end + 1 < chars.count
                    && ((".:".contains(chars[end]) && (isWordCharacter(chars[end + 1]) || "/.".contains(chars[end + 1])))
                        || (chars[end] == "!" && chars[end + 1].isLetter))
                if end < chars.count, ",.;:!?".contains(chars[end]), !isEmoticon(chars, at: end), !startsWord {
                    index = end
                    continue
                }
                out += chars[index..<end]
                index = end
                continue
            }
            out.append(chars[index])
            index += 1
        }
        var start = 0
        if let first = out.first, ",;:".contains(first) {
            while start < out.count, ",;:".contains(out[start]) { start += 1 }
            while start < out.count, out[start].isWhitespace { start += 1 }
        }
        return trimmed(String(out[start...]))
    }

    private static func isEmoticon(_ chars: [Character], at index: Int) -> Bool {
        guard index + 1 < chars.count else { return false }
        switch chars[index + 1] {
        case "(", ")": return true
        case "-": return index + 2 < chars.count && "()".contains(chars[index + 2])
        default: return false
        }
    }

    /// `line` with a full stop unless it already ends a sentence (or a
    /// list's colon), is empty, or is a lone address ("john@gmail.com").
    static func endingSentence(_ line: String) -> String {
        guard let last = line.last else { return line }
        if #".!?…"”)]:,;。！？」』）।॥۔؟"#.contains(last) || (line.contains("@") && !line.contains(where: \.isWhitespace)) {
            return line
        }
        return line + (usesIdeographicFullStop(last) ? "。" : ".")
    }

    /// Marks that end a sentence. A full stop counts only before a space, a
    /// line break or the end ("gmail.com" and "e.g." end nothing); the
    /// ideographic ones count anywhere.
    static func endsSentence(_ chars: [Character], at index: Int) -> Bool {
        guard index < chars.count else { return false }
        let c = chars[index]
        if "。！？".contains(c) { return true }
        guard ".!?…".contains(c) else { return false }
        return index + 1 >= chars.count || chars[index + 1].isWhitespace
    }

    /// Chinese and Japanese end a sentence with "。", not ".".
    private static func usesIdeographicFullStop(_ c: Character) -> Bool {
        guard let value = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
            || (0x3040...0x30FF).contains(value) || (0xF900...0xFAFF).contains(value)
    }

    /// The first letter of `word` capitalized, the rest as given.
    static func capitalizingFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(upper(first)) + word.dropFirst()
    }

    private static func lowercasingFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(lower(first)) + word.dropFirst()
    }

    /// Whether the text after `before` starts a sentence: nothing (or only
    /// spaces), a line break, or `.` `!` `?` `…`, closing quotes or brackets
    /// after them included.
    private static func startsSentence(after before: String) -> Bool {
        for c in before.reversed() {
            if c == "\n" { return true }
            if c.isWhitespace || "\"”’')]»".contains(c) { continue }
            return ".!?…。".contains(c)
        }
        return true
    }

    /// Whether the next word starts a sentence or a bulleted item ("- ").
    static func startsSentenceOrItem(after text: String) -> Bool {
        if startsSentence(after: text) { return true }
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let marker = trimmed(line)
        return marker == "-" || marker == "•"
    }

    /// The English pronoun "i" (alone or in "i'm", "i'll", "i've", "i'd")
    /// written with `to`, never "i.e." or an address.
    static func recasingPronounI(_ text: String, from: Character, to: Character) -> String {
        guard text.contains(from) else { return text }
        let chars = Array(text)
        let address = addressMask(chars)
        // A quoted "i" is a literal letter: Type "i" into the field.
        let quoted = quoteMask(chars)
        var out = chars
        for index in chars.indices where chars[index] == from && !address[index] && !quoted[index] {
            // "grep -i", "arr[i]": code, not the pronoun.
            if index > 0, isWordCharacter(chars[index - 1]) || "@.'’_-[".contains(chars[index - 1]) { continue }
            var after = index + 1
            if after < chars.count, "'’".contains(chars[after]) {
                let suffix = String(chars[(after + 1)...].prefix(2))
                let length: Int
                if suffix.hasPrefix("m") || suffix.hasPrefix("d") {
                    length = 1
                } else if suffix.hasPrefix("ll") || suffix.hasPrefix("ve") {
                    length = 2
                } else {
                    continue
                }
                after += 1 + length
            }
            let endsWord: Bool
            if after >= chars.count {
                endsWord = true
            } else {
                let next = chars[after]
                endsWord = !(isWordCharacter(next) || "@'’_]".contains(next))
                    && !(next == "." && after + 1 < chars.count && chars[after + 1].isLetter)
            }
            // "i underscore max" spells an identifier.
            let next = chars[min(after, chars.count)...].drop(while: { $0 == " " }).prefix(while: \.isLetter)
            if endsWord, !["underscore", "hyphen", "slash", "dot"].contains(String(next).lowercased()) { out[index] = to }
        }
        return String(out)
    }

    /// Capitalizes the first letter of each sentence: at the start, after a
    /// line break, or after ".", "!" or "?" and a space. A full stop inside a
    /// word starts nothing, and an address keeps its case.
    static func capitalizingSentenceStarts(_ text: String) -> String {
        var chars = Array(text)
        // Quoted text keeps its case and ends no sentence: The password is "red. blue".
        let quoted = quoteMask(chars)
        var capitalizeNext = true
        var endedSentence = false
        for index in chars.indices {
            let c = chars[index]
            if quoted[index] {
                capitalizeNext = false
                endedSentence = false
                continue
            }
            if capitalizeNext && c.isLetter {
                // "iPhone", "eBay" keep the spelling a Dictionary rule gave them; a URL keeps its case.
                if !isAddress(chars, at: index) && !hasInnerCapital(chars, at: index) && !isURL(chars, at: index) {
                    chars[index] = upper(c)
                }
                capitalizeNext = false
            } else if c == "\n" {
                capitalizeNext = true
                endedSentence = false
            } else if ".!?".contains(c) {
                // "i.e." and "e.g." end no sentence.
                endedSentence = !(c == "." && endsAbbreviation(chars, at: index))
                capitalizeNext = false
            } else if c.isWhitespace {
                if endedSentence {
                    capitalizeNext = true
                    endedSentence = false
                }
            } else if "\"”’')]".contains(c) && endedSentence {
                continue
            } else if !"\"“(¿¡".contains(c) {
                capitalizeNext = false
                endedSentence = false
            }
        }
        return String(chars)
    }

    /// Whether the full stop at `index` ends "i.e.", "e.g." or "vs.".
    private static func endsAbbreviation(_ chars: [Character], at index: Int) -> Bool {
        var start = index
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        let word = String(chars[start...index]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\"“"))
        // "at 9 a.m. tomorrow", "Apple Inc. announced", "the U.S. yesterday": the model's case stays.
        return ["i.e.", "e.g.", "vs.", "cf.", "inc.", "ltd.", "co.", "corp.", "mr.", "mrs.", "ms.", "dr.", "jr.", "sr.",
                "st.", "no.", "approx."].contains(word)
            || endsWithInitialism(word)
    }

    private static func isURL(_ chars: [Character], at index: Int) -> Bool {
        chars[index...].prefix { !$0.isWhitespace }.map(String.init).joined().contains("://")
    }

    /// Whether `text` ends in an initialism such as "U.S." or "p.m.".
    static func endsWithInitialism(_ text: String) -> Bool {
        text.range(of: #"(?:^|[\s(])(?:\p{L}\.){2,}$"#, options: .regularExpression) != nil
    }

    /// Lowercases the first letter of each sentence, as people text. Keeps
    /// acronyms ("NASA", though "OK" becomes "ok"), words with capitals inside
    /// ("iPhone"), list items and addresses.
    static func lowercasingSentenceStarts(_ text: String) -> String {
        var chars = Array(text)
        let quoted = quoteMask(chars)
        var atStart = true
        var index = 0
        while index < chars.count {
            if quoted[index] {
                atStart = false
                index += 1
                continue
            }
            if index == 0 || chars[index - 1] == "\n", let marker = listMarkerLength(chars, at: index) {
                index += marker
                atStart = false
                continue
            }
            let c = chars[index]
            if atStart && c.isLetter {
                var end = index
                while end < chars.count, chars[end].isLetter || "'’".contains(chars[end]) { end += 1 }
                let word = String(chars[index..<end])
                if !keepsCapital(word) && !isAddress(chars, at: index) {
                    let lowered = Array(word == "OK" ? "ok" : lowercasingFirst(word))
                    chars.replaceSubrange(index..<end, with: lowered)
                    index += lowered.count
                } else {
                    index = end
                }
                atStart = false
                continue
            }
            if c == "\n" || endsSentence(chars, at: index) {
                atStart = true
            } else if !c.isWhitespace && !"\"“'‘(¿¡”’)]".contains(c) {
                atStart = false
            }
            index += 1
        }
        return String(chars)
    }

    /// The length of a list marker ("1. ", "- ") at `index`, if one starts there.
    private static func listMarkerLength(_ chars: [Character], at index: Int) -> Int? {
        if index + 1 < chars.count, "-•".contains(chars[index]), chars[index + 1] == " " { return 2 }
        var end = index
        while end < chars.count, end - index < 2, chars[end].isASCII, chars[end].isNumber { end += 1 }
        if end > index, end + 1 < chars.count, chars[end] == ".", chars[end + 1] == " " { return end + 2 - index }
        return nil
    }

    private static func hasInnerCapital(_ chars: [Character], at index: Int) -> Bool {
        guard chars[index].isLowercase else { return false }
        return chars[(index + 1)...].prefix(while: isWordCharacter).contains(where: \.isUppercase)
    }

    private static func keepsCapital(_ word: String) -> Bool {
        if word == "OK" { return false }
        let letters = word.filter(\.isLetter)
        if letters.count >= 2 && letters.uppercased() == letters { return true }
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    /// Whether the word at `index` is an address ("john@gmail.com").
    private static func isAddress(_ chars: [Character], at index: Int) -> Bool {
        var end = index
        while end < chars.count, !chars[end].isWhitespace {
            if chars[end] == "@" { return true }
            end += 1
        }
        return false
    }

    /// `text`'s first letter capitalized when the text starts with it, unless
    /// it starts an address or has a capital inside ("iPhone"); "5 minutes"
    /// stays.
    static func capitalizingFirstLetter(_ text: String) -> String {
        let chars = Array(text)
        guard let index = chars.firstIndex(where: isWordCharacter), chars[index].isLetter,
              !isAddress(chars, at: index), !hasInnerCapital(chars, at: index) else { return text }
        var out = chars
        out[index] = upper(chars[index])
        return String(out)
    }
}
