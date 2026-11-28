import Foundation

/// Strips the wrappers a model sometimes puts around its answer.
public enum ValidationGate {
    /// Strips model artifacts that are not failures: code fences, "CLEAN:"/"Transcript:"
    /// labels, wrapping quotes.
    public static func stripArtifacts(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```[a-z]*\n?", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "```", with: "")
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["CLEAN:", "Clean:", "Transcript:", "TRANSCRIPT:"] where s.hasPrefix(label) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.count > 1, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// The written text without a start that repeats the end of the text
    /// already before the cursor ("[7] ", "3. ", "Hi Priya, "), when the
    /// speaker did not say it: the field already holds it, so inserting it
    /// would double it. A start the transcript also has is a spoken repeat
    /// and stays. MEASURED 2026-11-28 (eval/dictation/echo.py, 30 cases × 3):
    /// GPT-6 Luna repeated a line marker in 5 of 90 dictations, 1 of 90 with
    /// the FIELD rule against it; this drops each of those and changed no
    /// other output of 270 (0 of 99 inserted on the final 33-case set).
    public static func droppingEcho(_ text: String, before: String, transcript: String) -> String {
        let tail = String(before.trimmingCharacters(in: .whitespacesAndNewlines).suffix(80))
        let lastLine = tail.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        for length in stride(from: min(tail.count, text.count), through: 1, by: -1) {
            let ending = tail.suffix(length), start = text.prefix(length)
            guard start.compare(ending, options: .caseInsensitive) == .orderedSame,
                  ending.startIndex == tail.startIndex || tail[tail.index(before: ending.startIndex)].isWhitespace,
                  start.endIndex == text.endIndex || text[start.endIndex].isWhitespace else { continue }
            // Conservative: a marker or label ("[7]", "3.", "-", "Today:"),
            // a name with its comma, or several words. A lone word or a
            // plain number ("2024") could be the writer's own.
            let repeated = words(String(start))
            let marked = start.contains { $0.isPunctuation || $0.isSymbol }
            guard (marked && (length > 1 || String(ending) == lastLine)) || repeated.count > 1,
                  !spoken(repeated, in: transcript) else { return text }
            let rest = text[start.endIndex...].drop { $0.isWhitespace }
            return rest.isEmpty ? text : String(rest)
        }
        return text
    }

    /// The words open the transcript, after any fillers ("so um hi Priya").
    /// A number counts as spoken when the transcript opens with any number,
    /// since the writer turns "three" into "3".
    private static func spoken(_ repeated: [String], in transcript: String) -> Bool {
        guard !repeated.isEmpty else { return false }
        let heard = words(transcript).prefix(repeated.count + 4)
        if heard.indices.contains(where: { heard[$0...].starts(with: repeated) }) { return true }
        let isNumber = { (word: String) in word.allSatisfy(\.isNumber) || numberWords.contains(word) }
        return repeated.contains(where: isNumber) && heard.contains(where: isNumber)
    }

    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "first", "second", "third",
    ]

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
