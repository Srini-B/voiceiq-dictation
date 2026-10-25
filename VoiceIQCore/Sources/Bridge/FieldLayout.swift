import Foundation

/// Where a dictation lands relative to the lines around the cursor. A list
/// item goes on its own line, spaced like the list it joins; a paragraph that
/// follows a finished list goes after a blank line; anything that continues
/// the line before it gets a space. The writing model shapes the text; this
/// decides the gap, so it holds on every insert path whatever the model did.
enum FieldLayout {
    enum Line: Equatable {
        case listItem, quote, tableRow, heading, prose, blank
    }

    static func kind(of line: Substring) -> Line {
        let text = line.drop { $0 == " " || $0 == "\t" }
        guard let first = text.first else { return .blank }
        switch first {
        case ">": return .quote
        case "|": return .tableRow
        case "#":
            let hashes = text.prefix { $0 == "#" }.count
            return hashes <= 6 && text.dropFirst(hashes).first == " " ? .heading : .prose
        case "-", "*", "•", "+", "–":
            return text.dropFirst().first == " " ? .listItem : .prose
        default:
            return isOrderedMarker(text) ? .listItem : .prose
        }
    }

    /// "3. ", "12) ", "a) ", "B. ".
    private static func isOrderedMarker(_ text: Substring) -> Bool {
        let digits = text.prefix { $0.isASCII && $0.isNumber }.count
        let label = digits > 0 ? digits : (text.first.map { $0.isASCII && $0.isLetter } == true ? 1 : 0)
        guard (1...3).contains(label) else { return false }
        let rest = text.dropFirst(label)
        return [".", ")"].contains(rest.first) && rest.dropFirst().first == " "
    }

    /// What goes between the text before the cursor and the dictation: "",
    /// " ", a line break, or a blank line.
    static func leadingGap(before: String, text: String) -> String {
        guard let previous = before.last, let next = text.first else { return "" }
        guard !previous.isWhitespace else { return "" }
        let beforeLines = lines(before)
        let textLines = lines(text)
        let last = beforeLines[beforeLines.count - 1]
        let lastKind = kind(of: last), firstKind = kind(of: textLines[0])

        // One line after an unfinished sentence ("Meet at" + "3. Then we
        // go home") is the sentence going on, whatever its first characters.
        let continuesSentence = lastKind == .prose && !endsSentence(last) && previous != ":" && !text.contains("\n")
        if firstKind != .prose, !continuesSentence {
            guard firstKind == lastKind else { return "\n\n" }
            return gap(firstKind, from: Array(beforeLines.reversed()))
                ?? gap(firstKind, from: textLines)
                ?? defaultGap(firstKind, item: last)
        }
        if lastKind == .heading { return "\n" }
        let startsAnew = next.isUppercase || next.isNumber
        if lastKind != .prose, startsAnew, lastKind != .listItem || endsSentence(last) { return "\n\n" }
        // A greeting or lead-in ("Hi Priya,") followed by paragraphs.
        if text.contains("\n\n"), startsAnew, [",", ":"].contains(previous) { return "\n\n" }
        return SurroundingText.needsSpace(after: before, and: next) ? " " : ""
    }

    /// What goes between the dictation and the text after the cursor.
    static func trailingGap(before: String, text: String, after: String) -> String {
        guard let next = after.first, !next.isWhitespace, !text.isEmpty else { return "" }
        let textLines = lines(text)
        let last = textLines[textLines.count - 1]
        let lastKind = kind(of: last), nextKind = kind(of: lines(after)[0])

        if nextKind != .prose {
            if nextKind == lastKind {
                return gap(nextKind, from: Array(textLines.reversed()))
                    ?? gap(nextKind, from: lines(after))
                    ?? defaultGap(nextKind, item: last)
            }
            if lastKind != .prose || endsSentence(last) { return "\n\n" }
        }
        // The cursor sat at the start of a line, and the dictation is a whole
        // line or paragraph of its own: keep the break the field had there.
        let lineStart = before.reversed().prefix { $0 == " " || $0 == "\t" || $0.isNewline }
        if lineStart.contains(where: \.isNewline), !next.isLowercase, lastKind != .prose || endsSentence(last) {
            return lineStart.filter(\.isNewline).count >= 2 ? "\n\n" : "\n"
        }
        return SurroundingText.needsSpace(after: before + text, and: next) ? " " : ""
    }

    private static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The gap between `lines[0]`, an item of `kind`, and the nearest other
    /// item of that kind in `lines`; nil when no other item comes before
    /// something else.
    private static func gap(_ kind: Line, from lines: [Substring]) -> String? {
        var blanks = 0
        for line in lines.dropFirst() {
            switch self.kind(of: line) {
            case .blank: blanks += 1
            case kind: return blanks > 0 ? "\n\n" : "\n"
            default: return nil
            }
        }
        return nil
    }

    /// A list of sentences gets air between its items; a list of short
    /// phrases, a quote, or a table does not.
    private static func defaultGap(_ kind: Line, item: Substring) -> String {
        kind == .listItem && endsSentence(item) ? "\n\n" : "\n"
    }

    private static func endsSentence(_ line: Substring) -> Bool {
        let last = line.reversed().first { !$0.isWhitespace && !SurroundingText.closingQuotes.contains($0) }
        return last.map(SurroundingText.terminators.contains) ?? false
    }
}
