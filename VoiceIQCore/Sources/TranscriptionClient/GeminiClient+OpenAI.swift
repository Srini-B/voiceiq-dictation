import Foundation

/// OpenAI's models for each role the app has. Defaults follow OpenAI's own
/// recommendations (2026-09): `gpt-transcribe` for recorded speech and
/// GPT-6 Luna for the writing rules, Ask Anything, Translate and meeting notes.
public struct OpenAIConfig: Sendable, Equatable {
    public var transcribeModel = "gpt-transcribe"
    public var writingModel = "gpt-6-luna"
    /// Meetings only. `gpt-transcribe` has no speaker labels.
    public var diarizeModel = "gpt-4o-transcribe-diarize"
    /// Dictation only: a second transcript for the writing model, which cannot
    /// hear the recording. A different model family errs in different places.
    public var secondOpinionModel = "whisper-1"

    public init() {}
}

/// OpenAI's own API. Each call picks the model for its role from
/// `OpenAIConfig` and ignores the Gemini model name the caller passes.
///
/// Probed 2026-09-28 with a real key:
///  - `/audio/transcriptions` takes the app's FLAC as is (FLAC is not in the
///    documented format list; the transcript was identical to WAV and M4A).
///  - GPT-6 Luna rejects `temperature: 0` (only the default is allowed) and
///    takes no audio at all: Chat Completions answers 400 for `input_audio`
///    (wav included), and the Responses API answers "Audio input is not
///    available". The writing model never hears the recording on this
///    provider; `secondOpinionTranscript` is what it gets instead.
///  - A keyword containing `<` fails the whole request with 400.
extension GeminiClient {
    static let openAIEndpoint = URL(string: "https://api.openai.com/v1")!

    func openAITranscribe(audio: Data, mimeType: String = "audio/flac", keywords: [String],
                          deadline: TimeInterval, model override: String? = nil) async throws -> String {
        let model = override ?? openAIConfig().transcribeModel
        var form = MultipartForm()
        form.field("model", model)
        form.file("file", filename: "audio.\(Self.audioFormat(mimeType))", mimeType: mimeType, data: audio)
        for keyword in Self.openAIKeywords(keywords) { form.field("keywords[]", keyword) }
        let data = try await post(path: "audio/transcriptions", body: form.body, endpoint: Self.openAIEndpoint,
                                  deadline: deadline, modelLabel: model, stage: .transcribe, via: .openAI,
                                  extraHeaders: ["Content-Type": form.contentType])
        return try Self.extractTranscriptText(from: data)
    }

