import Foundation

/// Endpoint + model configuration, overridable in Settings (preview models get
/// renamed; never hard-fail on a model name).
public struct GeminiConfig: Sendable, Equatable {
    public var endpoint: URL
    /// Meetings only: diarized, word-timed transcription.
    public var transcribeModel: String
    /// Everything else: one call hears a dictation and writes its text, and
    /// meeting notes and meeting chat run on it too.
    public var writingModel: String

    public init(
        endpoint: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        // Model IDs read from ai.google.dev/gemini-api/docs/models on
        // 2026-11-22. A user can pin others in Settings → Advanced.
        transcribeModel: String = "gemini-3.5-transcribe",
        writingModel: String = "gemini-3.8-flash"
    ) {
        self.endpoint = endpoint
        self.transcribeModel = transcribeModel
        self.writingModel = writingModel
    }
}

/// Low-level Gemini API client. Uses non-streaming `generateContent`: the probe
/// showed the transcribe model delivers its entire result in one SSE lump anyway,
/// so streaming buys nothing but parsing complexity.
public actor GeminiClient {
    let session: URLSession
    private let apiKey: @Sendable () -> String?

    public init(apiKey: @escaping @Sendable () -> String?) {
        self.session = Self.makeSession()
        self.apiKey = apiKey
    }

    // MARK: - Calls

    /// One dictation in one call: the model hears the recording (FLAC) and
    /// answers `{"text": ...}` under `prompt`, which carries the writing
    /// rules. Screenshots ride along when
    /// screen context is on. Returns the text, or "" when the model heard no
    /// speech. Structured output keeps the model's working out of the answer:
    /// with audio attached, gemini-3.8-flash sometimes wrote its re-listening
    /// and drafts as plain text before the result (measured 2026-09-28).
    public func dictate(
        prompt: String,
        audio: Data,
        images: [Data] = [],
        model: String,
        endpoint: URL,
        deadline: TimeInterval
    ) async throws -> String {
        var parts: [[String: Any]] = [["text": prompt]]
        parts += images.map { ["inline_data": ["mime_type": "image/jpeg", "data": $0.base64EncodedString()]] }
        parts.append(["inline_data": ["mime_type": "audio/flac", "data": audio.base64EncodedString()]])
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "temperature": 0,
                "thinkingConfig": Self.thinkingConfig(model: model),
                "responseMimeType": "application/json",
                "responseJsonSchema": PromptV1.dictationSchema,
            ] as [String: Any],
        ]
        let reply = try await generateContent(body: body, model: model, endpoint: endpoint, deadline: deadline,
                                              stage: .transcribe)
        guard let text = PromptV1.dictationText(fromJSON: reply) else {
            // Never paste the model's working. Retryable: the next attempt
            // usually answers with the object.
            Log.transcription.warning("dictation reply was not the JSON answer")
            throw TranscriptionError.network("malformed_answer")
        }
        return text.contains(PromptV1.noSpeechToken) ? "" : text
    }

    /// A conversation: `system`, then alternating user and model turns,
    /// ending on the user's. For meeting chat; Gemini caches the repeated
    /// prefix implicitly.
    public func chat(
        system: String, turns: [(user: String, model: String)], question: String,
        model: String, endpoint: URL, deadline: TimeInterval, stage: UsageStage
    ) async throws -> String {
        let history: [[String: Any]] = turns.flatMap { turn in
            [["role": "user", "parts": [["text": turn.user]]], ["role": "model", "parts": [["text": turn.model]]]]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": history + [["role": "user", "parts": [["text": question]]]],
            "generationConfig": ["thinkingConfig": Self.thinkingConfig(model: model)],
        ]
        return try await generateContent(body: body, model: model, endpoint: endpoint, deadline: deadline, stage: stage)
    }

    /// Gemini 2 takes a zero thinking budget; Gemini 3 takes a level, and
    /// gemini-3.8-flash rejected "minimal" in the live probe.
    static func thinkingConfig(model: String) -> [String: Any] {
        model.hasPrefix("gemini-2") ? ["thinkingBudget": 0] : ["thinkingLevel": "low"]
    }

    /// Cheap key validation for onboarding/Settings.
    /// Why a key check failed, because "false" is not enough to act on.
    ///
    /// Onboarding must let someone past a check it could not perform (a captive
    /// portal, a VPN coming up) while HARD-BLOCKING a key the server actively
    /// rejected. Collapsing both into `false` is what let a bad key through: the
    /// caller fell back to a 1-second reachability probe that false-negatives on
    /// a cold NWPathMonitor, then saved the key anyway.
    public enum KeyCheck: Equatable, Sendable {
        case valid
        /// The server answered, and the answer was no. Never advance on this.
        case rejected(String?)
        /// We never got an answer. Not the key's fault — let them continue.
        case unreachable
    }

    public func validateKey(endpoint: URL) async -> KeyCheck {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1beta/models").appending(queryItems: [URLQueryItem(name: "pageSize", value: "1")]))
        request.timeoutInterval = 10
        applyAuth(&request)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .unreachable
        }
        switch http.statusCode {
        case 200:
            return .valid
        case 400, 401, 403:
            // A bad key returns 400 with API_KEY_INVALID on this API, not 401 —
            // measured. Treating only 401 as rejection would call it unreachable.
            return .rejected(Self.errorMessage(from: data))
        case 500...599:
            return .unreachable
        default:
            return .rejected(Self.errorMessage(from: data))
        }
    }

    /// First model in `candidates` this key can actually reach, or nil if none.
    /// Onboarding runs this so "your key works" means the whole pipeline works,
    /// not just that the key authenticates.
    public func resolveAvailableModel(from candidates: [String], endpoint: URL) async -> String? {
        for model in candidates {
            var request = URLRequest(url: endpoint.appendingPathComponent("v1beta/models/\(model)"))
            request.timeoutInterval = 8
            applyAuth(&request)
            guard let (_, response) = try? await session.data(for: request) else { continue }
            if (response as? HTTPURLResponse)?.statusCode == 200 { return model }
        }
        return nil
    }

    // MARK: - Core

    /// Thin parser over `post` — the classic `candidates/content/parts` envelope.
    func generateContent(body: [String: Any], model: String, endpoint: URL, deadline: TimeInterval,
                         stage: UsageStage) async throws -> String {
        let data = try await post(
            path: "v1beta/models/\(model):generateContent",
            body: try JSONSerialization.data(withJSONObject: body),
            endpoint: endpoint, deadline: deadline, modelLabel: model, stage: stage
        )
        return try Self.extractText(from: data)
    }

    /// Shared transport for EVERY Gemini call: auth, the true wall-clock deadline,
    /// and the HTTP status → TranscriptionError mapping. That mapping must never
    /// fork per-endpoint — RetryQueue branches on `.rateLimitedDaily` vs
    /// `.rateLimitedTransient` to decide between "keep this row queued forever"
    /// and "mark it failed", so two copies would drift into a data-loss bug.
    func post(
        path: String,
        body: Data,
        endpoint: URL,
        deadline: TimeInterval,
        modelLabel: String,
        /// False when the model is named in the BODY rather than the URL path
        /// (interactions). A 403/404 there is about the ENDPOINT, not the model,
        /// so reporting "your key can't use this model" would send the user to
        /// the wrong fix — especially since onboarding's preflight GETs the model
        /// resource and passes for exactly that user.
        modelIsInPath: Bool = true,
        /// Attributed to the current `UsageMeter.scope` for the Cost pane.
        stage: UsageStage,
        isRetryAfter429: Bool = false
    ) async throws -> Data {
        let url = endpoint.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = deadline
        applyAuth(&request)
        request.httpBody = body

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

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network("non-http")
        }
        switch http.statusCode {
        case 200:
            // Every billed call passes through here, so this is the one place
            // usage is read. Both envelopes are tried; a body with neither is
            // simply not metered.
            if let usage = TokenUsage.fromGenerateContent(data) ?? TokenUsage.fromInteraction(data) {
                UsageMeter.record(stage: stage, model: modelLabel, usage: usage)
            }
        case 401:
            throw TranscriptionError.auth
        case 403, 404:
            // Key authenticated but this model is not available to it — gated,
            // renamed, or unknown. "Fix your key" would misdirect — name the
            // model instead.
            let message = Self.errorMessage(from: data)
            Log.transcription.error("GeminiClient: \(http.statusCode) on \(path, privacy: .public) (\(modelLabel, privacy: .public)) — \(message ?? "no detail", privacy: .private)")
            guard modelIsInPath else {
                // The transcription endpoint itself is unreachable for this key.
                // Retryable, and the copy points at the Advanced escape hatch
                // rather than at a model the key demonstrably can reach.
                throw TranscriptionError.network("interactions_unavailable_\(http.statusCode)")
            }
            throw TranscriptionError.modelUnavailable(model: modelLabel, detail: message)
        case 429:
            let retryAfter = Self.retryDelaySeconds(from: data, headers: http)
            Log.transcription.info("GeminiClient: 429 on \(path, privacy: .public) (\(modelLabel, privacy: .public)) retryAfter=\(retryAfter ?? -1, format: .fixed(precision: 0)) — \(Self.errorMessage(from: data) ?? "no detail", privacy: .private)")
            // F5: per-minute throttles carry a short retryDelay — honor it once.
            if !isRetryAfter429, let delay = retryAfter, delay <= 8 {
                Log.transcription.info("GeminiClient: 429 with retryDelay \(delay, format: .fixed(precision: 1))s — waiting once")
                // A cancelled dictation (the user cancelled, or a new one
                // replaced it) stops here instead of sending again.
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try Task.checkCancellation()
                return try await post(path: path, body: body, endpoint: endpoint, deadline: deadline,
                                      modelLabel: modelLabel, modelIsInPath: modelIsInPath, stage: stage,
                                      isRetryAfter429: true)
            }
            // Only a real daily/hard quota is terminal; a per-minute throttle
            // (or an unparseable body) clears on its own and stays retryable.
            if let body = String(data: data, encoding: .utf8),
               let range = body.range(of: #""quotaId"\s*:\s*"[^"]*PerDay[^"]*""#, options: .regularExpression),
               !range.isEmpty {
                throw TranscriptionError.rateLimitedDaily
            }
            throw TranscriptionError.rateLimitedTransient(retryAfter: retryAfter)
        case 400:
            // Permanent: malformed request — retrying is pointless.
            let message = Self.errorMessage(from: data) ?? "http_\(http.statusCode)"
            Log.transcription.error("GeminiClient: \(http.statusCode) — \(message, privacy: .private)")
            throw TranscriptionError.badRequest(message)
        case 500...599:
            throw TranscriptionError.network("http_\(http.statusCode)")
        default:
            let message = Self.errorMessage(from: data) ?? "http_\(http.statusCode)"
            Log.transcription.error("GeminiClient: \(http.statusCode) — \(message, privacy: .private)")
            throw TranscriptionError.network(message)
        }

        return data
    }

    /// HTTP 200 with a non-"completed" status. Unknown statuses map to `.network`
    /// (RETRYABLE) rather than `.badRequest` (terminal) on purpose: under
    /// never-lose-words the safe direction on an unrecognised string is keeping
    /// the row queued and recoverable, not marking it permanently failed.
    static func mapInteractionStatus(_ status: String, json: [String: Any]) -> TranscriptionError {
        let detail = (json["error"] as? [String: Any])?["message"] as? String ?? ""
        if status == "failed" || status == "error" {
            let lowered = detail.lowercased()
            if lowered.contains("safety") || lowered.contains("blocked") {
                return .safetyBlocked
            }
            Log.transcription.error("interactions failed: \(detail, privacy: .private)")
            return .network("interaction_failed")
        }
        Log.transcription.error("interactions unexpected status \(status, privacy: .public)")
        return .network("interaction_status_\(status)")
    }

    /// Extracts a short retry hint from a 429: Retry-After header (seconds or
    /// an HTTP-date) or the google.rpc.RetryInfo "retryDelay": "2s" detail in
    /// the error body.
    static func retryDelaySeconds(from data: Data, headers: HTTPURLResponse, now: Date = Date()) -> Double? {
        if let header = headers.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Double(header) { return seconds }
            if let date = httpDateFormatter.date(from: header.trimmingCharacters(in: .whitespaces)) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        if let range = body.range(of: #""retryDelay"\s*:\s*"([0-9.]+)s""#, options: .regularExpression) {
            let match = String(body[range])
            let digits = match.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber || $0 == "." })
            return Double(digits)
        }
        return nil
    }

    /// RFC 9110 IMF-fixdate, the only form a server may send today.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

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

    deinit {
        session.invalidateAndCancel() // transient clients (key validation) must not leak (audit L33)
    }

    func applyAuth(_ request: inout URLRequest) {
        // Header, never ?key= — query strings leak into logs and proxies.
        if let key = apiKey() {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
    }

    // MARK: - Response parsing (pure, tested)

    static func extractText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        if let feedback = json["promptFeedback"] as? [String: Any],
           feedback["blockReason"] != nil {
            throw TranscriptionError.safetyBlocked
        }
        guard let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first else {
            throw TranscriptionError.network("no_candidates")
        }
        if let finish = first["finishReason"] as? String, finish == "SAFETY" {
            throw TranscriptionError.safetyBlocked
        }
        let parts = (first["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let texts = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // MEASURED 2026-09-26: with a FLAC attached, gemini-3.8-flash sometimes
        // returns two text parts, the first its working ("The speaker says: …
        // Let's re-listen at 01:21 …"), the second the answer. Neither carries
        // `thought: true`. Joining them made the output 2.7× the raw length, so
        // the gate rejected it and the raw transcript was pasted. The answer is
        // always the last part.
        return texts.last ?? ""
    }

    /// The two endpoints do NOT share an error envelope, measured 2026-08-20:
    ///   :generateContent  bad key  -> {"error":{...}}
    ///   /v1beta/interactions        -> [{"error":{...}}]   (array-wrapped)
    ///   :generateContent  bad model -> {"code":404,"status":"NOT_FOUND"}
    ///   /v1beta/interactions        -> {"code":"not_found"} (String code, no status)
    /// Casting straight to [String: Any] loses the message on the array form and
    /// the user gets a bare "http_400" instead of "API key not valid".
    static func errorMessage(from data: Data) -> String? {
        let root = try? JSONSerialization.jsonObject(with: data)
        let object: [String: Any]?
        if let dict = root as? [String: Any] {
            object = dict
        } else if let array = root as? [[String: Any]] {
            object = array.first
        } else {
            object = nil
        }
        guard let error = object?["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
