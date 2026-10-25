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
        // Spaces already typed after the last word stand in for a space, not
        // for a line break the layout needs.
        let field = String(before.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        guard let previous = field.last, !previous.isNewline, let next = text.first else { return "" }
        let beforeLines = lines(field)
        let textLines = lines(text)
        let last = beforeLines[beforeLines.count - 1]
        let lastKind = kind(of: last), firstKind = kind(of: textLines[0])

        if firstKind != .prose, text.contains("\n") || !continuesSentence(last, into: textLines[0]) {
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
        let rest = String(after.drop { $0 == " " || $0 == "\t" })
        guard let next = rest.first, !next.isNewline, !text.isEmpty else { return "" }
        let textLines = lines(text), afterLines = lines(rest)
        let last = textLines[textLines.count - 1]
        let lastKind = kind(of: last), nextKind = kind(of: afterLines[0])

        if nextKind != .prose, !continuesSentence(last, into: afterLines[0]) {
            guard nextKind == lastKind else { return "\n\n" }
            return gap(nextKind, from: Array(textLines.reversed()))
                ?? gap(nextKind, from: afterLines)
                ?? defaultGap(nextKind, item: last)
        }
        // The cursor sat at the start of a line, and the dictation is a whole
        // line or paragraph of its own: keep the break the field had there.
        let lineStart = before.reversed().prefix { $0 == " " || $0 == "\t" || $0.isNewline }
        if lineStart.contains(where: \.isNewline), !next.isLowercase, lastKind != .prose || endsSentence(last) {
            return lineStart.filter(\.isNewline).count >= 2 ? "\n\n" : "\n"
        }
        return SurroundingText.needsSpace(after: before + text, and: next) ? " " : ""
    }

    /// An unfinished sentence followed by a number or letter label goes on
    /// ("Meet at" + "3. Then we go home"); a bullet, quote, or table row never
    /// continues a sentence.
    private static func continuesSentence(_ prose: Substring, into line: Substring) -> Bool {
        kind(of: prose) == .prose && !endsSentence(prose) && !prose.hasSuffix(":")
            && isOrderedMarker(line.drop { $0 == " " || $0 == "\t" })
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
