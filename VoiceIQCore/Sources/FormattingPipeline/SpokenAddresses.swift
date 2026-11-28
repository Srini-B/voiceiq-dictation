// Adapted from Hex (github.com/anomalyco/hex, ios/HEXShared/Formatting/SpokenCleanupRules.swift
// at 012bdbbe). MIT licence, Copyright (c) 2026 Christopher Langton; see THIRD_PARTY_NOTICES.md.
import Foundation

/// Email addresses said aloud in English. "at the rate" (how India says @)
/// becomes "@" only before a domain ("gmail dot com", "gmail.com"), never in
/// "at the rate of 5%" or "at the rate we're going"; "at sign" always does.
/// Before a domain, the word before (with any "dot"-joined parts) and the
/// domain join into one lowercase address: "John at the rate Gmail dot com."
/// becomes "john@gmail.com.", "dot" becoming "." only there. A lone "at
/// sign" is left to `SpokenMarks.symbols`.
enum SpokenAddresses {
    private struct Token {
        let word: String
        let range: Range<String.Index>
        /// Split off "rate" or "sign" by `splittingGluedDomains`.
        var glued = false
    }

    private static let openingMarks: Set<Character> = ["¿", "¡", "\"", "“", "«", "(", "„"]
    private static let closingMarks: Set<Character> = [",", ".", ";", ":", "!", "?", "…", "\"", "”", "»", ")"]

    static func joining(in text: String) -> String {
        guard text.range(of: "at", options: .caseInsensitive) != nil else { return text }
        let tokens = splittingGluedDomains(words(in: text), in: text)
        func word(_ index: Int) -> String? { tokens.indices.contains(index) ? tokens[index].word : nil }
        var edits: [(range: Range<String.Index>, text: String)] = []
        // The first word an address may take: none already in an earlier one.
        var free = 0
        // The last word of the last address joined.
        var lastAddress: Int?
        // Quoted words are literal: The password is "john at sign gmail dot com".
        let literal = TidyText.quoteMask(Array(text))
        var index = 0
        while index < tokens.count {
            guard let marker = marker(tokens, at: index),
                  !literal[text.distance(from: text.startIndex, to: tokens[index].range.lowerBound)] else {
                index += 1
                continue
            }
            let next = marker.end + 1
            if marker.ambiguous, bare(word(next) ?? "") == "of" {
                index = next
                continue
            }
            guard let domain = domain(tokens, from: next),
                  let ending = marker.ambiguous ? ambiguousEnding(tokens, next: next, domain: domain) : .sentence else {
                index = marker.end + 1
                continue
            }
            var start = index
            var local: [String] = []
            // An opening quote stays outside the address: "\"John at sign gmail dot com."
            var quote = ""
            func quoted(_ word: String?) -> (marks: String, part: String)? {
                guard let word else { return nil }
                let marks = String(word.prefix { openingMarks.contains($0) })
                return localPart(String(word.dropFirst(marks.count))).map { (marks, $0) }
            }
            if index - 1 >= free, let (marks, part) = quoted(word(index - 1)) {
                local = [part]
                quote = marks
                start = index - 1
                // "john dot smith at the rate…": the parts before join with dots too.
                while quote.isEmpty, start - 2 >= free, let dot = word(start - 1), dot.lowercased() == "dot",
                      let (marks, part) = quoted(word(start - 2)) {
                    local.insert(part, at: 0)
                    quote = marks
                    start -= 2
                }
            }
            // No mailbox before it ("Type an at sign example.com"): a phrase, not an address.
            // "Prices rose at the rate gmail dot com": with "at the rate", the mailbox
            // opens the sentence or a clause, or follows a word that introduces an address;
            // before ", thanks" or "and" another address, only a strong one ("is moving" stays).
            let introduced = marker.ambiguous ? introduction(tokens, in: text, before: start, after: lastAddress) : .strong
            guard !local.isEmpty, let introduced, introduced == .strong || ending == .sentence else {
                index = marker.end + 1
                continue
            }
            let address = (local.joined(separator: ".") + "@" + domain.labels.joined(separator: ".")).lowercased()
            edits.append((tokens[start].range.lowerBound..<tokens[domain.end].range.upperBound, quote + address + domain.trailing))
            index = domain.end + 1
            free = index
            lastAddress = domain.end
        }
        guard !edits.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for edit in edits {
            result += text[cursor..<edit.range.lowerBound] + edit.text
            cursor = edit.range.upperBound
        }
        return result + text[cursor...]
    }

