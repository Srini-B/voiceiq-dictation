import Foundation

/// Claude + Nemotron's models for each role: NVIDIA Nemotron 3.5 Transcribe on
/// DeepInfra hears every recording (dictation and meetings), Claude Haiku 5.5
/// writes (cleanup, Ask Anything, Translate, meeting notes), and Claude Sonnet
/// 5.5 drives agent mode, which clicks by screenshot pixel and needs the
/// stronger model.
public struct AnthropicConfig: Sendable, Equatable {
    public var transcribeModel = "nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B"
    public var writingModel = "claude-haiku-5-5"
    public var agentModel = "claude-sonnet-5-5"

    public init() {}
}

/// Anthropic's Messages API and DeepInfra's OpenAI-compatible speech API.
///
/// Probed 2026-10-29 with real keys:
///  - DeepInfra `/audio/transcriptions` takes the app's FLAC as is, uses
///    `prompt` as context (a dictionary word came back spelled as given), and
///    with `verbose_json` returns word timestamps and the audio `duration`.
///  - It has no speaker labels: the model card's `<spk:N>` instruction, sent
///    as `prompt`, came back as plain text, and DeepInfra does not serve the
///    model on chat completions (404). Meetings label words by the track they
///    were heard on instead (`MeetingTranscriber`).
extension GeminiClient {
    static let anthropicEndpoint = URL(string: "https://api.anthropic.com/v1")!
    static let deepInfraEndpoint = URL(string: "https://api.deepinfra.com/v1/openai")!

    /// Dictation: the transcript text. The dictionary rides along as `prompt`.
    func deepInfraTranscribe(audio: Data, mimeType: String = "audio/flac", vocabulary: [String],
                             deadline: TimeInterval) async throws -> String {
        let data = try await deepInfraTranscription(audio: audio, mimeType: mimeType, vocabulary: vocabulary,
                                                    words: false, deadline: deadline, stage: .transcribe)
        return try Self.extractTranscriptText(from: data)
    }

    /// Meetings: timed words with no speaker; the caller labels them.
    func deepInfraWords(audio: Data, deadline: TimeInterval) async throws -> [DiarizedWord] {
        let data = try await deepInfraTranscription(audio: audio, mimeType: "audio/flac", vocabulary: [],
                                                    words: true, deadline: deadline, stage: .meetingTranscribe)
        return try Self.parseDeepInfraWords(data)
    }

    private func deepInfraTranscription(audio: Data, mimeType: String, vocabulary: [String], words: Bool,
                                        deadline: TimeInterval, stage: UsageStage) async throws -> Data {
        let model = AnthropicConfig().transcribeModel
        var form = MultipartForm()
        form.field("model", model)
        form.file("file", filename: "audio.\(Self.audioFormat(mimeType))", mimeType: mimeType, data: audio)
        // verbose_json carries `duration`, which is what DeepInfra bills.
        form.field("response_format", "verbose_json")
        if words { form.field("timestamp_granularities[]", "word") }
        if !vocabulary.isEmpty { form.field("prompt", vocabulary.joined(separator: ", ")) }
        return try await post(path: "audio/transcriptions", body: form.body, endpoint: Self.deepInfraEndpoint,
                              deadline: deadline, modelLabel: model, modelIsInPath: false, stage: stage,
                              via: .anthropic, extraHeaders: ["Content-Type": form.contentType])
    }

    static func parseDeepInfraWords(_ data: Data) throws -> [DiarizedWord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        let words = (json["words"] as? [[String: Any]] ?? []).compactMap { word -> DiarizedWord? in
            guard let text = word["word"] as? String else { return nil }
            return DiarizedWord(text: text, speaker: nil, start: (word["start"] as? NSNumber)?.doubleValue,
                                end: (word["end"] as? NSNumber)?.doubleValue)
        }
        if !words.isEmpty { return words }
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [DiarizedWord(text: text, speaker: nil)]
    }

    /// One Claude reply. With screenshots, the rules go in `system` and the
    /// user turn holds the labelled screenshots and the dictation, the layout
    /// `openAIMessages` measured as the one that keeps screen text out.
    func anthropicMessage(prompt: String, images: [Data] = [], deadline: TimeInterval, stage: UsageStage,
                          maxTokens: Int = 8192) async throws -> String {
        let model = AnthropicConfig().writingModel
        // Claude 5.5 rejects `temperature` ("deprecated for this model", probed 2026-10-29).
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens]
        let imageParts: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
        }
        if !images.isEmpty, let split = Self.dictationSplit(prompt) {
            let label = images.count == 1 ? "Screenshot" : "Screenshots"
            body["system"] = String(prompt[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            body["messages"] = [["role": "user", "content":
                [["type": "text", "text": "\(label) of the user's screen while dictating (reference only, not part of the dictation):"]]
                + imageParts + [["type": "text", "text": String(prompt[split...])]]]]
        } else {
            body["messages"] = [["role": "user", "content": [["type": "text", "text": prompt]] + imageParts]]
        }
        let data = try await post(path: "messages", body: try JSONSerialization.data(withJSONObject: body),
                                  endpoint: Self.anthropicEndpoint, deadline: deadline, modelLabel: model,
                                  stage: stage, via: .anthropic)
        return try Self.extractAnthropicText(from: data)
    }

    /// `GET /v1/models`: 200 for a usable key, 401 for a bad one.
    public static func validateAnthropicKey(_ key: String) async -> KeyCheck {
        var request = URLRequest(url: anthropicEndpoint.appendingPathComponent("models"))
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return await check(request)
    }

    /// `GET /v1/me`, which needs a key; DeepInfra's model list answers 200 without one.
    public static func validateDeepInfraKey(_ key: String) async -> KeyCheck {
        var request = URLRequest(url: URL(string: "https://api.deepinfra.com/v1/me")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await check(request)
    }

    private static func check(_ request: URLRequest) async -> KeyCheck {
        var request = request
        request.timeoutInterval = 10
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200: return .valid
        case 500...599: return .unreachable
        default: return .rejected(errorMessage(from: data))
        }
    }

    static func extractAnthropicText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        if json["stop_reason"] as? String == "refusal" { throw TranscriptionError.safetyBlocked }
        let content = json["content"] as? [[String: Any]] ?? []
        return content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }
}
