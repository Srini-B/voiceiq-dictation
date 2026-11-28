import Foundation

/// The email layout the writing rules ask for, made certain: a dictation that
/// opens with a greeting and a name ("Hi Priya,") and ends with a sign-off and
/// a name ("Thanks, Srini.") is greeting, blank line, body, blank line,
/// sign-off, and the name on the line under it.
/// MEASURED 2026-11-28 on the LLM Gateway: GPT-6 Luna laid out the eval's
/// email in 2 of 3 rounds with the rule and an example in the prompt, and
/// unseen one-paragraph emails in 1 of 12.
enum EmailLayout {
    /// The user's own writing rules decide layout when they speak of it
    /// ("Keep messages in a single paragraph"); the writer has followed them.
    static func apply(_ text: String, customRules: String = "") -> String {
        guard customRules.range(of: #"\b(paragraphs?|line ?breaks?|new ?lines?|single line|one line|one block|layout)\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = pattern.firstMatch(in: trimmed, range: range),
              let greeting = Range(match.range(at: 1), in: trimmed),
              let body = Range(match.range(at: 2), in: trimmed),
              let signOff = Range(match.range(at: 3), in: trimmed),
              let name = Range(match.range(at: 4), in: trimmed) else { return text }
        let middle = trimmed[body].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !middle.isEmpty else { return text }
        // "Please talk to Dr. Best, Dana." names Dr. Best; it is not signed "Best,".
        let titles: Set<Substring> = ["Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "St."]
        if let last = middle.split(separator: " ").last, titles.contains(last) { return text }
        // A body the writer started lowercase after "Hi Sam," starts a sentence
        // now. A first word with a capital inside it (iOS, eBay) or other
        // characters (user_id, config.json) is an identifier and keeps its spelling.
        let first = middle.prefix { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: ",;:!?."))
        let word = first.allSatisfy { $0.isLowercase || "'’-".contains($0) }
        let opened = word ? middle.prefix(1).uppercased() + middle.dropFirst() : middle
        // "Srini." ends a sentence; "Ana J." keeps its initial's period.
        var signed = String(trimmed[name])
        if signed.hasSuffix("."), (signed.split(separator: " ").last?.count ?? 0) > 2 { signed.removeLast() }
        return "\(trimmed[greeting])\n\n\(opened)\n\n\(trimmed[signOff]),\n\(signed)"
    }

    private static let name = #"\p{Lu}[\p{L}'’-]*\.?(?: \p{Lu}[\p{L}'’-]*\.?){0,2}"#
    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(pattern:
        #"^((?:Hi|Hey|Hello|Dear|Good morning|Good afternoon|Good evening) (?:"# + name + #"|team|all|everyone|folks|there),)"#
        + #"\s*([\s\S]+?[.!?]["”’)]*)\s*"#
        // A one-word closing is a sign-off only with its comma: "Best Buy." and
        // "Thanks All." are not "Best," signed "Buy".
        + #"((?:Thank you|Thanks again|Many thanks|Best regards|Kind regards|Warm regards|Talk soon|Take care)(?=,?\s)|(?:Thanks|Cheers|Best|Regards|Sincerely)(?=,))"#
        // "Best Regards." and "Thanks Again." are unsigned closings, not "Best," signed "Regards".
        + #",?\s+(?!(?i:regards|again|you|thanks|soon|care)\b)("# + name + #")\.?$"#)
}
