import Foundation

/// Models and hosts. The writing model can be pinned in Settings → Advanced.
public struct AssemblyAIConfig: Sendable, Equatable {
    /// LLM Gateway model that writes a dictation by the writing rules, and
    /// meeting notes and chat.
    public var writingModel: String

    public init(writingModel: String = AssemblyAIConfig.defaultWritingModel) {
        self.writingModel = writingModel
    }

    /// GPT-6 Luna: chosen 2026-11-28 on the dictation eval (activities/2026-11-28-assemblyai.md).
    public static let defaultWritingModel = "gpt-6-luna"
    /// Pre-recorded transcription: STT-3.7 for its 32 languages, Universal-2 for the rest.
    public static let transcribeModel = "assemblyai-stt-3-7"
    public static let fallbackModel = "universal-2"
    public static let realtimeModel = "assemblyai-stt-3-7-realtime"

    static let api = URL(string: "https://api.assemblyai.com")!
    static let gateway = URL(string: "https://llm-gateway.assemblyai.com")!
    static let streaming = URL(string: "wss://streaming.assemblyai.com/v3/ws")!
}

/// List prices, USD, from assemblyai.com/pricing (updated 2026-11-10, read 2026-11-28).
/// Speech is billed per hour of audio (pre-recorded) or of open session (streaming).
public enum AssemblyAIPrices {
    public static let realtimePerHour = 0.30
    public static let stt37PerHour = 0.21
    public static let universal2PerHour = 0.15
    public static let diarizationPerHour = 0.02
}

