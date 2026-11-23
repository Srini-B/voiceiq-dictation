import Foundation

/// The notes request for the on-device writer (LFM3-Omni-2B). The Gemini
/// rulebook is too long for a 2B model, so this asks for the core of the
/// notes: title, summary, decisions, action items and key points, in a fixed
/// JSON shape the grammar enforces. The dictionary and the user's writing
/// rules come from the same context as Gemini's.
extension MeetingNotesPrompt {
    static let onDeviceAnswerTokens = 900

    /// Prompt plus answer. iPhones keep the context smaller: its memory grows
    /// with every token.
    static var onDeviceContext: Int {
        #if os(iOS)
        return 16_384
        #else
        return 32_768
        #endif
    }

    static let onDeviceSystem = """
    You write meeting notes from a transcript. Answer with one JSON object:
    "title": a short title of at most 8 words naming what the meeting was about,
    "summary": two to four sentences on what was discussed and concluded,
    "decisions": each decision the meeting made, one sentence each,
    "actions": each task someone agreed to do, with "owner" (who will do it) and "deadline" (when, as said) or null when not said,
    "notes": other key points, facts and open questions, one sentence each.
    Use only what the transcript says. Never invent names, dates, numbers or facts. Use a speaker's name only when the transcript or the names list gives it; otherwise use the speaker label. Use empty lists when there is nothing. Write in the transcript's language.
    """

    /// The context, the user's dictionary and rules, and the transcript. A
    /// transcript longer than the context fits keeps its start and end, with
    /// the middle cut, and says so.
    static func onDeviceUser(transcript: [TranscriptSegment], context: Context) -> String {
        let names = context.labels
        let lines = transcript.map { segment in
            let time = segment.start.map { "[\(clock($0))] " } ?? ""
            return "\(time)\(label(segment.speaker, names)): \(segment.text)"
        }
        let date = context.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
        let known = names.values.filter { !$0.isEmpty }.sorted()
        var parts = [
            "Meeting: \(date), \(Int((context.durationSeconds / 60).rounded())) minutes, app: \(context.app ?? "unknown").",
            "Names: \(known.isEmpty ? "none known" : known.joined(separator: ", ")).",
        ]
        let references = userReferences(context).trimmingCharacters(in: .whitespacesAndNewlines)
        if !references.isEmpty { parts.append(String(references.prefix(4_000))) }
        // About three characters a token, with room for the rest of the prompt.
        let budget = (onDeviceContext - onDeviceAnswerTokens - 1_500) * 3
        parts.append("<transcript>\n\(fitted(lines, characters: budget))\n</transcript>")
        return parts.joined(separator: "\n\n")
    }

    static func fitted(_ turns: [String], characters budget: Int) -> String {
        let all = turns.joined(separator: "\n")
        guard all.count > budget else { return all }
        // A long uninterrupted turn is cut into pieces, so one turn larger
        // than the budget cannot leave nothing to keep.
        let size = max(200, budget / 8)
        let lines = turns.flatMap { turn in
            stride(from: 0, to: turn.count, by: size).map { String(turn.dropFirst($0).prefix(size)) }
        }
        var head: [String] = [], tail: [String] = [], used = 0
        var low = 0, high = lines.count - 1
        while low <= high {
            let next = head.count <= tail.count ? lines[low] : lines[high]
            guard used + next.count + 1 <= budget else { break }
            used += next.count + 1
            if head.count <= tail.count { head.append(next); low += 1 } else { tail.insert(next, at: 0); high -= 1 }
        }
        return (head + ["[… the middle of the meeting is left out: too long to write notes on this device …]"] + tail)
            .joined(separator: "\n")
    }

    static let onDeviceGrammar = #"""
    root ::= "{" ws "\"title\"" ws ":" ws string "," ws "\"summary\"" ws ":" ws string "," ws "\"decisions\"" ws ":" ws strings "," ws "\"actions\"" ws ":" ws actions "," ws "\"notes\"" ws ":" ws strings ws "}"
    strings ::= "[" ws ( string ( "," ws string )* )? ws "]"
    actions ::= "[" ws ( action ( "," ws action )* )? ws "]"
    action ::= "{" ws "\"text\"" ws ":" ws string "," ws "\"owner\"" ws ":" ws nullable "," ws "\"deadline\"" ws ":" ws nullable ws "}"
    nullable ::= string | "null"
    string ::= "\"" ( [^"\\\x7F\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F]{4} ) )* "\""
    ws ::= [ \t\n]{0,8}
    """#
}
