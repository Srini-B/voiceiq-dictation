// Adapted from Hex (github.com/anomalyco/hex, src/dictation/{filler_words,spoken_formatting,
// spoken_symbols}.rs and style.rs at 012bdbbe). MIT licence, Copyright (c) 2026 Christopher
// Langton; see THIRD_PARTY_NOTICES.md.
import Foundation

/// Layout and symbols said by name, in English and Spanish: "new line" and
/// "new paragraph" become line breaks, "open quote" … "close quote" (or
/// "quote" … "unquote") quotation marks, and "comma", "question mark",
/// "full stop" ("period" at the end of a line), "hashtag", "underscore" and
/// the like their marks, joined to their neighbours as
/// typed text is. Matching ignores case and Spanish accents and needs whole
/// words, so "newline", "commas" or "the colonel" stay. The commas, full
/// stops and spaces a speech model puts around a spoken mark go with it.
enum SpokenMarks {
    private enum Layout {
        case lineBreak(String)
        case openQuote
        case closeQuote
    }

    private static let englishLayouts: [([String], Layout)] = [
        (["new", "paragraph"], .lineBreak("\n\n")),
        (["new", "line"], .lineBreak("\n")),
        (["line", "break"], .lineBreak("\n")),
        (["open", "quote"], .openQuote),
        (["close", "quote"], .closeQuote),
    ]

    private static let spanishLayouts: [([String], Layout)] = [
        (["nuevo", "parrafo"], .lineBreak("\n\n")),
        (["nueva", "linea"], .lineBreak("\n")),
        (["salto", "de", "linea"], .lineBreak("\n")),
        (["abrir", "comillas"], .openQuote),
        (["abre", "comillas"], .openQuote),
        (["cerrar", "comillas"], .closeQuote),
        (["cierra", "comillas"], .closeQuote),
    ]

    /// Which neighbour a symbol joins.
    private enum Join {
        /// The next word: "#release".
        case next
        /// Both words: "my_variable".
        case both
        /// The word before, with one space after: "done, thanks".
        case previous
    }

    /// Only names that are rarely prose. Not "slash", "underscore", "hyphen",
    /// "hashtag" or "at sign", which are verbs and nouns too ("to slash
    /// costs", "our hashtag is trending", "look at sign language"), nor
    /// "period" ("a trial period").
    private static let englishSymbols: [([String], Character, Join)] = [
        (["comma"], ",", .previous),
        (["colon"], ":", .previous),
        (["full", "stop"], ".", .previous),
        (["question", "mark"], "?", .previous),
        (["exclamation", "mark"], "!", .previous),
        (["exclamation", "point"], "!", .previous),
    ]

    /// None: "coma" is also a verb and a noun ("Espero que Juan coma bien",
    /// "Estuvo en coma"), "dos puntos" a score, "guion" a script.
    private static let spanishSymbols: [([String], Character, Join)] = []

    /// The words for `language`: Spanish for Spanish, otherwise English
    /// (also while the language is unknown), none for another language, so
    /// an English "coma" stays a word.
    private static func forLanguage<T>(_ english: [T], _ spanish: [T], _ language: String?) -> [T] {
        switch Tidy.primaryLanguage(language) {
        case "en": return english
        case "es": return spanish
        case nil: return english
        default: return []
        }
    }

    // MARK: Layout

