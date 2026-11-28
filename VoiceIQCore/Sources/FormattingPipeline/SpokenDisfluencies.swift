// Adapted from Hex (github.com/anomalyco/hex, ios/HEXShared/Formatting/CleanupGuard.swift, ported
// to src/dictation/cleanup/guard.rs at a0f0a858, with guard/context.rs at e27726790). MIT licence,
// Copyright (c) 2026 Christopher Langton; see THIRD_PARTY_NOTICES.md.
import Foundation

/// English disfluencies removed with no model, only those Hex's cleanup guard
/// allows at its tagger's base threshold. Hex's tagger proposes the words and
/// the guard filters them; here each rule proposes only what the guard would
/// keep, and only where the words alone leave no doubt:
/// - a repeat of function words that cannot end a clause: "I I think", "the,
///   the office", "in the, in the morning", "w- we". Not "I had had enough",
///   "I know that that works" or "Whatever you do, do it", where the first
///   word ends something; not content words ("really, really", "a bag of
///   tea, a bag of tea", "No, no"); and never a capitalized word said again
///   capitalized ("Will, Will, are you there?");
/// - a false start of an auxiliary and a pronoun at a clause's start,
///   restarted with an auxiliary and the same pronoun: "Did you, have you
///   seen it?", "Can you, can you help?". "If you can, call me" stays;
/// - "like" and "you know" set off by commas: "I went, like, to the store".
///   Without commas "like" may be the verb or "such as" ("it was like a
///   dream", "folders like we did"), so it stays; so does a comma-set "like"
///   that quotes ("he was, like, I'm not going"), means "about" ("took,
///   like, five hours") or "such as" before a name ("cities, like, Paris"),
///   and "you know" that is the question ("Wait, you know, don't you?").
///
/// "I mean" always stays: it is a correction cue `SpokenRepairs` resolves
/// only like for like, and it also emphasizes ("It's good. I mean, really
/// good."). Quoted words stay as said. Names, numbers, hyphenated compounds,
/// content adverbs and negations are never in the word lists these rules
/// remove from.
enum SpokenDisfluencies {
    private struct Token {
        var word: String
        let quoted: Bool
        var bare: String { SpokenDisfluencies.bare(word) }
        var hasComma: Bool { word.hasSuffix(",") }

        /// The word without its comma, when it is only letters: nil for "5", "Hye-jin", "end." or a quoted
        /// word, double or single ("'the").
        var spoken: String? {
            guard !quoted else { return nil }
            let core = hasComma ? String(word.dropLast()) : word
            guard let first = core.first, let last = core.last, !"'’‘".contains(first), !"'’‘".contains(last)
            else { return nil }
            return core.allSatisfy({ $0.isLetter || "'’".contains($0) }) ? core : nil
        }
    }

    /// Words a repeat or a false start may be made of: the guard's
    /// `functionWords`, which hold no name, number or negation.
    private static let functionWords: Set<String> = [
        "a", "an", "the", "to", "of", "for", "with", "at", "in", "on", "from", "by", "about", "my", "your",
        "his", "her", "our", "their", "i", "we", "you", "he", "she", "they", "it", "can", "could", "would",
        "will", "should", "do", "does", "did", "is", "are", "was", "were", "be", "have", "has", "had", "and",
        "or", "but", "if", "that", "because", "so", "just", "want", "need", "think", "get", "got", "let's",
        "i'm", "we're", "you're", "it's", "there's", "i'll", "we'll", "i'd", "this", "me", "him", "them",
        "us", "some", "gonna", "wanna", "go", "going", "what", "when", "where", "how", "why", "which", "who",
    ]
    /// Of those, the ones that never end a clause, so a repeat of them is
    /// never two clauses meeting: "the", "I", "and"; not "do" in "Whatever you
    /// do, do it", "it" in "I love it, it works" or "had" in "I had had enough".
    private static let opensOnly: Set<String> = [
        "a", "an", "the", "my", "your", "our", "their", "i", "we", "he", "she", "they", "and", "or", "but", "if",
        "because", "i'm", "we're", "you're", "it's", "there's", "i'll", "we'll", "i'd", "let's",
    ]
    private static let auxiliaries: Set<String> = [
        "can", "could", "would", "will", "should", "do", "does", "did", "is", "are", "was", "were", "have", "has",
    ]
    private static let pronouns: Set<String> = ["i", "we", "you", "he", "she", "they", "it"]
    /// The guard's `nounStarts`: a sentence's opening "Like," or "You know,"
    /// is a filler before these, and may be the verb or the sentence's own
    /// subject before anything else ("Like, comment and share", "You know,
    /// of course, that this is confidential").
    private static let nounStarts: Set<String> = [
        "a", "an", "the", "this", "that", "my", "your", "his", "her", "our", "their", "its", "i", "you", "he",
        "she", "we", "they", "it", "me", "him", "them", "us",
    ]

