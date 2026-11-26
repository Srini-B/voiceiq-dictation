import Foundation

/// English fixes a speech model leaves for the writer, made only where the
/// words themselves leave no doubt, so a dictation never loses what was
/// meant: a spoken self-correction keeps only the correction, and a question
/// the model left unpunctuated gets its question mark.
enum SpokenRepairs {
    private struct Token {
        var word: String
        var bare: String { SpokenRepairs.bare(word) }
    }

    // MARK: Self-corrections

    /// Cues that may introduce a correction. Each is also plain speech ("It's
    /// fine, I mean, it's not great"), so a correction is repaired only when
    /// it swaps like for like and nothing else.
    private static let cues: [[String]] = [
        ["no", "wait"], ["wait", "no"], ["i", "mean"], ["i", "meant"], ["make", "that"], ["or", "rather"],
    ]
    private static let cueStarts: Set<String> = Set(cues.compactMap(\.first))
    private static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "tonight",
        "yesterday",
    ]
    /// Words that may follow a corrected number: "15,000, I mean, 50,000 dollars".
    private static let units: Set<String> = [
        "dollars", "euros", "pounds", "rupees", "percent", "people", "minutes", "hours", "days", "weeks", "months",
        "years", "am", "pm", "a.m", "p.m",
    ]

    /// `text` with each like-for-like spoken self-correction resolved: a day
    /// for a day or a number for a number (not names: "I met John, I mean,
    /// Seriously." has a capital that is no name), where the
    /// correction is all that is left of the sentence. "Meet on Tuesday, no
    /// wait, Wednesday." → "Meet on Wednesday."; "The budget is 15,000, I
    /// mean, 50,000 dollars." → "The budget is 50,000 dollars." Anything else
    /// stays as said, cue included: without a model, "We met on Friday, I
    /// mean, Monday works too" or "Scratch that, send it to Sarah" cannot be
    /// resolved without risking a word the speaker meant.
    static func correcting(_ text: String) -> String {
        // A quotation may span lines: its state carries from one to the next.
        var quote = Quote()
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let corrected = correctingLine(String(line), quote: quote)
            quote.read(String(line))
            return corrected
        }.joined(separator: "\n")
    }

    /// Which quotation marks are open.
    private struct Quote {
        var straight = false
        var curly = 0
        var isOpen: Bool { straight || curly > 0 }

        mutating func read(_ text: String) {
            for c in text {
                switch c {
                case "\"": straight.toggle()
                case "“", "«": curly += 1
                case "”", "»": curly = max(0, curly - 1)
                default: break
                }
            }
        }
    }

    private static func correctingLine(_ line: String, quote: Quote) -> String {
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map { Token(word: String($0)) }
        var index = 0
        while index < tokens.count {
            // Most words open no cue; only then is the quotation state read, so
            // a long dictation stays linear. Inside a quotation a cue is reported speech.
            if !cueStarts.contains(tokens[index].bare) || insideQuote(tokens, before: index, from: quote) {
                index += 1
                continue
            }
            if let end = match(cues, in: tokens, at: index), index > 0, tokens[index - 1].word.hasSuffix(","),
               end + 1 < tokens.count, let start = swappedStart(tokens, cue: index, correction: end + 1) {
                tokens.removeSubrange(start...end)
                index = start
                continue
            }
            index += 1
        }
        return tokens.map(\.word).joined(separator: " ")
    }

    /// Where the words a like-for-like correction replaces start, or nil.
    /// The correction must end its sentence: one or two words of the same
    /// kind ("Jon Smyth"), or a number and its unit.
    private static func swappedStart(_ tokens: [Token], cue: Int, correction: Int) -> Int? {
        let stop = tokens[correction...].firstIndex { endsSentence($0.word) } ?? tokens.count - 1
        let fixed = Array(tokens[correction...stop])
        guard fixed.count <= 2, let kind = kind(fixed[0].word, opensClause: false), kind != .name else { return nil }
        if fixed.count == 2 {
            let second = fixed[1]
            guard self.kind(second.word, opensClause: false) == kind || (kind == .number && units.contains(second.bare))
            else { return nil }
        }
        // The words replaced: the run of the same kind right before the cue,
        // inside its sentence ("Tuesday," or "John Smith,").
        var start = cue
        while start > 0, !endsSentence(tokens[start - 1].word), cue - start < 2,
              self.kind(tokens[start - 1].word, opensClause: start - 1 == 0 || endsSentence(tokens[start - 2].word)) == kind {
            start -= 1
        }
        // "Gate 12, I mean, 12 PM": the same number restated is no correction.
        guard start < cue, tokens[start..<cue].map(\.bare) != [fixed[0].bare] else { return nil }
        // One number for one of as many digits: "Call 555 1234, I mean, 5" and
        // "Room 101, I mean, 2" fix a digit, not the number.
        if kind == .number {
            let digits = { (word: String) in word.filter(\.isNumber).count }
            guard start == cue - 1, digits(tokens[start].word) == digits(fixed[0].word),
                  start == 0 || self.kind(tokens[start - 1].word, opensClause: false) != .number else { return nil }
        }
        return start
    }

    private enum Kind { case number, day, name }

    private static func kind(_ word: String, opensClause: Bool) -> Kind? {
        let bare = bare(word)
        // Digits only: "iOS 17, I mean, M2" names a model, not a number.
        if bare.contains(where: \.isNumber) { return bare.contains(where: \.isLetter) ? nil : .number }
        if weekdays.contains(bare) { return .day }
        // A capital that opens a sentence says nothing about a name, nor does "I".
        guard bare != "i", !bare.hasPrefix("i'") else { return nil }
        return !opensClause && word.first?.isUppercase == true ? .name : nil
    }

    /// The index of the last word of the cue phrase starting at `index`.
    /// Words inside a cue may carry a comma ("no, wait").
    private static func match(_ cues: [[String]], in tokens: [Token], at index: Int) -> Int? {
        for cue in cues where index + cue.count <= tokens.count {
            let words = tokens[index..<index + cue.count]
            guard zip(words, cue).allSatisfy({ $0.bare == $1 }),
                  !words.contains(where: { $0.word.contains(where: { "\"“”«»".contains($0) }) }) else { continue }
            let inner = words.dropLast().allSatisfy { !$0.word.hasSuffix(".") && !$0.word.hasSuffix("?") }
            // The cue is set off: "Tuesday, no wait, Wednesday".
            if inner, words.last?.word.hasSuffix(",") == true { return index + cue.count - 1 }
        }
        return nil
    }

    /// Whether a quotation opened before `index` is still open there.
    private static func insideQuote(_ tokens: [Token], before index: Int, from quote: Quote) -> Bool {
        var quote = quote
        for token in tokens[..<index] { quote.read(token.word) }
        return quote.isOpen
    }

    private static func endsSentence(_ word: String) -> Bool { word.last.map { ".!?".contains($0) } ?? false }

    // MARK: Questions

    private static let auxiliaries: Set<String> = [
        "can", "could", "would", "will", "should", "shall", "do", "does", "did", "is", "are", "was", "were", "have",
        "has", "had", "may", "might", "must", "isn't", "aren't", "don't", "doesn't", "didn't", "can't", "won't",
        "wouldn't", "couldn't", "shouldn't",
    ]
    private static let subjects: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "this", "that", "there", "these", "those", "anyone", "someone",
    ]
    private static func opensNounPhrase(_ word: String) -> Bool {
        determiners.contains(word) || subjects.contains(word) || objectPronouns.contains(word)
    }

    /// "what time is it", "how long is the call": a noun (or "long", "much")
    /// after the question word. "What matters is…" and "What happened is…"
    /// have a verb there and state something.
    private static func asksAbout(_ questionWord: String, _ word: String) -> Bool {
        if questionWord == "how" { return ["long", "much", "many", "far", "often", "old", "soon", "big", "late"].contains(word) }
        return !subjects.contains(word) && !word.hasSuffix("s") && !word.hasSuffix("ed")
    }

    private static let questionWords: Set<String> = ["what", "why", "how", "where", "when", "who", "which", "whose"]
    /// Question words that can take a noun before their verb ("what time is it",
    /// "how long is it"); "when Sam is free" is a clause, not a question.
    private static let nounQuestionWords: Set<String> = ["what", "which", "whose", "how"]
    private static let determiners: Set<String> = [
        "the", "a", "an", "my", "your", "his", "our", "their", "its", "this", "that", "these", "those",
    ]
    private static let objectPronouns: Set<String> = ["me", "him", "her", "us", "them"]

    /// `text` with a question mark on each line's last sentence when the
    /// model left it without a final mark and it asks: an auxiliary before
    /// its subject ("can you send it") or a question word before one ("when
    /// is the call"). "When I get home, call me" stays.
    static func askingQuestions(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let line = String(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let last = trimmed.last, last.isLetter || last.isNumber else { return line }
            // The last sentence: after a mark followed by a space, so "1.2" splits nothing.
            let sentence = trimmed.ranges(of: #/[.!?]\s/#).last.map { String(trimmed[$0.upperBound...]) } ?? trimmed
            let words = sentence.split(separator: " ").map { bare(String($0)) }.filter { !$0.isEmpty }
            // "Should you need help, call me": an inverted condition, not a question.
            if let first = words.first, ["should", "had", "were"].contains(first), sentence.contains(",") { return line }
            guard words.count >= 2, asks(words) else { return line }
            return trimmed + "?"
        }.joined(separator: "\n")
    }

    private static func asks(_ words: [String]) -> Bool {
        // "do you", but "do it now" and "have this ready by noon" are instructions.
        if words[0] == "do" || words[0] == "have" { return ["i", "you", "we", "they"].contains(words[1]) }
        // Not "May you…" (a wish) or "Don't you worry" (an instruction).
        if auxiliaries.contains(words[0]), words[0] != "may", !words[0].hasSuffix("n't") { return subjects.contains(words[1]) }
        // "when is the call", "what time is it", but not "where it is" or
        // "What was promised never arrived".
        if questionWords.contains(words[0]) {
            return (auxiliaries.contains(words[1]) && (words.count == 2 || opensNounPhrase(words[2])))
                || (nounQuestionWords.contains(words[0]) && words.count > 2 && auxiliaries.contains(words[2])
                    && asksAbout(words[0], words[1]))
        }
        // "what's the plan", "where're they", "who's coming"; but "What's left
        // goes in the trash" and "What's worse, we missed it" are statements.
        guard let apostrophe = words[0].firstIndex(of: "'") else { return false }
        let next = words[1]
        return questionWords.contains(String(words[0][..<apostrophe])) && !words.dropFirst().contains(where: auxiliaries.contains)
            && (determiners.contains(next) || subjects.contains(next) || objectPronouns.contains(next) || words.count <= 2)
    }

    /// Lowercased, without the punctuation around it.
    private static func bare(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)).lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }
}