    /// How an address after "at the rate" ends: where the sentence does, or
    /// where it goes on, at a courtesy after a comma ("…, please."). Before
    /// "and" or "or" and another address, it ends as the last address does.
    private enum Ending { case sentence, continued }

    /// How the domain after "at the rate" (from `next`) ends an address, or nil.
    /// "at the rate" is plain English before a written domain ("grew at the rate
    /// Amazon.com"): only a spoken one ("company dot co dot in") or one the model
    /// glued to "rate" ("rategmail.com") is an address, and only at one of those
    /// endings. "grew at the rate Amazon dot com predicted" stays.
    private static func ambiguousEnding(_ tokens: [Token], next: Int,
                                        domain: (labels: [String], end: Int, trailing: String)) -> Ending? {
        guard domain.end > next || tokens[next].glued else { return nil }
        if domain.end == tokens.count - 1 || domain.trailing.contains(where: { ".!?".contains($0) }) { return .sentence }
        let rest = domain.end + 1
        if domain.trailing == "," {
            let end = tokens[rest...].firstIndex { $0.word.last.map { ".!?".contains($0) } ?? false } ?? tokens.count - 1
            return [["please"], ["thanks"], ["thank", "you"], ["cheers"]].contains(tokens[rest...end].map { bare($0.word) })
                ? .continued : nil
        }
        guard domain.trailing.isEmpty, ["and", "or"].contains(tokens[rest].word.lowercased()) else { return nil }
        return addressEnding(tokens, at: rest + 1)
    }

    /// How an address said with a marker from `index` ends ("ravi at the rate
    /// gmail dot com"), or nil when none starts there.
    private static func addressEnding(_ tokens: [Token], at index: Int) -> Ending? {
        var end = index
        guard tokens.indices.contains(end), localPart(tokens[end].word) != nil else { return nil }
        while end + 2 < tokens.count, tokens[end + 1].word.lowercased() == "dot", localPart(tokens[end + 2].word) != nil { end += 2 }
        guard end + 1 < tokens.count, let marker = marker(tokens, at: end + 1),
              let domain = domain(tokens, from: marker.end + 1) else { return nil }
        if marker.ambiguous { return ambiguousEnding(tokens, next: marker.end + 1, domain: domain) }
        return domain.end == tokens.count - 1 || domain.trailing.contains(where: { ".!?".contains($0) }) ? .sentence : .continued
    }

    private enum Introduction { case strong, weak }

    /// Words that introduce an address: "Mail priya at the rate…", "cc priya…".
    private static let strongIntroductions: Set<String> = [
        "email", "e-mail", "mail", "cc", "bcc", "contact", "reach", "write", "ping", "address", "id", "me", "tell",
        "invite", "copy", "forward", "send", "reply", "notify", "message", "text", "include",
    ]
    /// Of those, the words that name an address, so what follows them is one: "My email will be billing…".
    private static let addressNouns: Set<String> = ["email", "e-mail", "mail", "address", "id"]
    /// Words that introduce an address only after one of those ("My email is
    /// priya…", "Write to priya…") or where the address ends the sentence:
    /// "The market is moving at the rate google dot com, thanks." stays.
    private static let weakIntroductions: Set<String> = [
        "is", "was", "are", "be", "to", "from", "at", "on", "in", "via", "as", "with", "for", "try", "use", "add",
    ]

