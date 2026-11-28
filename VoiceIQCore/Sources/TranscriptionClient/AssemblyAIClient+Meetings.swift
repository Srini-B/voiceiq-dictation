import Foundation

/// A word with the request-local speaker label and its time inside the audio
/// that was sent.
public struct DiarizedWord: Equatable, Sendable {
    public var text: String
    public var speaker: String?
    public var start: Double?
    public var end: Double?
    public init(text: String, speaker: String?, start: Double? = nil, end: Double? = nil) {
        self.text = text; self.speaker = speaker; self.start = start; self.end = end
    }
}

public extension AssemblyAIClient {
    /// Word-timed words of a meeting track from pre-recorded STT-3.7, with
    /// per-request speaker labels ("A", "B") when `speakerLabels` is set;
    /// `SpeakerLinker` maps them. The language is detected, and Universal-2
    /// takes languages STT-3.7 lacks.
    func transcribeSpeakers(audio: Data, speakerLabels: Bool, deadline: TimeInterval) async throws -> [DiarizedWord] {
        let transcript = try await transcribe(
            audio: audio, request: TranscriptRequest(speakerLabels: speakerLabels),
            deadline: deadline, stage: .meetingTranscribe)
        return transcript.words.map { DiarizedWord(text: $0.text, speaker: $0.speaker, start: $0.start, end: $0.end) }
    }

    /// Notes JSON for a prompt built by `MeetingNotesPrompt`.
    func meetingNotesJSON(prompt: String, model: String, deadline: TimeInterval) async throws -> String {
        try await complete(messages: [["role": "user", "content": prompt]], model: model,
                           schema: ("meeting_notes", Self.notesSchema), deadline: deadline, stage: .meetingSummary)
    }

    /// The shape `MeetingNotesPrompt.rules` asks for, enforced by the API.
    /// MEASURED 2026-11-26: with JSON mode alone gemini-3.8-flash wrote stray
    /// text inside the object in 5 of about 40 replies, and each cost a
    /// second notes request. Properties are listed glossary first, so it is
    /// written before the notes use it.
    static var notesSchema: [String: Any] {
        let text: [String: Any] = ["type": "string"]
        let maybe: [String: Any] = ["type": ["string", "null"]]
        let texts: [String: Any] = ["type": "array", "items": text]
        // Every key is required (strict structured output asks for it, and a
        // skipped glossary or speakers list loses spellings and names). Empty
        // arrays and nulls stay allowed.
        func object(_ fields: [(String, [String: Any])]) -> [String: Any] {
            ["type": "object", "properties": Dictionary(uniqueKeysWithValues: fields),
             "required": fields.map(\.0), "additionalProperties": false]
        }
        func list(_ item: [String: Any]) -> [String: Any] { ["type": "array", "items": item] }
        return object([
            ("glossary", list(object([("term", text), ("heard", texts)]))),
            ("type", ["type": "string", "enum": MeetingKind.allCases.map(\.rawValue)] as [String: Any]), ("title", text), ("summary", text),
            ("sections", list(object([("title", text), ("items", texts)]))),
            ("decisions", texts),
            ("actions", list(object([("text", text), ("owner", maybe), ("deadline", maybe)]))),
            ("notes", texts),
            ("speakers", list(object([("label", text), ("name", maybe), ("evidence", maybe)]))),
            ("participants", texts),
        ])
    }

    /// The notes for a prompt from `MeetingNotesPrompt`, asked once more when
    /// the reply is not notes JSON. MEASURED 2026-11-26: across 14 notes
    /// requests, gemini-3.8-flash twice wrote JSON the decoder refused, and
    /// each of those meetings ended without notes.
    /// Notes with no action items for a transcript that holds commitments are
    /// asked for once more with those lines quoted
    /// (`MeetingNotesPrompt.missingActions`).
    func meetingNotes(prompt: String, transcript: [TranscriptSegment], model: String,
                      deadline: TimeInterval) async throws -> MeetingNotes {
        let ask = { (prompt: String) in
            do {
                return try MeetingNotesPrompt.parse(try await self.meetingNotesJSON(prompt: prompt, model: model, deadline: deadline))
            } catch let error where error is DecodingError || (error as NSError).domain == NSCocoaErrorDomain {
                Log.transcription.info("notes reply was not notes JSON; asking again")
                return try MeetingNotesPrompt.parse(try await self.meetingNotesJSON(prompt: prompt, model: model, deadline: deadline))
            }
        }
        let notes = try await ask(prompt)
        guard let missing = MeetingNotesPrompt.missingActions(notes, transcript: transcript) else { return notes }
        Log.transcription.info("notes had no action items for a transcript with commitments; asking again")
        guard let again = try? await ask(prompt + missing), !again.actions.isEmpty else { return notes }
        return again
    }

    static func stripFences(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: #"^```(?:json)?\s*|\s*```$"#, with: "", options: .regularExpression)
        }
        return cleaned
    }
}