    /// A transcript of the same recording by a different speech model, for
    /// the cleanup pass to check the primary transcript against. Only on
    /// OpenAI; nil on Gemini. No keywords: whisper-1 takes a free-text prompt
    /// instead, and SECOND is more useful when independent.
    public func secondOpinionTranscript(flacData: Data, deadline: TimeInterval) async throws -> String? {
        guard provider() == .openAI else { return nil }
        let text = try await openAITranscribe(audio: flacData, keywords: [], deadline: deadline,
                                              model: openAIConfig().secondOpinionModel)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openAIChat(prompt: String, images: [Data] = [], deadline: TimeInterval, stage: UsageStage,
                    jsonObject: Bool = false) async throws -> String {
        let model = openAIConfig().writingModel
        var body: [String: Any] = [
            "model": model,
            "messages": Self.openAIMessages(prompt: prompt, images: images, instructionRole: "developer"),
            "reasoning_effort": GeminiClient.openAIReasoningEffort,
        ]
        if jsonObject {
            body["response_format"] = ["type": "json_object"]
        }
        let data = try await post(path: "chat/completions", body: try JSONSerialization.data(withJSONObject: body),
                                  endpoint: Self.openAIEndpoint, deadline: deadline, modelLabel: model,
                                  stage: stage, via: .openAI)
        return try Self.extractChatMessage(from: data)
    }

    /// Speaker-labelled segments for a meeting window. Each reference is a
    /// known speaker's voice (2–10 s, at most four); segments in their voice
    /// come back labelled with their id, anyone else as "A", "B", ….
    /// Probed 2026-09-28: a FLAC data URL works as a reference.
    func openAIDiarize(audio: Data, references: [(id: String, audio: Data)],
                       deadline: TimeInterval) async throws -> [DiarizedWord] {
        let model = openAIConfig().diarizeModel
        var form = MultipartForm()
        form.field("model", model)
        form.field("response_format", "diarized_json")
        form.field("chunking_strategy", "auto")
        form.file("file", filename: "audio.flac", mimeType: "audio/flac", data: audio)
        for reference in references.prefix(Self.openAIMaxReferences) {
            form.field("known_speaker_names[]", reference.id)
            form.field("known_speaker_references[]", "data:audio/flac;base64,\(reference.audio.base64EncodedString())")
        }
        let data = try await post(path: "audio/transcriptions", body: form.body, endpoint: Self.openAIEndpoint,
                                  deadline: deadline, modelLabel: model, stage: .meetingTranscribe, via: .openAI,
                                  extraHeaders: ["Content-Type": form.contentType])
        return try Self.parseOpenAIDiarized(data)
    }

    /// MEASURED 2026-09-28 on three dictations with the full cleanup prompt:
    /// `none` took 1.4–2.5 s with no reasoning tokens; `low` took 1.9–4.7 s,
    /// spent up to 307 reasoning tokens, and turned a two-sentence dictation
    /// into a numbered list.
    static let openAIReasoningEffort = "none"

    /// Chat messages for an OpenAI writing model.
    ///
    /// With screenshots, the rules go in an instruction message and the user
    /// message carries only the labelled screenshots and the transcript.
    /// MEASURED 2026-09-28 on GPT-6 Luna with a screenshot of a TextEdit
    /// document full of earlier dictations: rules, transcript and image in one
    /// user message copied screen text into the answer in 3 of 9 runs (2 of 9
    /// with stricter wording); this layout in 0 of 29, and dictionary words
    /// visible on screen were still spelled right.
    static func openAIMessages(prompt: String, images: [Data], instructionRole: String) -> [[String: Any]] {
        let imageParts: [[String: Any]] = images.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]]
        }
        let dictation = prompt.range(of: PromptV1.fieldBeforeLabel, options: .backwards)
            ?? prompt.range(of: "SECOND: ", options: .backwards) ?? prompt.range(of: "RAW: ", options: .backwards)
        guard !images.isEmpty, let split = dictation else {
            return [["role": "user", "content": [["type": "text", "text": prompt]] + imageParts]]
        }
        let label = images.count == 1 ? "Screenshot" : "Screenshots"
        return [
            ["role": instructionRole, "content": String(prompt[..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)],
            ["role": "user", "content": [["type": "text", "text": "\(label) of the user's screen while dictating (reference only, not part of the dictation):"]]
                + imageParts + [["type": "text", "text": String(prompt[split.lowerBound...])]]],
        ]
    }

    static let openAIMaxReferences = 4
    static let openAIReferenceSeconds: ClosedRange<Double> = 2...10

    /// `GET /models` answers 200 for a usable key and 401 for a bad one.
    public func validateOpenAIKey() async -> KeyCheck {
        var request = URLRequest(url: Self.openAIEndpoint.appendingPathComponent("models"))
        request.timeoutInterval = 10
        applyAuth(&request, via: .openAI)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200: return .valid
        case 500...599: return .unreachable
        default: return .rejected(Self.errorMessage(from: data))
        }
    }

    // MARK: - Parsing

    static func audioFormat(_ mimeType: String) -> String {
        switch mimeType {
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/mp3", "audio/mpeg": return "mp3"
        case "audio/ogg": return "ogg"
        default: return "flac"
        }
    }

    /// `{"text": "...", ...}` from `/audio/transcriptions`. A silent clip is an
    /// empty string, never an error, matching the Gemini extractors.
    static func extractTranscriptText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        let text = json["text"] as? String ?? ""
        if text.isEmpty {
            Log.transcription.info("openai transcript empty; response keys: \(json.keys.sorted().joined(separator: ","), privacy: .public)")
        }
        return text
    }

    /// `choices[0].message.content`, which may be a string or an array of text
    /// parts. A `finish_reason` of `content_filter` is the safety block.
    static func extractChatMessage(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
            throw TranscriptionError.network("no_choices")
        }
        if let finish = first["finish_reason"] as? String, finish == "content_filter" {
            throw TranscriptionError.safetyBlocked
        }
        let message = first["message"] as? [String: Any] ?? [:]
        let parts = message["content"] as? [[String: Any]] ?? []
        let text = message["content"] as? String ?? parts.compactMap { $0["text"] as? String }.joined()
        if text.isEmpty {
            // Shape only, never content: which keys came back and why it stopped.
            let details = (json["usage"] as? [String: Any])?["completion_tokens_details"] as? [String: Any] ?? [:]
            Log.transcription.error("openai message empty: finish=\(first["finish_reason"] as? String ?? "nil", privacy: .public) message keys=\(message.keys.sorted().joined(separator: ","), privacy: .public) content type=\(String(describing: type(of: message["content"] as Any)), privacy: .public) reasoning tokens=\((details["reasoning_tokens"] as? NSNumber)?.intValue ?? -1, privacy: .public)")
        }
        return text
    }

    /// Keywords may not contain `<`, `>`, a carriage return or a line feed.
    static func openAIKeywords(_ terms: [String]) -> [String] {
        terms.map { term in
            term.replacingOccurrences(of: #"[<>\r\n]"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    static func parseOpenAIDiarized(_ data: Data) throws -> [DiarizedWord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        let segments = json["segments"] as? [[String: Any]] ?? []
        return segments.compactMap { segment in
            guard let text = (segment["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return DiarizedWord(text: text, speaker: segment["speaker"] as? String,
                                start: (segment["start"] as? NSNumber)?.doubleValue,
                                end: (segment["end"] as? NSNumber)?.doubleValue)
        }
    }
}

/// `multipart/form-data` for the audio endpoints.
struct MultipartForm {
    private let boundary = "voiceiq-\(UUID().uuidString)"
    private(set) var parts = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    var body: Data { parts + Data("--\(boundary)--\r\n".utf8) }

    mutating func field(_ name: String, _ value: String) {
        parts += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }

    mutating func file(_ name: String, filename: String, mimeType: String, data: Data) {
        parts += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8)
        parts += data
        parts += Data("\r\n".utf8)
    }
}