    /// How the mailbox starting at `start` is introduced for "at the rate", or
    /// nil: strongly when it opens the sentence or a clause, follows a strong
    /// word, or follows "and" or "or" after an address joined here (`after`);
    /// weakly after a weak word, or after any other "and" or "or".
    private static func introduction(_ tokens: [Token], in text: String, before start: Int, after lastAddress: Int?) -> Introduction? {
        // A mailbox that opens the text or a line ("Contacts\npriya at the rate…").
        guard start > 0, !text[tokens[start - 1].range.upperBound..<tokens[start].range.lowerBound].contains("\n") else { return .strong }
        let previous = tokens[start - 1].word
        let mailbox = bare(tokens[start].word)
        // A verb or a number, not a mailbox: "growing at the rate…", "went from 10 at the rate…".
        // Not "-ed" ("Ahmed") or a short "-ing" ("Ming").
        let verb = mailbox.hasSuffix("ing") && mailbox.count >= 6
        let number = mailbox.allSatisfy(\.isNumber)
        // After a comma, only a mailbox that is no verb or number: "Prices kept rising, growing at the rate…".
        if previous.last == ",", verb || number { return nil }
        if let last = previous.last, ".!?,:;".contains(last) { return .strong }
        let word = bare(previous).replacingOccurrences(of: "’", with: "'")
        if strongIntroductions.contains(word) { return .strong }
        // "My email's priya…" is "email is"; "It's priya…" is "it is".
        let contracted = word.hasSuffix("'s") ? String(word.dropLast(2)) : nil
        if let contracted, strongIntroductions.contains(contracted) { return .strong }
        // The words before it in its sentence: "My email will be priya…" has "email" earlier.
        var first = start - 1
        while first > 0, !(tokens[first - 1].word.last.map { ".!?".contains($0) } ?? false) { first -= 1 }
        let earlier = tokens[first..<(start - 1)].map { bare($0.word) }
        if weakIntroductions.contains(word) || contracted != nil {
            // A word naming the address just before: "My email will be billing at the rate…".
            let named = contracted == nil && earlier.suffix(3).contains(where: addressNouns.contains)
            // "It is growing at the rate…", "went from 10 at the rate…", even after another strong word
            // ("Tell me it will be growing…"). Not after "to" ("to billing", "to 123").
            let progressive = ["is", "was", "are", "be"].contains(word) || contracted != nil
            if !named, (progressive && verb) || ((progressive || word == "from") && number) { return nil }
            // Only within the phrase: "Tell me whether the market is moving at the rate…" stays.
            if contracted == nil, earlier.suffix(3).contains(where: strongIntroductions.contains) { return .strong }
            return .weak
        }
        guard ["and", "or"].contains(word) else { return nil }
        if lastAddress == start - 2 { return .strong }
        // "Prices in Europe rose and fell at the rate…", "from 5 or 10 at the rate…": only a list after a
        // strong introduction or an address ("Send it to priya … and ravi…") names a mailbox, never a
        // number; a weak word ("in", "to") anywhere earlier is no introduction.
        let introduced = earlier.isEmpty || earlier.contains { strongIntroductions.contains($0) || $0.contains("@") }
        return introduced && !number ? .weak : nil
    }