    /// "like" after these quotes or describes ("he was, like, I'm not going"; "it feels, like, wrong").
    private static let quotativeVerbs: Set<String> = [
        "am", "is", "are", "was", "were", "be", "been", "being", "feel", "feels", "felt", "look", "looks",
        "looked", "sound", "sounds", "sounded",
    ]
    /// So does "like" after these, unless a place or time follows: "he goes, like, no way" but "I went, like,
    /// to the store". Before a place or time "like" is never "such as" either ("left, like, after lunch").
    private static let goVerbs: Set<String> = ["go", "goes", "going", "went"]
    private static let placeWords: Set<String> = [
        "to", "into", "in", "at", "on", "out", "home", "back", "there", "up", "down", "after", "before", "during",
        "around", "since", "until", "over", "under", "near", "through", "across",
    ]
    /// "like" before these, or "a" or "an" and one of these, means "about": "it took, like, five
    /// hours", "like, a hundred".
    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "dozen", "couple", "few", "half", "hundreds", "thousands", "millions", "dozens",
    ]
    /// Cut-offs that are also prefixes or words ("re- read", "A- average", "No- not now").
    private static let notCutOffs: Set<String> = ["re", "co", "un", "no", "a"]

    static func removing(from text: String) -> String {
        let quoted = TidyText.quoteMask(Array(text))
        var offset = 0
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var tokens: [Token] = []
            var start = offset
            // Empty words keep runs of spaces: Type "a  b" into the field.
            for word in line.split(separator: " ", omittingEmptySubsequences: false) {
                let inQuote = (start..<(start + word.count)).contains { quoted[$0] }
                    || word.contains(where: { "\"“”«»".contains($0) })
                tokens.append(Token(word: String(word), quoted: inQuote))
                start += word.count + 1
            }
            offset += line.count + 1
            markSingleQuoted(&tokens)
            return removing(tokens)
        }.joined(separator: "\n")
    }

    /// Marks a single-quoted span ('put the the book', ‘…’) as quoted, from a word that opens
    /// with a quote to the next word that closes one. An opening with no close on the line
    /// ("'cause") marks nothing.
    private static func markSingleQuoted(_ tokens: inout [Token]) {
        var index = 0
        while index < tokens.count {
            guard let first = tokens[index].word.first, "'‘".contains(first) else { index += 1; continue }
            let closes = { (word: String) -> Bool in
                word.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?…)")).last.map { "'’".contains($0) } ?? false
            }
            guard let end = (index..<tokens.count).first(where: { closes(tokens[$0].word) && ($0 > index || tokens[$0].word.count > 1) })
            else { index += 1; continue }
            for quoted in index...end { tokens[quoted] = Token(word: tokens[quoted].word, quoted: true) }
            index = end + 1
        }
    }

    private static func removing(_ line: [Token]) -> String {
        var tokens = line
        var index = 0
        while index < tokens.count {
            let opens = startsSentence(tokens, at: index)
            let capital = tokens[index].word.first?.isUppercase == true
            if let count = repeatLength(tokens, at: index) ?? falseStartLength(tokens, at: index) {
                tokens.removeSubrange(index..<(index + count))
            } else if let count = fillerLength(tokens, at: index) {
                tokens.removeSubrange(index..<(index + count))
                // "I went, like, you know, to the store": a run of fillers goes as one.
                while let more = fillerLength(tokens, at: index) { tokens.removeSubrange(index..<(index + more)) }
                // "I went, like, to the store": the comma before was the pause too. "So, like, we" keeps it,
                // and so does "I told Sam, like, Priya said no".
                if index > 0, tokens[index - 1].hasComma, index < tokens.count,
                   tokens[index].word.first?.isLowercase == true, clauseWords(tokens, before: index) >= 2 {
                    tokens[index - 1].word.removeLast()
                }
            } else {
                index += 1
                continue
            }
            // A removal that opened the sentence hands its capital on, but not to "iPhone" or a path.
            if opens, capital, index < tokens.count {
                let next = tokens[index].word
                let inner = next.dropLast().drop(while: { !$0.isLetter })
                if !next.dropFirst().contains(where: \.isUppercase), !next.contains("/"), !next.contains("@"),
                   !inner.dropFirst().contains(".") {
                    tokens[index].word = TidyText.capitalizingFirst(next)
                }
            }
        }
        return tokens.map(\.word).joined(separator: " ")
    }

    /// How many words at `index` are said again right after them: one to
    /// three function words ending in one that opens a clause ("in the, in
    /// the morning"), or a cut-off start of the next word ("w- we").
    private static func repeatLength(_ tokens: [Token], at index: Int) -> Int? {
        let first = tokens[index]
        let cut = first.word.dropLast()
        if !first.quoted, first.word.hasSuffix("-"), (1...2).contains(cut.count), cut.allSatisfy(\.isLetter),
           !notCutOffs.contains(cut.lowercased()), index + 1 < tokens.count, !tokens[index + 1].quoted,
           !capitalizedMidSentence(tokens, at: index),
           tokens[index + 1].bare.hasPrefix(first.word.dropLast().lowercased()) {
            return 1
        }
        for length in 1...3 where index + 2 * length <= tokens.count {
            let span = Array(tokens[index..<(index + length)])
            let again = Array(tokens[(index + length)..<(index + 2 * length)])
            guard span.allSatisfy({ token in token.spoken.map { functionWords.contains(bare($0)) } == true }),
                  span.dropLast().allSatisfy({ !$0.hasComma }),
                  again.dropLast().allSatisfy({ $0.spoken != nil && !$0.hasComma }), again.last?.quoted == false,
                  span.map(\.bare) == again.map(\.bare), opensOnly.contains(span[length - 1].bare),
                  // A pronoun before a comma can end an inverted question: "Who am I, I wonder?"
                  !(span[length - 1].hasComma && pronouns.contains(span[length - 1].bare)) else { continue }
            // A word capitalized mid-sentence, or said again with its capital, may be a name: "Will, Will".
            guard !(index..<(index + length)).contains(where: { capitalizedMidSentence(tokens, at: $0) }),
                  !again.contains(where: { $0.word.first?.isUppercase == true && !isPronounI($0.bare) }) else { return nil }
            return length
        }
        return nil
    }

    /// Two words for a false start: an auxiliary and a pronoun with a comma
    /// at a clause's start, restarted with an auxiliary and the same pronoun
    /// ("Did you, have you seen it?", "So, can you, could you").
    private static func falseStartLength(_ tokens: [Token], at index: Int) -> Int? {
        guard index + 3 < tokens.count, startsClause(tokens, at: index),
              !capitalizedMidSentence(tokens, at: index) else { return nil }
        let words = tokens[index..<(index + 4)]
        guard words.allSatisfy({ $0.spoken != nil }), tokens[index + 1].hasComma,
              !tokens[index].hasComma, !tokens[index + 2].hasComma, !tokens[index + 3].hasComma else { return nil }
        // Inside a chain ("Should we, could we, would we go?") nothing is a false start.
        if index >= 2, tokens[index - 1].hasComma, auxiliaries.contains(tokens[index - 2].bare),
           pronouns.contains(tokens[index - 1].bare) {
            return nil
        }
        let (aux, pronoun) = (tokens[index].bare, tokens[index + 1].bare)
        guard auxiliaries.contains(aux), pronouns.contains(pronoun), auxiliaries.contains(tokens[index + 2].bare),
              tokens[index + 3].bare == pronoun else { return nil }
        return 2
    }

    /// How many words of a comma-set "like" or "you know" start at `index`:
    /// between commas mid-sentence, or opening a sentence with its comma. Not
    /// before "and" or "or" ("share, like, and comment"), and not before a
    /// sentence's last word ("Wait, you know, right?").
    private static func fillerLength(_ tokens: [Token], at index: Int) -> Int? {
        let filler: [String]
        if tokens[index].spoken.map(bare) == "like" {
            filler = ["like"]
        } else if tokens[index].spoken.map(bare) == "you", index + 1 < tokens.count, tokens[index + 1].spoken.map(bare) == "know",
                  !tokens[index].hasComma {
            filler = ["you", "know"]
        } else {
            return nil
        }
        let last = index + filler.count - 1
        let after = last + 1
        // The next word with its own comma is a list item, and "like" the verb: "follow, like, subscribe, and share".
        guard tokens[last].hasComma, after < tokens.count, !tokens[after].quoted, !tokens[after].bare.isEmpty,
              // Another filler may follow with its own comma: "you know, like, after lunch".
              !tokens[after].hasComma || tokens[after].spoken.map(bare) == "like",
              !["and", "or"].contains(tokens[after].bare), !endsSentence(tokens[after].word),
              !capitalizedMidSentence(tokens, at: index) else { return nil }
        let next = tokens[after]
        if filler == ["like"] {
            // Quoting, about a number, or "such as" before a name: "cities, like, Paris".
            let before = index > 0 ? tokens[index - 1].bare : ""
            if quotativeVerbs.contains(before) || before.hasSuffix("'s") || before.hasSuffix("’s")
                || goVerbs.contains(before) && !placeWords.contains(next.bare)
                || next.word.drop(while: { "$€£¥₹~".contains($0) }).first?.isNumber == true
                || numberWords.contains(next.bare)
                || ["a", "an"].contains(next.bare) && after + 1 < tokens.count && numberWords.contains(tokens[after + 1].bare)
                || next.word.first?.isUppercase == true && !isPronounI(next.bare)
                // "such as" between a thing and an example: "a tool, like, a hammer"; "supplies, like, paper".
                || index > 0 && !before.isEmpty && !functionWords.contains(before)
                    && (["a", "an", "the", "some"].contains(next.bare)
                        || !functionWords.contains(next.bare) && !placeWords.contains(next.bare)) {
                return nil
            }
        } else if auxiliaries.contains(next.bare) || next.bare.hasSuffix("n't") || next.bare.hasSuffix("n’t") {
            // "Wait, you know, don't you?": the words are the question.
            return nil
        }
        if startsSentence(tokens, at: index) {
            return nounStarts.contains(next.bare) ? filler.count : nil
        }
        return tokens[index - 1].hasComma && !tokens[index - 1].quoted ? filler.count : nil
    }

    private static func startsSentence(_ tokens: [Token], at index: Int) -> Bool {
        index == 0 || endsSentence(tokens[index - 1].word)
    }

    private static func startsClause(_ tokens: [Token], at index: Int) -> Bool {
        startsSentence(tokens, at: index) || tokens[index - 1].hasComma
    }

    /// The guard's name check: capitalized, not after a sentence's end or a colon, and not "I".
    private static func capitalizedMidSentence(_ tokens: [Token], at index: Int) -> Bool {
        guard index > 0, tokens[index].word.first(where: \.isLetter)?.isUppercase == true,
              let mark = tokens[index - 1].word.last, !".?!…:\"".contains(mark) else { return false }
        return !isPronounI(tokens[index].bare)
    }

    private static func isPronounI(_ bare: String) -> Bool { bare == "i" || bare.hasPrefix("i'") }

    private static func endsSentence(_ word: String) -> Bool { word.last.map { ".!?…".contains($0) } ?? false }

    /// How many words the sentence holds before `index`.
    private static func clauseWords(_ tokens: [Token], before index: Int) -> Int {
        var count = 0
        for token in tokens[..<index].reversed() {
            if endsSentence(token.word) { break }
            if !token.word.isEmpty { count += 1 }
        }
        return count
    }

    /// Lowercased, without the punctuation around it.
    private static func bare(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)).lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }
}
