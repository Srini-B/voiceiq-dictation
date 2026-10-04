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
                                  stage: .meetingTranscribe, via: .gemini)
        return try Self.parseDiarizedWords(data)
    }

    /// The same through a gateway, where no transcription endpoint diarizes.
    /// VERIFIED 2026-09-27: OpenRouter's `/audio/transcriptions` for
    /// `google/gemini-3.5-transcribe` returns one untimed segment whatever
    /// options are passed, and Vercel's drops `word_info` too (Vercel community
    /// thread 48498). The flash model is sent each known speaker's clips as
    /// separate audio parts under their ids, then the window, and answers with
    /// those ids. MEASURED 2026-09-27: its timestamps drift too far for the
    /// overlap vote the native path uses, which split one person into two ids.
    func transcribeSpeakers(audio: Data, references: [(id: String, audio: Data)], model: String,
                            deadline: TimeInterval, via: ModelEndpoint) async throws -> [DiarizedWord] {
        var parts: [ChatPart] = []
        if references.isEmpty {
            parts.append(.text("Reference clips: none yet."))
        } else {
            parts.append(.text("Reference clips:"))
            for reference in references { parts += [.text("Reference \(reference.id):"), .flac(reference.audio)] }
        }
        parts += [.text("Window audio:"), .flac(audio)]
        let text = try await gatewayChat(prompt: Self.speakerTranscriptPrompt, model: model, deadline: deadline,
                                         stage: .meetingTranscribe, jsonSchema: Self.speakerTranscriptSchema,
                                         parts: parts, via: via)
        return try Self.parseSpeakerSegments(text)
    }

    /// Notes JSON for a prompt built by `MeetingNotesPrompt`.
    func meetingNotesJSON(prompt: String, model: String, endpoint: URL, deadline: TimeInterval,
                          via route: ModelRoute) async throws -> String {
        if writingSource() == .sarvam {
            return try await sarvamChat(prompt: prompt, deadline: deadline, stage: .meetingSummary, jsonObject: true)
        }
        switch (route.provider, route.gateway) {
        case (.gemini, .direct): break
        case (.openAI, .direct):
            return try await openAIChat(prompt: prompt, deadline: deadline, stage: .meetingSummary, jsonObject: true)
        default:
            return try await gatewayChat(prompt: prompt, model: writingModelID(model, route: route), provider: route.provider,
                                         deadline: deadline, stage: .meetingSummary, jsonObject: true, via: route.endpoint)
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "thinkingConfig": ["thinkingLevel": "low"],
            ],
        ]
        return try await generateContent(body: body, model: model, endpoint: endpoint, deadline: deadline,
                                         stage: .meetingSummary)
    }

    /// MEASURED 2026-09-27: asking the flash model to judge speakers "by voice
    /// (pitch, timbre, accent)" got `content_filter` every time. This wording
    /// passed.
    static let speakerTranscriptPrompt = """
    Transcribe this window of a recorded call and label who speaks.

    Speaker ids must stay the same across the whole call, which is processed in consecutive windows. Each reference clip is a person already identified earlier in the call, under a fixed id. When the same person talks in this window, use their id. Use a new id (the next unused one of s1, s2, s3, ...) only for a person who matches no reference. Never give two different people the same id, and never give one person two ids.

    Return ONLY JSON: {"segments":[{"speaker":"s1","start":0.0,"end":0.0,"text":""}]}
    - One segment per speaker turn, in time order. Start a new segment when the speaker changes or after a pause longer than one second.
    - "start" and "end": seconds from the start of the window audio, to one decimal place.
    - "text": exactly what is said, in the language and script spoken. Do not translate, correct, summarize, or add words. Leave out silence, music, and noise.
    """

    /// Strict schema, because the same request with `json_object` returned an
    /// unterminated string on a Tamil call (2026-09-27).
    static let speakerTranscriptSchema: [String: Any] = [
        "type": "object",
        "properties": ["segments": ["type": "array", "items": [
            "type": "object",
            "properties": ["speaker": ["type": "string"], "start": ["type": "number"],
                           "end": ["type": "number"], "text": ["type": "string"]],
            "required": ["speaker", "start", "end", "text"],
            "additionalProperties": false,
        ] as [String: Any]]],
        "required": ["segments"],
        "additionalProperties": false,
    ]

    static func parseSpeakerSegments(_ text: String) throws -> [DiarizedWord] {
        struct Segment: Decodable { var speaker: String; var start: Double; var end: Double; var text: String }
        struct Envelope: Decodable { var segments: [Segment] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(stripFences(text).utf8))
        return envelope.segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map {
            DiarizedWord(text: $0.text, speaker: $0.speaker, start: $0.start, end: $0.end)
        }
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
