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

    /// "scratch that" set off as a command drops what came before it in the
    /// sentence, or the sentence before when it opens one. Not "delete
    /// that", which is as often an instruction to the reader ("Open the
    /// draft. Delete that, then create a new one").
    private static let discards: [[String]] = [["scratch", "that"], ["strike", "that"]]
    /// How sure a cue is that it corrects what came before.
    private enum Cue {
        /// "no wait": a whole new clause may replace the old one.
        case restart
        /// "I mean": replaces a restated word, or a like-for-like word.
        case swap
        /// "actually": a plain word too ("It's fine, actually, I love it"), so
        /// it repairs only a narrowed restatement ("actually just to Sarah").
        /// "sorry" is never a cue: "Thanks for the update, sorry for the delay".
        case restated
    }

    private static let cues: [([String], Cue)] = [
        (["no", "wait"], .restart), (["wait", "no"], .restart), (["i", "mean"], .swap), (["i", "meant"], .swap),
        (["make", "that"], .swap), (["or", "rather"], .swap), (["actually"], .restated),
    ]
    /// The first words of every cue, discard and filler.
    private static let cueStarts: Set<String> = Set((discards + cues.map(\.0) + fillers).compactMap(\.first))

    /// What a whole new clause opens with.
    private static let clauseOpeners: Set<String> = [
        "i", "i'll", "i'm", "i'd", "you", "you'll", "we", "we'll", "let's", "they", "they'll", "he", "he'll", "she",
        "she'll", "it", "it'll",
    ]
    /// Set off by commas and correcting nothing, "you know" is a filler: "It
    /// was, you know, fine" → "It was fine". "I mean" stays: it often opens
    /// what the speaker means ("It's not ready yet, I mean, it's close").
    private static let fillers: [[String]] = [["you", "know"]]
    /// Words a correction may open with before the word it restates.
    private static let openers: Set<String> = ["just", "only", "also", "then", "and"]
    private static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "tonight",
        "yesterday",
    ]

    /// `text` with each spoken self-correction resolved: "Meet on Tuesday,
    /// no wait, Wednesday." → "Meet on Wednesday."; "I want, I mean, I need
    /// the report" → "I need the report". A correction that restates no
    /// earlier word and is not a like-for-like swap (a day, a number, a
    /// name) stays as said.
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
            // a long dictation stays linear.
            // Inside a quotation a cue is reported speech: "Please, delete that, then confirm."
            if !cueStarts.contains(tokens[index].bare) || insideQuote(tokens, before: index, from: quote) {
                index += 1
                continue
            }
            // A command stands alone: "Please don't delete that." and "The phrase is
            // scratch that." are content. Only "scratch that" may end the dictation.
            if let end = match(discards, in: tokens, at: index),
               index == 0 || endsClause(tokens[index - 1].word),
               end < tokens.count - 1 ? endsClause(tokens[end].word) : tokens[index].bare == "scratch",
               // "Send the invoice to the team. Scratch that, send it to Sarah":
               // "it" still means the invoice, so nothing can go.
               !pointsBack(tokens, from: end + 1) {
                let start = clauseStart(tokens, before: index)
                tokens.removeSubrange(start...end)
                index = start
                continue
            }
            if let (cue, end) = cues.lazy.compactMap({ words, cue in match([words], in: tokens, at: index).map { (cue, $0) } }).first,
               index > 0, endsClause(tokens[index - 1].word), end + 1 < tokens.count,
               let start = repairedStart(tokens, cue: index, correction: end + 1, kind: cue) {
                tokens.removeSubrange(start...end)
                index = start
                continue
            }
            if index > 0, let end = match(fillers, in: tokens, at: index), end + 1 < tokens.count,
               tokens[index - 1].word.hasSuffix(","), tokens[end].word.hasSuffix(","),
               // "$10, I mean, $20 would…": an unresolved swap keeps its words.
               kind(tokens[index - 1].word, opensClause: false) == nil
                || kind(tokens[index - 1].word, opensClause: false) != kind(tokens[end + 1].word, opensClause: false) {
                tokens[index - 1].word.removeLast()
                tokens.removeSubrange(index...end)
                continue
            }
            index += 1
        }
        return tokens.map(\.word).joined(separator: " ")
    }

    /// Where the words a correction replaces start, or nil when it is unclear.
    private static func repairedStart(_ tokens: [Token], cue: Int, correction: Int, kind cueKind: Cue) -> Int? {
        // Only "no wait" reaches back across a full stop: "Thanks for the
        // help. Actually, for the trouble…" is two sentences.
        let start = cueKind == .restart ? clauseStart(tokens, before: cue) : sentenceStart(tokens, before: cue)
        guard start < cue else { return nil }
        let said = Array(tokens[start..<cue])
        let stop = tokens[correction...].firstIndex { endsSentence($0.word) } ?? tokens.count - 1
        let fixed = tokens[correction...stop].map(\.bare)
        // "actually" also opens new information ("We need the plan, actually
        // the budget is fine", "in the office, actually, in the morning"):
        // only a narrowing ("just", "only") with no verb of its own corrects.
        // Only a phrase that restates a place or recipient, opening with a
        // preposition ("actually just to Sarah"), counts; "actually the team
        // helped" is new information.
        if cueKind == .restated {
            // At most a preposition and two words: "actually on Monday Sam
            // cancelled" is a new clause.
            // Its object is a noun phrase: a determiner, a name or a number
            // ("to Sarah", "at the cafe"), never a verb ("to save money").
            let phrase = fixed.drop { openers.contains($0) }
            let openerCount = fixed.count - phrase.count
            guard openerCount > 0, phrase.count >= 2, phrase.count <= 3, !phrase.contains(where: auxiliaries.contains),
                  let anchor = phrase.first, prepositions.contains(anchor) else { return nil }
            let object = tokens[correction + openerCount + 1].word
            let named = object.first.map { $0.isUppercase || $0.isNumber } ?? false || objectPronouns.contains(bare(object))
            // "with Sam listening", "with him listening": after a name or a
            // pronoun, nothing more may follow.
            guard determiners.contains(bare(object)) || (named && phrase.count == 2) else { return nil }
        }
        // A restated word: "I want, I mean, I need" or "to the team, actually just to Sarah".
        if let anchor = fixed.first(where: { !openers.contains($0) }),
           let at = said.lastIndex(where: { $0.bare == anchor }),
           // A repeated subject marks only a short false start ("I want, I
           // mean, I need"); "I sent it to John, I mean, I hope he reads it"
           // and "It's not ready yet, I mean, it's close" go on to say more.
           !isSubject(anchor) || said.count - at <= 2,
           // A repeated "the" or "to" restates a short phrase ("to the team, I
           // mean, to Sarah"), not a clause ("the summary still needs work").
           !(determiners.contains(anchor) || prepositions.contains(anchor)) || fixed.count - (fixed.firstIndex(of: anchor) ?? 0) <= 3,
           // After a repeated preposition comes a new object ("to Sarah", "to
           // the team"), not a verb ("to Sarah, I mean, to say thanks").
           !prepositions.contains(anchor) || namesObject(fixed, after: anchor, tokens, correction) {
            return start + at
        }
        // A like-for-like swap: a day for a day, a number for a number, a
        // name for a name ("John Smith, I mean, Jon Smith").
        guard cueKind != .restated else { return nil }
        // The swap is the whole correction: "$20 would have been too much" opens a clause.
        if fixed.count <= 3, !fixed.contains(where: auxiliaries.contains), let kind = kind(tokens[correction].word, opensClause: false) {
            var swapped = said.count
            while swapped > 0, kind == self.kind(said[swapped - 1].word, opensClause: swapped == 1) { swapped -= 1 }
            if swapped < said.count { return start + swapped }
        }
        // One list item for another: "milk, eggs, I mean, bread"; but "Hi,
        // Sarah, I mean, congrats!" greets.
        if fixed.count == 1, said.count >= 2, said[said.count - 2].word.hasSuffix(","),
           !greetings.contains(said[said.count - 2].bare) { return cue - 1 }
        // "I'll call Sarah, no wait, I'll email her": a new clause; but in
        // "she'll call me" "she" is Sarah, so the words stay.
        if cueKind == .restart, clauseOpeners.contains(fixed[0]), !pointsBack(tokens, from: correction) { return start }
        return nil
    }

    private enum Kind { case number, day, name }

    private static func kind(_ word: String, opensClause: Bool) -> Kind? {
        let bare = bare(word)
        if bare.contains(where: \.isNumber) { return .number }
        if weekdays.contains(bare) { return .day }
        // A capital that opens a sentence says nothing about a name, nor does "I".
        guard bare != "i", !bare.hasPrefix("i'") else { return nil }
        return !opensClause && word.first?.isUppercase == true ? .name : nil
    }

    /// The first word of the clause holding `index`: after the last sentence
    /// end before it, or the whole sentence before when `index` opens one.
    private static func clauseStart(_ tokens: [Token], before index: Int) -> Int {
        var start = index
        while start > 0, !endsSentence(tokens[start - 1].word) { start -= 1 }
        if start == index, start > 0 {
            start -= 1
            while start > 0, !endsSentence(tokens[start - 1].word) { start -= 1 }
        }
        return start
    }

    /// Whether the sentence from `index` refers back with a pronoun ("send
    /// it", "she'll call"), which the words a correction drops would leave
    /// without a referent.
    private static func pointsBack(_ tokens: [Token], from index: Int) -> Bool {
        let pronouns: Set<String> = ["it", "its", "he", "she", "they", "him", "her", "them", "his", "their"]
        for token in tokens[min(index, tokens.count)...] {
            let bare = token.bare
            let base = bare.firstIndex(of: "'").map { String(bare[..<$0]) } ?? bare
            if pronouns.contains(base) { return true }
            if endsSentence(token.word) { break }
        }
        return false
    }

    /// The first word of the sentence holding `index`, never before a full stop.
    private static func sentenceStart(_ tokens: [Token], before index: Int) -> Int {
        var start = index
        while start > 0, !endsSentence(tokens[start - 1].word) { start -= 1 }
        return start
    }

    /// The index of the last word of the cue phrase starting at `index`.
    /// Words inside a cue may carry a comma ("no, wait").
    private static func match(_ cues: [[String]], in tokens: [Token], at index: Int) -> Int? {
        for cue in cues where index + cue.count <= tokens.count {
            let words = tokens[index..<index + cue.count]
            // A quoted cue is reported speech: "The button says: \"Delete that\"".
            guard zip(words, cue).allSatisfy({ $0.bare == $1 }),
                  !words.contains(where: { $0.word.contains(where: { "\"“”«»".contains($0) }) }) else { continue }
            let inner = words.dropLast().allSatisfy { !$0.word.hasSuffix(".") && !$0.word.hasSuffix("?") }
            if inner { return index + cue.count - 1 }
        }
        return nil
    }

    /// Whether a quotation opened before `index` is still open there.
    private static func insideQuote(_ tokens: [Token], before index: Int, from quote: Quote) -> Bool {
        var quote = quote
        for token in tokens[..<index] { quote.read(token.word) }
        return quote.isOpen
    }

    private static func endsClause(_ word: String) -> Bool { word.last.map { ",.;:!?—…".contains($0) } ?? false }
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
    /// "what time is it", "how long is the call": a noun (or "long", "much")
    /// after the question word. "What matters is…" and "What happened is…"
    /// have a verb there and state something.
    private static func asksAbout(_ questionWord: String, _ word: String) -> Bool {
        if questionWord == "how" { return ["long", "much", "many", "far", "often", "old", "soon", "big", "late"].contains(word) }
        return !subjects.contains(word) && !word.hasSuffix("s") && !word.hasSuffix("ed")
    }

    /// Whether the word after the preposition `anchor` in the correction
    /// starts a noun phrase: a determiner, a name, a number or a pronoun.
    private static func namesObject(_ fixed: [String], after anchor: String, _ tokens: [Token], _ correction: Int) -> Bool {
        guard let at = fixed.firstIndex(of: anchor), correction + at + 1 < tokens.count else { return false }
        let object = tokens[correction + at + 1].word
        return determiners.contains(bare(object)) || objectPronouns.contains(bare(object))
            || (object.first.map { $0.isUppercase || $0.isNumber } ?? false)
    }

    /// "it's", "we're", "that's": a subject with its verb.
    private static func isSubject(_ word: String) -> Bool {
        subjects.contains(word) || word.firstIndex(of: "'").map { subjects.contains(String(word[..<$0])) } ?? false
    }

    /// Words that open a greeting or an answer, not a list.
    private static let greetings: Set<String> = [
        "hi", "hey", "hello", "dear", "thanks", "yes", "no", "ok", "okay", "so", "well", "oh",
    ]
    private static let questionWords: Set<String> = ["what", "why", "how", "where", "when", "who", "which", "whose"]
    /// Question words that can take a noun before their verb ("what time is it",
    /// "how long is it"); "when Sam is free" is a clause, not a question.
    private static let nounQuestionWords: Set<String> = ["what", "which", "whose", "how"]
    private static let determiners: Set<String> = [
        "the", "a", "an", "my", "your", "his", "our", "their", "its", "this", "that", "these", "those",
    ]
    /// "her" is here, not a determiner: "with her listening" is a clause, so
    /// "actually at her office" stays as said too.
    private static let objectPronouns: Set<String> = ["me", "him", "her", "us", "them"]
    private static let prepositions: Set<String> = [
        // Not "before" or "after", which also open a clause ("before Sam left").
        "to", "for", "at", "on", "in", "with", "from", "by", "about", "into", "onto",
    ]

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
        if auxiliaries.contains(words[0]) { return subjects.contains(words[1]) }
        // "when is the call", "what time is it", but not "where it is".
        if questionWords.contains(words[0]) {
            return auxiliaries.contains(words[1])
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
