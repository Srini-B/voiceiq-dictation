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
                  !marker.ambiguous || endsAmbiguousAddress(tokens, next: next, domain: domain) else {
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
            // opens the sentence or a clause, or follows a word that introduces an address.
            guard !local.isEmpty, !marker.ambiguous || introducesAddress(tokens, before: start, after: lastAddress) else {
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

    /// Whether the domain after "at the rate" (from `next`) ends an address.
    /// "at the rate" is plain English before a written domain ("grew at the rate
    /// Amazon.com"): only a spoken one ("company dot co dot in") or one the model
    /// glued to "rate" ("rategmail.com") is an address, and only where the
    /// sentence ends, at a courtesy after a comma ("…, please."), or before "and"
    /// and another address. "grew at the rate Amazon dot com predicted" stays.
    private static func endsAmbiguousAddress(_ tokens: [Token], next: Int,
                                             domain: (labels: [String], end: Int, trailing: String)) -> Bool {
        guard domain.end > next || tokens[next].glued else { return false }
        if domain.end == tokens.count - 1 || domain.trailing.contains(where: { ".!?".contains($0) }) { return true }
        let rest = domain.end + 1
        if domain.trailing == "," {
            let end = tokens[rest...].firstIndex { $0.word.last.map { ".!?".contains($0) } ?? false } ?? tokens.count - 1
            return [["please"], ["thanks"], ["thank", "you"], ["cheers"]].contains(tokens[rest...end].map { bare($0.word) })
        }
        return domain.trailing.isEmpty && ["and", "or"].contains(tokens[rest].word.lowercased()) && addressFollows(tokens, at: rest + 1)
    }

    /// Whether an address said with a marker starts at `index`: "ravi at the rate gmail dot com".
    private static func addressFollows(_ tokens: [Token], at index: Int) -> Bool {
        var end = index
        guard tokens.indices.contains(end), localPart(tokens[end].word) != nil else { return false }
        while end + 2 < tokens.count, tokens[end + 1].word.lowercased() == "dot", localPart(tokens[end + 2].word) != nil { end += 2 }
        guard end + 1 < tokens.count, let marker = marker(tokens, at: end + 1),
              let domain = domain(tokens, from: marker.end + 1) else { return false }
        return !marker.ambiguous || endsAmbiguousAddress(tokens, next: marker.end + 1, domain: domain)
    }

    /// Words after which "at the rate" may close a mailbox: "My email is priya at
    /// the rate…", "Mail priya at the rate…", "Send it to priya at the rate…".
    private static let addressIntroductions: Set<String> = [
        "is", "was", "email", "e-mail", "mail", "to", "me", "cc", "bcc", "contact", "reach", "write", "ping", "from",
        "address", "id", "at", "on", "try", "use",
    ]

    /// Whether the mailbox starting at `start` may join "at the rate": it opens
    /// the sentence or a clause, follows a word from `addressIntroductions`, or
    /// follows "and" or "or" right after another address (`after`).
    private static func introducesAddress(_ tokens: [Token], before start: Int, after lastAddress: Int?) -> Bool {
        guard start > 0 else { return true }
        let previous = tokens[start - 1].word
        if let last = previous.last, ".!?,:;".contains(last) { return true }
        let word = bare(previous)
        if addressIntroductions.contains(word) { return true }
        return ["and", "or"].contains(word) && lastAddress == start - 2
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
