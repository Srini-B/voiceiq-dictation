import Foundation

/// The email layout the writing rules ask for, made certain: a dictation that
/// opens with a greeting and a name ("Hi Priya,") and ends with a sign-off and
/// a name ("Thanks, Srini.") is greeting, blank line, body, blank line,
/// sign-off, and the name on the line under it.
/// MEASURED 2026-11-28 on the LLM Gateway: GPT-6 Luna laid out the eval's
/// email in 2 of 3 rounds with the rule and an example in the prompt, and
/// unseen one-paragraph emails in 1 of 12.
enum EmailLayout {
    static func apply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = pattern.firstMatch(in: trimmed, range: range),
              let greeting = Range(match.range(at: 1), in: trimmed),
              let body = Range(match.range(at: 2), in: trimmed),
              let signOff = Range(match.range(at: 3), in: trimmed),
              let name = Range(match.range(at: 4), in: trimmed) else { return text }
        let middle = trimmed[body].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !middle.isEmpty else { return text }
        // A body the writer started lowercase after "Hi Sam," starts a sentence
        // now; a word with a capital inside it (iOS, eBay) keeps its spelling.
        let first = middle.prefix { !$0.isWhitespace && !$0.isPunctuation }
        let opened = first.allSatisfy(\.isLowercase) ? middle.prefix(1).uppercased() + middle.dropFirst() : middle
        // "Srini." ends a sentence; "Ana J." keeps its initial's period.
        var signed = String(trimmed[name])
        if signed.hasSuffix("."), (signed.split(separator: " ").last?.count ?? 0) > 2 { signed.removeLast() }
        return "\(trimmed[greeting])\n\n\(opened)\n\n\(trimmed[signOff]),\n\(signed)"
    }

    private static let name = #"\p{Lu}[\p{L}'’-]*\.?(?: \p{Lu}[\p{L}'’-]*\.?){0,2}"#
    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(pattern:
        #"^((?:Hi|Hey|Hello|Dear|Good morning|Good afternoon|Good evening) (?:"# + name + #"|team|all|everyone|folks|there),)"#
        + #"\s*([\s\S]+?[.!?]["”’)]*)\s*"#
        + #"(Thanks|Thank you|Thanks again|Many thanks|Cheers|Best|Best regards|Regards|Kind regards|Warm regards|Sincerely|Talk soon|Take care)"#
        + #",?\s+("# + name + #")\.?$"#)
}
