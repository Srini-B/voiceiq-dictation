import Foundation

/// Claude's models for each role: Claude Sonnet 5.5 does all the writing:
/// cleanup, Ask Anything, Translate, meeting notes and agent mode. Claude has
/// no speech model, so with it recordings are transcribed on device. Haiku 5.5
/// wrote cleanup until 2026-10-30, when the user found its cleanups too weak.
public struct AnthropicConfig: Sendable, Equatable {
    public var writingModel = "claude-sonnet-5-5"
    public var notesModel = "claude-sonnet-5-5"
    public var agentModel = "claude-sonnet-5-5"

    public init() {}
}

/// Anthropic's Messages API.
extension GeminiClient {
    static let anthropicEndpoint = URL(string: "https://api.anthropic.com/v1")!

    /// One Claude reply. A cleanup prompt's rules go in `system` and the user
    /// turn holds the labelled screenshots and the dictation, the layout
    /// `openAIMessages` measured as the one that keeps screen text out.
    func anthropicMessage(prompt: String, images: [Data] = [], model: String = AnthropicConfig().writingModel,
                          deadline: TimeInterval, stage: UsageStage, maxTokens: Int = 8192) async throws -> String {
        // Claude 5.5 rejects `temperature` ("deprecated for this model", probed 2026-10-29).
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens]
        let imageParts: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
        }
        if let (system, dictation) = Self.anthropicCleanupSplit(prompt) {
            body["system"] = system
            let label = images.count == 1 ? "Screenshot" : "Screenshots"
            let shots: [[String: Any]] = images.isEmpty ? [] :
                [["type": "text", "text": "\(label) of the user's screen while dictating (reference only, not part of the dictation):"]] + imageParts
            body["messages"] = [["role": "user", "content": shots + [["type": "text", "text": dictation]]]]
        } else {
            body["messages"] = [["role": "user", "content": [["type": "text", "text": prompt]] + imageParts]]
        }
        let data = try await post(path: "messages", body: try JSONSerialization.data(withJSONObject: body),
                                  endpoint: Self.anthropicEndpoint, deadline: deadline, modelLabel: model,
                                  stage: stage, via: .anthropic)
        return try Self.extractAnthropicText(from: data)
    }

    /// A cleanup prompt as `system` blocks and the dictation. The rules up to
    /// `layoutReminder` are the same for every dictation until the user edits
    /// the dictionary or writing rules, so they carry the cache breakpoint;
    /// the field rules, reminder and PLACE line after it vary per dictation.
    /// The one-hour TTL lets dictations minutes apart share one write; it
    /// costs 2x input against 1.25x for five minutes, and a hit costs 0.05x
    /// on Sonnet 5.5. It beats no cache once about half of dictations land
    /// within the hour of the last one. On the 12.6k-token rules and the nine
    /// dictations of 2026-10-29 it costs about $0.11 on Sonnet, against $0.19
    /// with five minutes and $0.23 uncached.
    /// Nil for any other prompt, which goes as one user turn uncached.
    static func anthropicCleanupSplit(_ prompt: String) -> (system: [[String: Any]], dictation: String)? {
        guard let split = dictationSplit(prompt),
              let stable = prompt.range(of: PromptV1.layoutReminder)?.upperBound, stable <= split else { return nil }
        var system: [[String: Any]] = [["type": "text", "text": String(prompt[..<stable]),
                                        "cache_control": AgentCachePolicy.staticTTL]]
        let varying = prompt[stable..<split].trimmingCharacters(in: .whitespacesAndNewlines)
        if !varying.isEmpty { system.append(["type": "text", "text": varying]) }
        return (system, String(prompt[split...]))
    }

    /// `GET /v1/models`: 200 for a usable key, 401 for a bad one.
    public static func validateAnthropicKey(_ key: String) async -> KeyCheck {
        var request = URLRequest(url: anthropicEndpoint.appendingPathComponent("models"))
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
