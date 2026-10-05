import Foundation

/// Removes standalone hesitation sounds from a verbatim transcript.
///
/// Only for text that reaches the user WITHOUT the writing model: the cleanup
/// call failed or its answer was rejected. A verbatim transcript keeps every
/// "uh" it hears ("check on, uh, development branch"), and on those paths
/// nothing else would remove them. Deliberately narrow: only sounds that are never a
/// word in a language the app supports. "er" (German "he"), "ah", "eh", "hmm"
/// and "like" stay, because each carries meaning somewhere.
public enum FillerStripper {
    private static let fillers = #"(?:u+h+|u+m+|u+h+m+|e+r+m+|ä+h+m*|euh)"#

    /// A filler with the commas the recognizer put around it, so
    /// "on, uh, development" becomes "on development".
    private static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?:,[ \t]*)?(?<![\p{L}\p{N}'’‘"“”-])"# + fillers + #"(?![\p{L}\p{N}'’‘"“”-])(?:[ \t]*,)?"#,
        options: [.caseInsensitive]
    )

    public static func strip(_ text: String) -> String {
        let ns = text as NSString
        let matches = fillerPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        // A filler that opened a sentence leaves a marker so the word after it
        // can take the capital: "Uh, so we ship" → "So we ship".
        var out = ""
        var cursor = 0
        for match in matches {
            let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += before
            let opensSentence = ns.character(at: match.range.location) != 0x2C // ","
                && (out.last { !$0.isWhitespace || $0.isNewline }.map { ".!?\n".contains($0) } ?? true)
            out += opensSentence ? "\(marker) " : " "
            cursor = match.range.location + match.range.length
        }
        out = capitalizeAfterMarkers(out + ns.substring(from: cursor))
        // Tidy what the removal leaves: doubled spaces, a space before
        // punctuation, punctuation left at the start of a line or sentence.
        let tidy: [(String, String)] = [
            (#"[ \t]{2,}"#, " "),
            (#"[ \t]+([.,;:!?])"#, "$1"),
            (#"(^|\n)[ \t]*[,.;:]+[ \t]*"#, "$1"),
            (#"([.!?])[ \t]*[,.;:]+(?=\s|$)"#, "$1"),
            (#"(^|\n)[ \t]+"#, "$1"),
            (#"[ \t]+($|\n)"#, "$1"),
        ]
        for (pattern, template) in tidy {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    private static let marker: Character = "\u{1}"

    private static func capitalizeAfterMarkers(_ text: String) -> String {
        var result = ""
        var pending = false
        for character in text {
            if character == marker { pending = true; continue }
            if pending, character.isLetter || character.isNumber {
                result += character.uppercased()
                pending = false
            } else {
                result.append(character)
            }
        }
        return result
    }
}