/// The AssemblyAI API: pre-recorded transcription, the LLM Gateway, and key
/// checks. Realtime dictation streams through `RealtimeTranscription`.
public actor AssemblyAIClient {
    private let apiKey: @Sendable () -> String?

    public init(apiKey: @escaping @Sendable () -> String?) {
        self.apiKey = apiKey
    }

    // MARK: - LLM Gateway

    /// Writes a dictation: `prompt` carries the writing rules and the
    /// transcript, and the model answers `{"text": ...}`. Returns the text,
    /// or "" when the transcript held no speech.
    public func write(prompt: String, model: String, deadline: TimeInterval) async throws -> String {
        let reply = try await complete(
            messages: [["role": "user", "content": prompt]], model: model,
            schema: ("dictation", PromptV1.dictationSchema), deadline: deadline, stage: .cleanup)
        guard let text = PromptV1.dictationText(fromJSON: reply) else {
            Log.transcription.warning("dictation reply was not the JSON answer")
            throw TranscriptionError.network("malformed_answer")
        }
        if text.contains(PromptV1.noSpeechToken) { return "" }
        // A blank answer without the no-speech token is a writer failure, not
        // silence: the transcript goes in tidied instead.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.network("blank_answer")
        }
        return text
    }

    /// A conversation: `system`, then alternating user and assistant turns,
    /// ending on the user's. For meeting chat.
    public func chat(
        system: String, turns: [(user: String, model: String)], question: String,
        model: String, deadline: TimeInterval, stage: UsageStage
    ) async throws -> String {
        let history: [[String: Any]] = turns.flatMap { turn in
            [["role": "user", "content": turn.user], ["role": "assistant", "content": turn.model]]
        }
        let messages = [["role": "system", "content": system]] + history + [["role": "user", "content": question]]
        return try await complete(messages: messages, model: model, deadline: deadline, stage: stage)
    }

    /// One chat completion. `schema` asks for structured output under that name.
    func complete(
        messages: [[String: Any]], model: String, schema: (name: String, schema: [String: Any])? = nil,
        deadline: TimeInterval, stage: UsageStage
    ) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": messages, "max_tokens": 8_000]
        if let schema {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": schema.name, "strict": true, "schema": schema.schema]]
        }
        if let effort = Self.reasoningEffort(model: model) { body["reasoning_effort"] = effort }
        let data = try await send(
            url: AssemblyAIConfig.gateway.appendingPathComponent("v1/chat/completions"),
            body: try JSONSerialization.data(withJSONObject: body), deadline: deadline,
            modelLabel: model, stage: stage)
        if let usage = TokenUsage.fromChatCompletion(data) {
            UsageMeter.record(stage: stage, model: Self.label(model), usage: usage)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        if choice["finish_reason"] as? String == "content_filter" { throw TranscriptionError.safetyBlocked }
        return message["content"] as? String ?? ""
    }

    /// No reasoning for the writers that support switching it off: the
    /// writing rules need none, and reasoning is billed as output.
    static func reasoningEffort(model: String) -> String? {
        if model.hasPrefix("gpt-6") { return "none" }
        if model.hasPrefix("gemini-3") { return "low" }
        return nil
    }

    /// Usage rows name the host, so the Cost pane books them to AssemblyAI.
    static func label(_ model: String) -> String { "assemblyai/\(model)" }

    // MARK: - Pre-recorded transcription

    public struct TranscriptRequest: Sendable {
        public var speechModels: [String]
        public var languageCode: String?
        public var speakerLabels: Bool

        public init(speechModels: [String] = [AssemblyAIConfig.transcribeModel, AssemblyAIConfig.fallbackModel],
                    languageCode: String? = nil, speakerLabels: Bool = false) {
            self.speechModels = speechModels
            self.languageCode = languageCode
            self.speakerLabels = speakerLabels
        }

        var body: [String: Any] {
            var body: [String: Any] = ["speech_models": speechModels]
            if let languageCode { body["language_code"] = languageCode } else { body["language_detection"] = true }
            if speakerLabels { body["speaker_labels"] = true }
            return body
        }

        /// USD an hour of audio costs on `model`, the one the service used,
        /// with these options.
        func pricePerHour(model: String) -> Double {
            var rate = model.hasPrefix("universal")
                ? AssemblyAIPrices.universal2PerHour : AssemblyAIPrices.stt37PerHour
            if speakerLabels { rate += AssemblyAIPrices.diarizationPerHour }
            return rate
        }
    }

    public struct Transcript: Sendable, Equatable {
        public struct Word: Sendable, Equatable {
            public var text: String
            public var start: Double
            public var end: Double
            /// The speaker's label ("A") or, with Speaker Identification, name.
            public var speaker: String?
        }
        public var text: String
        public var words: [Word]
        public var model: String
        public var audioSeconds: Double
    }

    /// Uploads the audio, starts a transcript and polls it to completion.
    public func transcribe(audio: Data, request: TranscriptRequest, deadline: TimeInterval,
                           stage: UsageStage) async throws -> Transcript {
        let started = Date()
        func remaining() throws -> TimeInterval {
            let left = deadline - Date().timeIntervalSince(started)
            guard left > 0 else { throw TranscriptionError.timeout }
            return left
        }
        let model = request.speechModels.first ?? AssemblyAIConfig.transcribeModel
        let upload = try await send(url: AssemblyAIConfig.api.appendingPathComponent("v2/upload"), body: audio,
                                    contentType: "application/octet-stream", deadline: try remaining(),
                                    modelLabel: model, stage: stage)
        guard let uploadURL = (try? JSONSerialization.jsonObject(with: upload) as? [String: Any])?["upload_url"] as? String
        else { throw TranscriptionError.network("upload_unparseable") }
        var body = request.body
        body["audio_url"] = uploadURL
        let created = try await send(url: AssemblyAIConfig.api.appendingPathComponent("v2/transcript"),
                                     body: try JSONSerialization.data(withJSONObject: body), deadline: try remaining(),
                                     modelLabel: model, stage: stage)
        guard let id = (try? JSONSerialization.jsonObject(with: created) as? [String: Any])?["id"] as? String
        else { throw TranscriptionError.network("transcript_unparseable") }
        // A 5-minute file completes in about 9 s at p50 (AssemblyAI's planning figure).
        var wait: UInt64 = 700_000_000
        var offline = false
        // Polls that ran out of time offline are offline, so the recording queues for the reconnect.
        func timeLeft() throws -> TimeInterval {
            do { return try remaining() } catch { throw offline ? TranscriptionError.offline : error }
        }
        while true {
            // Never sleeps past the deadline, however long a 429 asked for.
            try await Task.sleep(nanoseconds: min(wait, UInt64(try timeLeft() * 1_000_000_000)))
            wait = min(wait * 3 / 2, 3_000_000_000)
            let data: Data
            let pollDeadline = min(30, try timeLeft())
            do {
                data = try await send(url: AssemblyAIConfig.api.appendingPathComponent("v2/transcript/\(id)"), body: nil,
                                      deadline: pollDeadline, modelLabel: model, stage: stage)
                offline = false
            } catch TranscriptionError.rateLimitedTransient(let retryAfter) {
                // The job is uploaded and billed; a throttled poll waits as
                // long as the server asks (up to 30 s) and asks again.
                if let retryAfter { wait = max(wait, UInt64(min(retryAfter, 30) * 1_000_000_000)) }
                offline = false
                continue
            } catch TranscriptionError.offline {
                offline = true
                continue
            } catch TranscriptionError.network, TranscriptionError.timeout {
                // A failed poll asks again rather than sending the audio a second time.
                offline = false
                continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch json["status"] as? String {
            case "completed":
                let transcript = Self.transcript(from: json, model: model)
                UsageMeter.record(stage: stage, model: Self.label(transcript.model), usage: TokenUsage(
                    reportedCostUSD: transcript.audioSeconds / 3600 * request.pricePerHour(model: transcript.model),
                    audioSeconds: transcript.audioSeconds))
                return transcript
            case "error":
                let message = json["error"] as? String ?? "transcript_error"
                Log.transcription.error("AssemblyAI transcript failed: \(message, privacy: .private)")
                // Audio the service could not read fails the same way again;
                // a server error is worth another job.
                let lowered = message.lowercased()
                if lowered.contains("no spoken audio") { throw TranscriptionError.emptyTranscript }
                if lowered.contains("server error") { throw TranscriptionError.network("transcript_server_error") }
                throw TranscriptionError.badRequest(message)
            default:
                continue
            }
        }
    }

    static func transcript(from json: [String: Any], model: String) -> Transcript {
        let words = (json["words"] as? [[String: Any]] ?? []).compactMap { word -> Transcript.Word? in
            guard let text = word["text"] as? String, let start = word["start"] as? Double,
                  let end = word["end"] as? Double else { return nil }
            return Transcript.Word(text: text, start: start / 1000, end: end / 1000, speaker: word["speaker"] as? String)
        }
        return Transcript(text: json["text"] as? String ?? "", words: words,
                          model: json["speech_model_used"] as? String ?? json["speech_model"] as? String ?? model,
                          audioSeconds: json["audio_duration"] as? Double ?? (words.last?.end ?? 0))
    }

    // MARK: - Key check

    /// Why a key check failed, because "false" is not enough to act on.
    /// Onboarding lets someone past a check it could not perform, and
    /// hard-blocks a key the server rejected.
    public enum KeyCheck: Equatable, Sendable {
        case valid
        /// The server answered, and the answer was no. Never advance on this.
        case rejected(String?)
        /// We never got an answer. Not the key's fault — let them continue.
        case unreachable
    }

    public func validateKey() async -> KeyCheck {
        var request = URLRequest(url: AssemblyAIConfig.api.appendingPathComponent("v2/transcript")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "1")]))
        request.timeoutInterval = 10
        applyAuth(&request)
        let session = Self.makeSession()
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200: return .valid
        case 429, 500...599: return .unreachable
        default: return .rejected(Self.errorMessage(from: data))
        }
    }

    // MARK: - Transport

    /// Shared transport for every AssemblyAI call: auth, the true wall-clock
    /// deadline, and the HTTP status → TranscriptionError mapping. A GET
    /// when `body` is nil.
    func send(url: URL, body: Data?, contentType: String = "application/json", deadline: TimeInterval,
              modelLabel: String, stage: UsageStage, isRetryAfter429: Bool = false) async throws -> Data {
        // No key, no upload: the server would only refuse it.
        guard apiKey() != nil else { throw TranscriptionError.auth }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.timeoutInterval = deadline
        applyAuth(&request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.perform(request, deadline: deadline, stage: stage, modelLabel: modelLabel)
        } catch is DeadlineExceeded {
            throw TranscriptionError.timeout
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                throw TranscriptionError.offline
            case .timedOut:
                throw TranscriptionError.timeout
            default:
                throw TranscriptionError.network(error.code.rawValue.description)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.network("non-http") }
        let status = http.statusCode
        switch status {
        case 200...299:
            return data
        case 401:
            throw TranscriptionError.auth
        case 402:
            throw TranscriptionError.noBalance
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            // One wait, inside the caller's deadline.
            if !isRetryAfter429, let delay = retryAfter, delay <= 8, delay + 1 < deadline {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try Task.checkCancellation()
                return try await send(url: url, body: body, contentType: contentType, deadline: deadline - delay,
                                      modelLabel: modelLabel, stage: stage, isRetryAfter429: true)
            }
            throw TranscriptionError.rateLimitedTransient(retryAfter: retryAfter)
        case 400, 403, 404:
            let message = Self.errorMessage(from: data) ?? "http_\(status)"
            Log.transcription.error("AssemblyAI: \(status) on \(url.path, privacy: .public) (\(modelLabel, privacy: .public)) — \(message, privacy: .private)")
            // An account without a gateway balance gets 400 "does not have
            // access to this LLM Gateway model" (measured 2026-11-28).
            if Self.isNoBalance(message) { throw TranscriptionError.noBalance }
            if status == 400 { throw TranscriptionError.badRequest(message) }
            // The gateway answers a bad key with 403 "Authentication error".
            if status == 403, message.lowercased().contains("authentication") { throw TranscriptionError.auth }
            throw TranscriptionError.modelUnavailable(model: modelLabel, detail: message)
        case 500...599:
            throw TranscriptionError.network("http_\(status)")
        default:
            throw TranscriptionError.network(Self.errorMessage(from: data) ?? "http_\(status)")
        }
    }

    static func isNoBalance(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("does not have access to this llm gateway")
            || lowered.contains("insufficient funds") || lowered.contains("insufficient balance")
            || lowered.contains("insufficient credit")
            // The speech API's 400 once the credit is spent (common errors guide).
            || lowered.contains("balance is negative")
    }

    struct DeadlineExceeded: Error {}

    /// Races an operation against a hard wall-clock deadline.
    static func withDeadline<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DeadlineExceeded()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func applyAuth(_ request: inout URLRequest) {
        if let key = apiKey() { request.setValue(key, forHTTPHeaderField: "Authorization") }
    }

    /// The message of an error body: `{"error": "..."}` on the speech API,
    /// `{"message": ..., "metadata": {"errors": [...]}}` on the gateway.
    static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let errors = (json["metadata"] as? [String: Any])?["errors"] as? [String], let first = errors.first {
            return first
        }
        if let error = json["error"] as? String { return error }
        if let error = (json["error"] as? [String: Any])?["message"] as? String { return error }
        return json["message"] as? String
    }
}