    private static func words(in text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isWhitespace {
                if let begin = start { tokens.append(Token(word: String(text[begin..<index]), range: begin..<index)) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { tokens.append(Token(word: String(text[begin...]), range: begin..<text.endIndex)) }
        return tokens
    }

    /// Apple's speech models glue a spoken domain to the word before it
    /// ("John at the rategmail.com.", "Priya at signyahoo.com."): this splits
    /// "rate" or "sign" off again.
    private static func splittingGluedDomains(_ tokens: [Token], in text: String) -> [Token] {
        var result: [Token] = []
        for (index, token) in tokens.enumerated() {
            let lower = token.word.lowercased()
            let before = index > 0 ? tokens[index - 1].word.lowercased() : nil
            let prefix: String?
            if before == "the", index > 1, tokens[index - 2].word.lowercased() == "at", lower.hasPrefix("rate") {
                prefix = "rate"
            } else if before == "at", lower.hasPrefix("sign") {
                prefix = "sign"
            } else {
                prefix = nil
            }
            guard let prefix, isDomain(String(token.word.dropFirst(prefix.count))) else {
                result.append(token)
                continue
            }
            let cut = text.index(token.range.lowerBound, offsetBy: prefix.count)
            result.append(Token(word: String(token.word.prefix(prefix.count)), range: token.range.lowerBound..<cut))
            result.append(Token(word: String(token.word.dropFirst(prefix.count)), range: cut..<token.range.upperBound, glued: true))
        }
        return result
    }

    /// "at the rate" (ambiguous: also plain English) or "at sign" / "at-sign"
    /// at `index`; only the last word may carry punctuation ("at sign.").
    private static func marker(_ tokens: [Token], at index: Int) -> (end: Int, ambiguous: Bool)? {
        func word(_ offset: Int) -> String? {
            tokens.indices.contains(index + offset) ? tokens[index + offset].word.lowercased() : nil
        }
        if bare(tokens[index].word) == "at-sign" { return (index, false) }
        guard word(0) == "at" else { return nil }
        if let sign = word(1), bare(sign) == "sign" { return (index + 1, false) }
        if word(1) == "the", let rate = word(2), bare(rate) == "rate" { return (index + 2, true) }
        return nil
    }

    /// A domain spoken from `index`: labels joined by "dot" or already by
    /// ".", at least two, ending in a top-level domain of letters ("com",
    /// "co dot in"). Punctuation after the last label is kept apart.
    private static func domain(_ tokens: [Token], from index: Int) -> (labels: [String], end: Int, trailing: String)? {
        var labels: [String] = []
        var position = index
        var trailing = ""
        while tokens.indices.contains(position) {
            let token = tokens[position]
            let core = withoutClosingMarks(token.word)
            let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !core.isEmpty, parts.allSatisfy(isLabel) else { return nil }
            labels += parts
            trailing = String(token.word.dropFirst(core.count))
            guard trailing.isEmpty, tokens.indices.contains(position + 2),
                  tokens[position + 1].word.lowercased() == "dot",
                  isLabel(withoutClosingMarks(tokens[position + 2].word).split(separator: ".").first.map(String.init) ?? "")
            else { break }
            position += 2
        }
        return isTopLevel(labels) ? (labels, position, trailing) : nil
    }

    /// A written domain, maybe with punctuation after it: "gmail.com.", "co.in".
    private static func isDomain(_ word: String) -> Bool {
        let labels = withoutClosingMarks(word).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return isTopLevel(labels) && labels.allSatisfy(isLabel)
    }

    private static func isTopLevel(_ labels: [String]) -> Bool {
        guard labels.count >= 2, let top = labels.last else { return false }
        return top.count >= 2 && top.allSatisfy(\.isLetter)
    }

    private static func isLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
            && label.allSatisfy { ($0.isLetter || $0.isNumber || $0 == "-") && $0.isASCII }
    }

    /// The word before "@" when it can start an address: letters, digits,
    /// "." "_" "-" "+", with no punctuation after it.
    private static func localPart(_ word: String) -> String? {
        // "Type an at sign example.com": a function word is not a mailbox.
        guard !["a", "an", "the", "to", "at", "is", "in", "on", "of", "and", "or", "type", "use", "add"].contains(word.lowercased()),
              let first = word.first, let last = word.last,
              first.isLetter || first.isNumber, last.isLetter || last.isNumber,
              word.allSatisfy({ ($0.isLetter || $0.isNumber || "._-+".contains($0)) && $0.isASCII }) else { return nil }
        return word
    }

    private static func withoutClosingMarks(_ word: String) -> String {
        String(word.reversed().drop { closingMarks.contains($0) }.reversed())
    }

    /// Lowercased, without opening marks or trailing punctuation.
    private static func bare(_ word: String) -> String {
        var trimmed = Substring(word)
        while let first = trimmed.first, openingMarks.contains(first) { trimmed = trimmed.dropFirst() }
        while let last = trimmed.last, closingMarks.contains(last) { trimmed = trimmed.dropLast() }
        return trimmed.lowercased()
    }
}
