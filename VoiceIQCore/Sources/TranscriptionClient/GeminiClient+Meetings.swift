import Foundation

/// A word or phrase with the request-local speaker label and its time inside
/// the audio that was sent.
public struct DiarizedWord: Equatable, Sendable {
    public var text: String
    public var speaker: String?
    public var start: Double?
    public var end: Double?
    public init(text: String, speaker: String?, start: Double? = nil, end: Double? = nil) {
        self.text = text; self.speaker = speaker; self.start = start; self.end = end
    }
}

public extension GeminiClient {
    /// Speaker-labelled, timed transcription through Google's own endpoint.
    /// Labels are per request ("spk:0"); `SpeakerLinker` maps them.
    func transcribeSpeakers(audio: Data, model: String, endpoint: URL, deadline: TimeInterval) async throws -> [DiarizedWord] {
        // `timestamp_granularities` is required in practice: with `diarization_mode`
        // alone the API returned no word_info annotations and a single text block
        // whose speaker turns were concatenated without spaces (verified 2026-09-26).
        let body: [String: Any] = [
            "model": model,
            "input": [["type": "audio", "mime_type": "audio/flac", "data": audio.base64EncodedString()]],
            "generation_config": ["transcription_config": [
                "mode": ["type": "verbatim", "diarization_mode": "speaker", "timestamp_granularities": ["word"]]
            ]],
        ]
        let data = try await post(path: "v1beta/interactions",
                                  body: try JSONSerialization.data(withJSONObject: body), endpoint: endpoint,
                                  deadline: deadline, modelLabel: model, modelIsInPath: false,
                                  stage: .meetingTranscribe)
        return try Self.parseDiarizedWords(data)
    }

    /// Notes JSON for a prompt built by `MeetingNotesPrompt`.
    func meetingNotesJSON(prompt: String, model: String, endpoint: URL, deadline: TimeInterval) async throws -> String {
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": Self.notesSchema,
                "thinkingConfig": ["thinkingLevel": "low"],
            ],
        ]
        return try await generateContent(body: body, model: model, endpoint: endpoint, deadline: deadline,
                                         stage: .meetingSummary)
    }

    /// The shape `MeetingNotesPrompt.rules` asks for, enforced by the API.
    /// MEASURED 2026-11-26: with JSON mode alone gemini-3.8-flash wrote stray
    /// text inside the object (`"…Wednesday." his? wait, strictly no unneeded
    /// text]`) in 5 of about 40 replies, and each cost a second notes request.
    /// `propertyOrdering` keeps the glossary first, so it is written before the notes use it.
    static var notesSchema: [String: Any] {
        let text: [String: Any] = ["type": "STRING"]
        let maybe: [String: Any] = ["type": "STRING", "nullable": true]
        let texts: [String: Any] = ["type": "ARRAY", "items": text]
        func object(_ fields: [(String, [String: Any])], required: [String]) -> [String: Any] {
            ["type": "OBJECT", "properties": Dictionary(uniqueKeysWithValues: fields),
             "propertyOrdering": fields.map(\.0), "required": required]
        }
        func list(_ item: [String: Any]) -> [String: Any] { ["type": "ARRAY", "items": item] }
        return object([
            ("glossary", list(object([("term", text), ("heard", texts)], required: ["term", "heard"]))),
            ("type", text), ("title", text), ("summary", text),
            ("sections", list(object([("title", text), ("items", texts)], required: ["title", "items"]))),
            ("decisions", texts),
            ("actions", list(object([("text", text), ("owner", maybe), ("deadline", maybe)], required: ["text"]))),
            ("notes", texts),
            ("speakers", list(object([("label", text), ("name", maybe), ("evidence", maybe)], required: ["label"]))),
            ("participants", texts),
        ], required: ["type", "title", "summary", "decisions", "actions", "notes"])
    }

    /// The notes for a prompt from `MeetingNotesPrompt`, asked once more when
    /// the reply is not notes JSON. MEASURED 2026-11-26: across 14 notes
    /// requests on the evaluator's meetings, gemini-3.8-flash twice wrote
    /// JSON the decoder refused (text after the object, and a badly formed
    /// object), and each of those meetings ended without notes.
    /// Notes with no action items for a transcript that holds commitments are
    /// asked for once more with those lines quoted
    /// (`MeetingNotesPrompt.missingActions`).
    func meetingNotes(prompt: String, transcript: [TranscriptSegment], model: String, endpoint: URL,
                      deadline: TimeInterval) async throws -> MeetingNotes {
        let ask = { (prompt: String) in
            do {
                return try MeetingNotesPrompt.parse(try await self.meetingNotesJSON(prompt: prompt, model: model, endpoint: endpoint, deadline: deadline))
            } catch let error where error is DecodingError || (error as NSError).domain == NSCocoaErrorDomain {
                Log.transcription.info("notes reply was not notes JSON; asking again")
                return try MeetingNotesPrompt.parse(try await self.meetingNotesJSON(prompt: prompt, model: model, endpoint: endpoint, deadline: deadline))
            }
        }
        let notes = try await ask(prompt)
        guard let missing = MeetingNotesPrompt.missingActions(notes, transcript: transcript) else { return notes }
        Log.transcription.info("notes had no action items for a transcript with commitments; asking again")
        guard let again = try? await ask(prompt + missing), !again.actions.isEmpty else { return notes }
        return again
    }

    static func parseDiarizedWords(_ data: Data) throws -> [DiarizedWord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        let status = json["status"] as? String ?? "missing"
        guard status == "completed" else { throw mapInteractionStatus(status, json: json) }
        let content = (json["steps"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "model_output" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "text" }
        let words = content.flatMap { item -> [DiarizedWord] in
            (item["annotations"] as? [[String: Any]] ?? []).compactMap { annotation in
                guard annotation["type"] as? String == "word_info", let text = annotation["text"] as? String else { return nil }
                return DiarizedWord(text: text, speaker: annotation["speaker"] as? String,
                                    start: seconds(annotation["start_offset"]), end: seconds(annotation["end_offset"]))
            }
        }
        if !words.isEmpty { return words }
        let fallback = content.compactMap { $0["text"] as? String }.joined()
        return fallback.isEmpty ? [] : [DiarizedWord(text: fallback, speaker: nil)]
    }

    /// "12.340s" → 12.34
    static func seconds(_ value: Any?) -> Double? {
        guard let string = value as? String else { return value as? Double }
        return Double(string.hasSuffix("s") ? String(string.dropLast()) : string)
    }

    static func stripFences(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: #"^```(?:json)?\s*|\s*```$"#, with: "", options: .regularExpression)
        }
        return cleaned
    }
}