    static func layout(in text: String, language: String? = nil) -> String {
        let layouts = forLanguage(englishLayouts, spanishLayouts, language)
        guard !layouts.isEmpty else { return text }
        let spanish = Tidy.primaryLanguage(language) == "es"
        let chars = Array(text)
        let address = TidyText.addressMask(chars)
        // Words already in quotation marks are literal: Type "new line" into the field.
        let quoted = TidyText.quoteMask(chars)
        var out: [Character] = []
        var index = 0
        // Where the "unquote" closing an open "quote" starts.
        var pendingUnquote: Int?
        while index < chars.count {
            let wordStart = !address[index] && !quoted[index] && (index == 0 || !joinsIdentifier(chars[index - 1]))
            if pendingUnquote == index {
                pendingUnquote = nil
                index = write(.closeQuote, into: &out, chars, after: index + "unquote".count)
                continue
            }
            // "a new line of shoes", "my new paragraph"; and inside "quote …
            // unquote" the words are what is quoted.
            // Only after a mark ("Dear Sam, new paragraph", "Hello. New line."): "Press enter
            // for new line" and "Write new paragraph at the top" use the words as nouns.
            if wordStart, pendingUnquote == nil,
               let (layout, end) = layouts.lazy.compactMap({ words, layout in
                phraseEnd(words, in: chars, at: index, foldsAccents: spanish).map { (layout, $0) }
            }).first, !nounAfterLayout(chars, after: end), saysLayout(layout, chars, at: index, end: end) {
                index = write(layout, into: &out, chars, after: end)
                continue
            }
            // "a quote for the job", "my quote": the noun.
            if wordStart, pendingUnquote == nil, !spanish,
               !(wordBefore(chars, at: index).map { ["a", "an", "the", "my", "your", "our", "their", "this", "that", "one", "no"].contains($0) } ?? false),
               let end = phraseEnd(["quote"], in: chars, at: index),
               let close = unquote(in: chars, after: end, outside: quoted) {
                pendingUnquote = close
                index = write(.openQuote, into: &out, chars, after: end)
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return String(out)
    }

    /// Where the first whole-word "unquote" after `from` starts, when words
    /// come between: "quote unquote experts" is a figure of speech.
    private static func unquote(in chars: [Character], after from: Int, outside quoted: [Bool]) -> Int? {
        var wordsBetween = false
        for index in from..<chars.count {
            // A written "unquote" in quotation marks is a word, not the command.
            let wordStart = !quoted[index] && (index == 0 || !TidyText.isWordCharacter(chars[index - 1]))
            if wordStart, phraseEnd(["unquote"], in: chars, at: index) != nil { return wordsBetween ? index : nil }
            wordsBetween = wordsBetween || TidyText.isWordCharacter(chars[index])
        }
        return nil
    }

    private static func write(_ layout: Layout, into out: inout [Character], _ chars: [Character], after end: Int) -> Int {
        switch layout {
        case .lineBreak(let breaks):
            trimEnd(&out, also: ",;")
            out += breaks
            return skip(chars, from: end, also: ",.;:")
        case .openQuote:
            trimEnd(&out, also: "")
            if let last = out.last, !"\n([\"".contains(last) { out.append(" ") }
            out.append("\"")
            return skip(chars, from: end, also: ",.")
        case .closeQuote:
            trimEnd(&out, also: ",")
            out.append("\"")
            let next = skip(chars, from: end, also: "")
            if next < chars.count, TidyText.isWordCharacter(chars[next]) { out.append(" ") }
            return next
        }
    }

    // MARK: Symbols

    /// `comma` is what a spoken "comma" becomes; `Tidy.spoken` passes a
    /// placeholder so `layout` can tell it from a comma the model wrote.
    static func symbols(in text: String, language: String? = nil, comma: Character = ",") -> String {
        let symbolWords = forLanguage(englishSymbols, spanishSymbols, language)
        guard !symbolWords.isEmpty else { return text }
        let spanish = Tidy.primaryLanguage(language) == "es"
        let chars = Array(text)
        let address = TidyText.addressMask(chars)
        // A quoted word is literal: The password is "comma".
        let quoted = TidyText.quoteMask(chars)
        var out: [Character] = []
        // Where the last symbol written ends, so trimming never removes it.
        var floor = 0
        var index = 0
        while index < chars.count {
            let wordStart = !address[index] && !quoted[index] && (index == 0 || !joinsIdentifier(chars[index - 1]))
            if wordStart, let (symbol, join, end) = symbolWords.lazy.compactMap({ words, symbol, join -> (Character, Join, Int)? in
                guard let end = phraseEnd(words, in: chars, at: index, foldsAccents: spanish),
                      // A mark follows a word: "Colon biopsy results…" opens with the organ.
                      let before = wordBefore(chars, at: index), !namesTheMark(before),
                      // A comma, colon or semicolon comes between words: "a bigger colon." is the organ.
                      !["comma", "colon", "semicolon"].contains(words[0]) || wordFollows(chars, after: end),
                      words != ["comma"] || !beforeCompound(chars, after: end, ["separated", "separate", "delimited", "splice", "splices", "rules", "key"]),
                      // "That's my final answer, full stop.": emphasis, said after a comma.
                      words != ["full", "stop"] || !afterComma(chars, at: index),
                      words != ["colon"] || !beforeCompound(chars, after: end, colonCompounds) else { return nil }
                return (symbol, join, end)
            }).first {
                if join != .next {
                    while out.count > floor, let last = out.last, TidyText.isSpace(last) || last == "," { out.removeLast() }
                }
                out.append(symbol == "," ? comma : symbol)
                floor = out.count
                index = skip(chars, from: end, also: ",.")
                if join == .previous, index < chars.count, !"\n,.;:!?)]\"".contains(chars[index]) { out.append(" ") }
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return String(out)
    }

    /// "colon cancer", "a colon cleanse": the organ, not the mark.
    private static let colonCompounds: Set<String> = [
        "cancer", "cancers", "cleanse", "cleansing", "polyp", "polyps", "health", "screening", "surgery", "wall",
    ]

    private static func beforeCompound(_ chars: [Character], after end: Int, _ compounds: Set<String>) -> Bool {
        let start = skip(chars, from: end, also: "")
        var stop = start
        while stop < chars.count, TidyText.isWordCharacter(chars[stop]) { stop += 1 }
        return compounds.contains(String(chars[start..<stop]).lowercased())
    }

    private static func afterComma(_ chars: [Character], at index: Int) -> Bool {
        var before = index
        while before > 0, TidyText.isSpace(chars[before - 1]) { before -= 1 }
        return before > 0 && chars[before - 1] == ","
    }

    /// Whether a word follows on the same line, after spaces and commas.
    private static func wordFollows(_ chars: [Character], after end: Int) -> Bool {
        let next = skip(chars, from: end, also: ",")
        return next < chars.count && (TidyText.isWordCharacter(chars[next]) || "\"“(".contains(chars[next]))
    }

    /// A line break only after a mark ("Dear Sam, new paragraph", "Hello.
    /// New line."): "Press enter for new line" and "Write new paragraph at the
    /// top" use the words as nouns. A quotation mark after any word that does
    /// not describe it.
    private static func saysLayout(_ layout: Layout, _ chars: [Character], at index: Int, end: Int) -> Bool {
        let before = wordBefore(chars, at: index)
        if case .lineBreak = layout {
            // Set off as a command: after a sentence's end or a spoken mark
            // ("Hello. New line.", "Dear Sam comma new paragraph"), or with a
            // mark after it too ("Thanks, new line, Sam"). "Sure, new paragraph
            // styles look good" is a noun phrase.
            guard before == "" else { return false }
            var mark = index
            while mark > 0, TidyText.isSpace(chars[mark - 1]) { mark -= 1 }
            let after = skip(chars, from: end, also: "")
            return ".!?\u{E000}".contains(chars[mark - 1]) || after == chars.count || ",.;:!?\n".contains(chars[after])
        }
        return before.map { !describesLayout($0) } ?? false
    }

    /// Words before "new line" that make it a noun: "a new line of shoes",
    /// "this new line", "a soft line break".
    private static func describesLayout(_ word: String) -> Bool {
        namesTheMark(word) || ["soft", "hard", "brand", "whole", "first", "next", "last", "product"].contains(word)
    }

    /// "new line of products", "new line cook": a noun phrase, not the command.
    private static func nounAfterLayout(_ chars: [Character], after end: Int) -> Bool {
        let start = skip(chars, from: end, also: "")
        var stop = start
        while stop < chars.count, TidyText.isWordCharacter(chars[stop]) { stop += 1 }
        return ["of", "cook", "cooks", "item", "items", "manager", "managers", "worker", "workers", "break", "breaks"]
            .contains(String(chars[start..<stop]).lowercased())
    }

    /// The word before `index`, lowercased; "" when a mark comes between
    /// ("Done, comma"); nil when nothing does, at the start of a line.
    private static func wordBefore(_ chars: [Character], at index: Int) -> String? {
        var end = index
        while end > 0, TidyText.isSpace(chars[end - 1]) { end -= 1 }
        guard end > 0, chars[end - 1] != "\n" else { return nil }
        var start = end
        while start > 0, TidyText.isWordCharacter(chars[start - 1]) || "'’".contains(chars[start - 1]) { start -= 1 }
        return String(chars[start..<end]).lowercased().replacingOccurrences(of: "’", with: "'")
    }

    /// A word that makes the mark's name a noun: an article, a possessive,
    /// a demonstrative or quantifier ("one question mark left", "no comma
    /// after"), or a word describing the mark ("an Oxford comma", "a big
    /// question mark", "a bigger colon").
    private static func namesTheMark(_ word: String) -> Bool {
        [
            "a", "an", "the", "my", "your", "his", "her", "our", "their", "its", "this", "that", "these", "those",
            "one", "no", "any", "some", "every", "each", "another", "single", "extra", "missing", "stray",
            "trailing", "oxford", "serial", "big", "bigger", "huge", "giant", "inverted", "un", "una", "el", "la",
            "mi", "su", "este", "esta",
            // A preposition makes it a noun: "came to full stop", "press enter for new line".
            "to", "for", "at", "of", "with", "in", "on", "from", "by", "about",
            // So does an instruction about the mark: "Add colon then space", "or comma there".
            "add", "type", "put", "insert", "use", "press", "delete", "remove", "or", "and", "need", "want",
        ].contains(word)
    }

    // MARK: Matching

    /// A word character, "_" or "-": "server_underscore_value" and "slash-command" are one word.
    /// A word character, "_", "-" or "/": "server_comma", "/comma/value" are written text.
    private static func joinsIdentifier(_ c: Character) -> Bool { TidyText.isWordCharacter(c) || "_-/".contains(c) }

    /// `c` lowercased with Spanish accents dropped: "Párrafo" reads as "parrafo".
    static func fold(_ c: Character) -> Character {
        switch TidyText.lower(c) {
        case "á": return "a"
        case "é": return "e"
        case "í": return "i"
        case "ó": return "o"
        case "ú", "ü": return "u"
        case let other: return other
        }
    }

    /// Where `words` (folded, whitespace between them) starting at `start`
    /// end, when they end a word.
    /// Accents are folded only for Spanish: an English "colon" never matches "Colón".
    static func phraseEnd(_ words: [String], in chars: [Character], at start: Int, foldsAccents: Bool = false) -> Int? {
        var position = start
        for (number, word) in words.enumerated() {
            if number > 0 {
                let spaces = chars[position...].prefix(while: \.isWhitespace).count
                guard spaces > 0 else { return nil }
                position += spaces
            }
            for expected in word {
                guard position < chars.count,
                      (foldsAccents ? fold(chars[position]) : TidyText.lower(chars[position])) == expected else { return nil }
                position += 1
            }
        }
        return position == chars.count || !joinsIdentifier(chars[position]) ? position : nil
    }

    private static func trimEnd(_ out: inout [Character], also: String) {
        while let last = out.last, TidyText.isSpace(last) || also.contains(last) { out.removeLast() }
    }

    private static func skip(_ chars: [Character], from index: Int, also: String) -> Int {
        var index = index
        while index < chars.count, TidyText.isSpace(chars[index]) || also.contains(chars[index]) { index += 1 }
        return index
    }
}

/// The hesitation sounds a speech model writes down ("um", "uh", "er").
enum Hesitations {
    /// Not "ah", which is meant as often as not ("Ah, I see").
    private static let english = ["um", "umm", "uh", "uhh", "erm", "er", "hmm", "hm"]

    /// English `text` without its hesitations, as whole words, lowercase or
    /// with only a capital first letter, so "umbrella", "Uhura", "uh-huh" and
    /// "ER" stay. Their comma or ellipsis goes with them, and one that started
    /// a sentence hands its capital to the next word. Line breaks stay.
    static func removing(from text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var removed = false
        var capitalize = false
        let address = TidyText.addressMask(chars)
        let quoted = TidyText.quoteMask(chars)
        var index = 0
        while index < chars.count {
            if !address[index], !quoted[index], let end = englishEnd(chars, at: index) {
                while let last = out.last, TidyText.isSpace(last) { out.removeLast() }
                if !removed { capitalize = chars[index].isUppercase && startsSentence(out) }
                index = afterHesitation(chars, end)
                removed = true
                continue
            }
            let c = chars[index]
            index += 1
            if removed {
                if TidyText.isSpace(c) { continue }
                if c == "\n" {
                    removed = false
                    capitalize = false
                    out.append(c)
                    continue
                }
                if ".!?,".contains(c) && startsSentence(out) { continue }
                removed = false
                let closing = ".,;:!?)]}”’…".contains(c)
                    || (c == "\"" && (index >= chars.count || !TidyText.isWordCharacter(chars[index])))
                if closing {
                    while let last = out.last, TidyText.isSpace(last) || last == "," { out.removeLast() }
                    capitalize = false
                } else {
                    // "call her, uh, tomorrow": the comma was the pause. "So, um, we" keeps it.
                    if out.last == ",", c.isLowercase, clauseHasWords(out) { out.removeLast() }
                    if needsSpace(out) { out.append(" ") }
                    if capitalize {
                        capitalize = false
                        out.append(TidyText.upper(c))
                        continue
                    }
                }
            }
            out.append(c)
        }
        if removed {
            while let last = out.last, TidyText.isSpace(last) || last == "," { out.removeLast() }
        }
        return String(out)
    }

    /// Whether the sentence `out` ends in holds two words or more.
    private static func clauseHasWords(_ out: [Character]) -> Bool {
        let clause = out.dropLast().reversed().prefix { !".!?\n".contains($0) }
        return clause.split(whereSeparator: \.isWhitespace).count >= 2
    }

    /// "_" and "/" join too: "um_server" is an identifier, "/um/config" a path.
    private static func joinsWord(_ c: Character) -> Bool { TidyText.isWordCharacter(c) || "-'’_/".contains(c) }

    /// A hesitation's letters that are a word here: after a number ("5 um",
    /// micrometres; "2 em"), capitalized mid-sentence ("Mr. Um"), or "uh"
    /// in "uh huh".
    static func isWord(_ chars: [Character], at start: Int) -> Bool {
        var before = start
        while before > 0, TidyText.isSpace(chars[before - 1]) { before -= 1 }
        if before > 0, chars[before - 1].isNumber { return true }
        var wordStart = before
        while wordStart > 0, !chars[wordStart - 1].isWhitespace { wordStart -= 1 }
        let previous = String(chars[wordStart..<before]).lowercased()
        // "Mr. Um", "server underscore um" spelling an identifier, and the sound
        // named as a word: "the um key", "He said um three times".
        if ["mr.", "mrs.", "ms.", "dr.", "prof.", "underscore", "hyphen", "slash", "dot", "the", "a", "an", "said", "say",
            "says", "saying", "word", "type", "typed"].contains(previous) { return true }
        if chars[start].isUppercase, before > 0, !".!?\n".contains(chars[before - 1]) { return true }
        let rest = String(chars[start...].prefix(16)).lowercased()
        if ["uh huh", "uh-huh", "uh oh", "uh-oh"].contains(where: rest.hasPrefix) { return true }
        // "Er is a German pronoun": a capitalized sound followed by a verb is the word.
        if chars[start].isUppercase, ["er is", "um is", "uh is"].contains(where: rest.hasPrefix) { return true }
        // "um underscore server" spells an identifier.
        let next = rest.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return ["underscore", "hyphen", "slash", "dot"].contains(next)
    }

    /// Whether the mark at `index` holds an address or a domain together:
    /// "@", or "." between letters ("um@gmail.com", "john@er.com").
    static func joinsAddress(_ chars: [Character], at index: Int) -> Bool {
        guard index >= 0, index < chars.count else { return false }
        if chars[index] == "@" { return true }
        return chars[index] == "." && index > 0 && index + 1 < chars.count
            && TidyText.isWordCharacter(chars[index - 1]) && TidyText.isWordCharacter(chars[index + 1])
    }

    private static func englishEnd(_ chars: [Character], at start: Int) -> Int? {
        if start > 0, joinsWord(chars[start - 1]) || joinsAddress(chars, at: start - 1) { return nil }
        if Hesitations.isWord(chars, at: start) { return nil }
        for word in english {
            let end = start + word.count
            guard end <= chars.count else { continue }
            let matches = zip(chars[start..<end], word).enumerated().allSatisfy { number, pair in
                pair.0 == pair.1 || (number == 0 && pair.0 == TidyText.upper(pair.1))
            }
            if matches, end == chars.count || !(joinsWord(chars[end]) || joinsAddress(chars, at: end)) { return end }
        }
        return nil
    }

    private static func afterHesitation(_ chars: [Character], _ end: Int) -> Int {
        func skipSpaces(_ index: Int) -> Int {
            var index = index
            while index < chars.count, TidyText.isSpace(chars[index]) { index += 1 }
            return index
        }
        var index = skipSpaces(end)
        if index < chars.count, chars[index] == "," || chars[index] == "…" {
            index += 1
        } else if index + 2 < chars.count, chars[index] == ".", chars[index + 1] == ".", chars[index + 2] == "." {
            index += 3
        }
        return skipSpaces(index)
    }

    private static func startsSentence(_ out: [Character]) -> Bool {
        guard let last = out.last else { return true }
        return ".!?\n".contains(last)
    }

    private static func needsSpace(_ out: [Character]) -> Bool {
        guard let last = out.last else { return false }
        if "\n([{“‘".contains(last) { return false }
        if last == "\"" { return out.count >= 2 && !out[out.count - 2].isWhitespace }
        return true
    }

    /// `text` without standalone hesitations in `language`: at the start or
    /// after a space or comma, and before a space, a comma or a sentence's
    /// end, with their comma and spaces.
    static func removingStandalone(from text: String, language: FillerLanguage?) -> String {
        guard let language else { return TidyText.collapsingSpaces(text) }
        let chars = Array(text)
        let address = TidyText.addressMask(chars)
        let quoted = TidyText.quoteMask(chars)
        var out = ""
        var index = 0
        while index < chars.count {
            if !address[index], !quoted[index], !Hesitations.isWord(chars, at: index), let end = language.end(chars, at: index) {
                let starts = index == 0 || chars[index - 1].isWhitespace || chars[index - 1] == ","
                let ends = end >= chars.count || chars[end].isWhitespace
                    || (",.!?".contains(chars[end]) && !Hesitations.joinsAddress(chars, at: end))
                // "UM" and "ER" are acronyms, not hesitations.
                let acronym = chars[index..<end].filter(\.isUppercase).count > 1
                if starts && ends && !acronym {
                    var after = end
                    if after < chars.count, chars[after] == "," { after += 1 }
                    while after < chars.count, TidyText.isSpace(chars[after]) { after += 1 }
                    // "C'est bon, euh." → "C'est bon.": the pause's comma goes before an end mark.
                    if after == chars.count || ".!?".contains(chars[after]) {
                        while let last = out.last, last.isWhitespace || last == "," { out.removeLast() }
                    }
                    out.append(" ")
                    index = after
                    continue
                }
            }
            out.append(chars[index])
            index += 1
        }
        return TidyText.collapsingSpaces(out)
    }
}

/// The hesitation sounds each language drops. English "er" is a word in
/// Norwegian, Danish, Swedish and German, and "um" in Portuguese, so each
/// language drops only its own, and a language without a list drops none.
/// Spanish drops "eh", "em" and "mmm" (never "e", "and"), German "äh" and
/// "ähm" (never "eh", "anyway"), French "euh" and "heu".
enum FillerLanguage {
    case english, nordic, spanish, german, french

    init?(_ language: String?) {
        switch Tidy.primaryLanguage(language) {
        case "en": self = .english
        case "nb", "nn", "no", "da", "sv": self = .nordic
        case "es": self = .spanish
        case "de": self = .german
        case "fr": self = .french
        default: return nil
        }
    }

    /// Where the hesitation at `start` ends, if one starts there.
    func end(_ chars: [Character], at start: Int) -> Int? {
        guard start < chars.count else { return nil }
        func run(_ from: Int, _ expected: Character) -> Int {
            var end = from
            while end < chars.count, TidyText.lower(chars[end]) == expected { end += 1 }
            return end
        }
        /// A run of `vowel`, then one or more "h", then any "m".
        func vowelH(_ vowel: Character) -> Int? {
            let afterVowel = run(start, vowel)
            let afterH = run(afterVowel, "h")
            return afterH > afterVowel ? run(afterH, "m") : nil
        }
        func hm() -> Int? {
            let afterM = run(start + 1, "m")
            return afterM > start + 1 ? afterM : nil
        }
        let first = TidyText.lower(chars[start])
        switch self {
        case .english:
            guard start + 1 < chars.count else { return nil }
            switch (first, TidyText.lower(chars[start + 1])) {
            case ("u", "m"): return run(start + 2, "m")
            case ("u", "h"): return run(start + 2, "h")
            // "er" and "erm", never "err" ("err on the side of caution").
            case ("e", "r"): return run(start + 2, "m")
            case ("h", "m"): return run(start + 2, "m")
            default: return nil
            }
        case .nordic:
            switch first {
            case "e", "ø", "ö": return vowelH(first)
            case "h": return hm()
            default: return nil
            }
        case .spanish:
            switch first {
            case "e":
                if let end = vowelH("e") { return end }
                let afterE = run(start, "e")
                let afterM = run(afterE, "m")
                return afterM > afterE ? afterM : nil
            // "mmm", never "mm" (millimetres).
            case "m":
                let afterM = run(start, "m")
                return afterM >= start + 3 ? afterM : nil
            case "h": return hm()
            default: return nil
            }
        case .german:
            switch first {
            case "ä", "ö": return vowelH(first)
            case "h": return hm()
            default: return nil
            }
        case .french:
            // "euh", "heu", "hmm"; never "eu" (had) or "hum" alone.
            let lower = chars[start...].prefix(4).map(TidyText.lower)
            if lower.starts(with: "euh") { return run(start + 3, "h") }
            if lower.starts(with: "heu") { return run(start + 3, "u") }
            return first == "h" ? hm() : nil
        }
    }
}
