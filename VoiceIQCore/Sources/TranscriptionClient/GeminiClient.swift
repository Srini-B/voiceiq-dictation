import Foundation

/// Endpoint + model configuration, overridable in Settings (preview models get
/// renamed; never hard-fail on a model name).
public struct GeminiConfig: Sendable, Equatable {
    public var endpoint: URL
    public var transcribeModel: String
    public var cleanupModel: String

    public init(
        endpoint: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        // PRODUCT DECISION, not a tunable default: VoiceiQ ships on
        // gemini-3.5-transcribe. Do not swap it, and do not add automatic
        // substitution — no other model is this product. (The name that 404'd
        // on 2026-08-18 was the -preview suffix; the graduated name is this
        // one.) A user can still pin something else in Settings → Advanced.
        transcribeModel: String = "gemini-3.5-transcribe",
        cleanupModel: String = "gemini-3.8-flash"
    ) {
        self.endpoint = endpoint
        self.transcribeModel = transcribeModel
        self.cleanupModel = cleanupModel
    }

}

public extension GeminiClient {
    /// How the transcription model formats its output.
    ///
    /// VERIFIED 2026-08-20 against the live API: `verbatim` produces output
    /// byte-identical to sending no transcription_config at all, so it is the
    /// server default and we omit the field entirely for it.
    enum TranscriptionMode: String, Sendable, CaseIterable {
        /// Exactly what was said, punctuated.
        case verbatim
        /// The model removes fillers, collapses self-corrections ("at 1pm —
        /// actually, no, 2pm"), formats spoken lists and adds paragraph breaks.
        case smart
    }
}

/// Low-level Gemini API client. Uses non-streaming `generateContent`: the probe
/// showed the transcribe model delivers its entire result in one SSE lump anyway,
/// so streaming buys nothing but parsing complexity.
public actor GeminiClient {
    let session: URLSession
    private let apiKey: @Sendable () -> String?
    let openRouterKey: @Sendable () -> String?
    let vercelKey: @Sendable () -> String?
    let openAIKey: @Sendable () -> String?
    let elevenLabsKey: @Sendable () -> String?
    let sarvamKey: @Sendable () -> String?
    /// Read per call, like `provider`, so a model override applies at once.
    let openAIConfig: @Sendable () -> OpenAIConfig
    /// Read per call: whose model writes (`cleanup`, meeting notes).
    let writingSource: @Sendable () -> WritingSource
    /// Read per call, so flipping the provider or gateway in Settings takes
    /// effect on the next request without rebuilding the client.
    let route: @Sendable () -> ModelRoute

    public init(
        apiKey: @escaping @Sendable () -> String?,
        openRouterKey: @escaping @Sendable () -> String? = { nil },
        vercelKey: @escaping @Sendable () -> String? = { nil },
        openAIKey: @escaping @Sendable () -> String? = { nil },
        elevenLabsKey: @escaping @Sendable () -> String? = { nil },
        sarvamKey: @escaping @Sendable () -> String? = { nil },
        openAIConfig: @escaping @Sendable () -> OpenAIConfig = { OpenAIConfig() },
        writingSource: @escaping @Sendable () -> WritingSource = { .provider },
        route: @escaping @Sendable () -> ModelRoute = { ModelRoute(provider: .gemini, gateway: .direct) }
    ) {
        self.session = Self.makeSession()
        self.apiKey = apiKey
        self.openRouterKey = openRouterKey
        self.vercelKey = vercelKey
        self.openAIKey = openAIKey
        self.elevenLabsKey = elevenLabsKey
        self.sarvamKey = sarvamKey
        self.openAIConfig = openAIConfig
        self.writingSource = writingSource
        self.route = route
    }

    // MARK: - Calls

    /// Audio-only request. The transcribe models ignore prompts, and
    /// audioTranscriptionConfig.wordTimestamp MUST be true or the transcript
    /// comes back empty.
    public func transcribe(
        flacData: Data, model: String, endpoint: URL, deadline: TimeInterval,
        customVocabulary: [String] = []
    ) async throws -> String {
        let route = route()
        switch (route.provider, route.gateway) {
        case (.gemini, .direct): break
        case (.openAI, .direct):
            return try await openAITranscribe(audio: flacData, keywords: customVocabulary, deadline: deadline)
        default:
            return try await gatewayTranscribe(audio: flacData, model: transcriptionModelID(model, route: route),
                                               deadline: deadline, stage: .transcribe, via: route.endpoint)
        }
        let parts: [[String: Any]] = [
            ["inline_data": ["mime_type": "audio/flac", "data": flacData.base64EncodedString()]],
        ]
        // NB: `mode` is NOT available here — it parses but returns an empty text
        // part on this endpoint. wordTimestamp remains mandatory, and the two are
        // mutually exclusive (400 together). customVocabulary does work, so the
        // Dictionary keeps biasing the recogniser even on the legacy transport.
        var audioConfig: [String: Any] = ["wordTimestamp": true, "diarization": false]
        if !customVocabulary.isEmpty { audioConfig["customVocabulary"] = customVocabulary }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "temperature": 0,
                "audioTranscriptionConfig": audioConfig,
            ],
        ]
        return try await generateContent(body: body, model: model, endpoint: endpoint, deadline: deadline, stage: .transcribe)
    }

    /// Cleanup call (flash class, thinking minimized), optionally with JPEG context.
    /// The thinking knob differs by model generation (probed live):
    ///  - gemini-2.x: `thinkingConfig.thinkingBudget: 0`
    ///  - gemini-3.x+: `thinkingConfig.thinkingLevel: "low"` (thinkingBudget → 400;
    ///    bare/top-level thinkingLevel → 400; "low" measured faster and more
    ///    consistent than "minimal" on our eval set)
    public func cleanup(
        prompt: String,
        images: [Data] = [],
        audioFLAC: Data? = nil,
        model: String,
        endpoint: URL,
        deadline: TimeInterval,
        stage: UsageStage = .cleanup,
        jsonSchema: [String: Any]? = nil
    ) async throws -> String {
        let route = route()
        // Callers check `writingModelHearsAudio`; a recording reaching an
        // OpenAI writing model would be dropped and the prompt would lie.
        if audioFLAC != nil, !route.provider.writingModelHearsAudio || writingSource() == .sarvam {
            throw TranscriptionError.badRequest("writing model takes no audio")
        }
        if writingSource() == .sarvam {
            // Text only: `sarvam-105b` takes no images, so screenshots stay here.
            return try await sarvamChat(prompt: prompt, deadline: deadline, stage: stage, jsonSchema: jsonSchema)
        }
        switch (route.provider, route.gateway) {
        case (.gemini, .direct): break
        case (.openAI, .direct):
            return try await openAIChat(prompt: prompt, images: images, deadline: deadline, stage: stage, jsonSchema: jsonSchema)
        default:
            return try await gatewayChat(prompt: prompt, images: images, audioFLAC: audioFLAC,
                                         model: writingModelID(model, route: route), provider: route.provider,
                                         deadline: deadline, stage: stage, jsonSchema: jsonSchema, via: route.endpoint)
        }
        let thinkingConfig: [String: Any] = model.hasPrefix("gemini-2")
            ? ["thinkingBudget": 0]
            : ["thinkingLevel": "low"]
        var parts: [[String: Any]] = [["text": prompt]]
        parts.append(contentsOf: images.map {
            ["inline_data": ["mime_type": "image/jpeg", "data": $0.base64EncodedString()]]
        })
        if let audioFLAC {
            parts.append(["inline_data": ["mime_type": "audio/flac", "data": audioFLAC.base64EncodedString()]])
        }
        var generationConfig: [String: Any] = [
            "temperature": 0,
            "thinkingConfig": thinkingConfig,
        ]
        if let jsonSchema {
            // Structured output keeps the model's working out of the answer:
            // with audio attached, gemini-3.8-flash sometimes wrote its
            // re-listening and drafts as plain text before the result.
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseJsonSchema"] = jsonSchema
        }
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": parts,
            ]],
            "generationConfig": generationConfig,
        ]
        return try await generateContent(body: body, model: model, endpoint: endpoint, deadline: deadline, stage: stage)
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
        isRetryAfter429: Bool = false,
        /// Gateway calls share this transport: same deadline, same status →
        /// error mapping, different base URL, auth header and usage envelope.
        via: ModelEndpoint = .gemini,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        let url = endpoint.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: field) }
        request.timeoutInterval = deadline
        applyAuth(&request, via: via)
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.perform(request, deadline: deadline, stage: stage, via: via, modelLabel: modelLabel)
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
        // Sarvam answers 202 Accepted when it creates a batch job.
        case 200,
             202 where via == .sarvam:
            // Every billed call passes through here, so this is the one place
            // usage is read. Both envelopes are tried; a body with neither is
            // simply not metered.
            let usage: TokenUsage? = switch via {
            case .gemini: TokenUsage.fromGenerateContent(data) ?? TokenUsage.fromInteraction(data)
            case .openAI: TokenUsage.fromOpenAIDuration(data, model: modelLabel) ?? TokenUsage.fromOpenAI(data)
            case .openRouter, .vercel: TokenUsage.fromOpenAI(data) ?? TokenUsage.fromVercelTranscription(data)
            // No usage block, and the price depends on the request's options:
            // `elevenLabsTranscribe` books it.
            case .elevenLabs: nil
            // Chat reports OpenAI-shaped usage; speech-to-text has none and
            // `sarvamTranscribe` books it by audio length.
            case .sarvam: TokenUsage.fromOpenAI(data)
            }
            if let usage {
                UsageMeter.record(stage: stage, model: modelLabel, usage: usage)
            }
        case 401:
            // ElevenLabs answers 401 for an exhausted credit balance as well as
            // for a bad key (`quota_exceeded`): that is "add credits", not "fix
            // your key", and it clears on top-up, so it blocks the queue like a
            // daily quota instead of failing the row.
            if via == .elevenLabs {
                let detail = Self.elevenLabsErrorDetail(from: data)
                Log.transcription.error("GeminiClient: 401 on \(path, privacy: .public) via elevenLabs — \(detail.kinds.joined(separator: "/"), privacy: .public): \(detail.message ?? "no detail", privacy: .private)")
                if Self.isElevenLabsQuota(detail) { throw TranscriptionError.rateLimitedDaily }
            }
            throw TranscriptionError.auth
        case 402 where via == .elevenLabs:
            Log.transcription.error("GeminiClient: 402 on \(path, privacy: .public) via elevenLabs — \(Self.errorMessage(from: data) ?? "no detail", privacy: .private)")
            throw TranscriptionError.rateLimitedDaily
        case 402:
            // Gateways: the key is fine, the account balance is not. Retryable
            // so the recording stays queued until credits are added.
            Log.transcription.error("GeminiClient: 402 on \(path, privacy: .public) — \(Self.errorMessage(from: data) ?? "no detail", privacy: .private)")
            throw TranscriptionError.network("gateway_insufficient_credits")
        case 403 where via == .sarvam:
            // Sarvam answers 403 `invalid_api_key_error` for a bad key
            // (checked 2026-10-03); 401 is not used.
            Log.transcription.error("GeminiClient: 403 on \(path, privacy: .public) via sarvam — \(Self.errorMessage(from: data) ?? "no detail", privacy: .private)")
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
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await post(path: path, body: body, endpoint: endpoint, deadline: deadline,
                                      modelLabel: modelLabel, modelIsInPath: modelIsInPath, stage: stage,
                                      isRetryAfter429: true, via: via, extraHeaders: extraHeaders)
            }
            // OpenAI answers 429 `insufficient_quota` when the account has no
            // credit left, Sarvam 429 `insufficient_quota_error`: the same
            // situation as a gateway's 402.
            if let body = String(data: data, encoding: .utf8), body.contains("insufficient_quota") {
                throw TranscriptionError.network("gateway_insufficient_credits")
            }
            // Only a real daily/hard quota is terminal; a per-minute throttle
            // (or an unparseable body) clears on its own and stays retryable.
            if let body = String(data: data, encoding: .utf8),
               let range = body.range(of: #""quotaId"\s*:\s*"[^"]*PerDay[^"]*""#, options: .regularExpression),
               !range.isEmpty {
                throw TranscriptionError.rateLimitedDaily
            }
            throw TranscriptionError.rateLimitedTransient(retryAfter: retryAfter)
        case 400,
             422 where via == .elevenLabs || via == .sarvam:
            // Permanent: malformed request — retrying is pointless. ElevenLabs
            // and Sarvam report schema validation as 422.
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

    // MARK: - Interactions (native smart transcription)

    /// Audio transcription via `POST {endpoint}/v1beta/interactions`.
    ///
    /// This is a DIFFERENT surface from `:generateContent`, with a different
    /// response envelope (`steps/content/text`, not `candidates/content/parts`)
    /// and the model named in the BODY rather than the URL path. It is the only
    /// place `mode: "smart"` works — on `:generateContent` the same field parses
    /// but returns an empty text part with finishReason STOP (probed on the
    /// transcribe models).
    public func transcribeInteraction(
        audio: Data,
        mimeType: String = "audio/flac",
        model: String,
        endpoint: URL,
        mode: TranscriptionMode,
        customVocabulary: [String],
        deadline: TimeInterval
    ) async throws -> String {
        let route = route()
        switch (route.provider, route.gateway) {
        case (.gemini, .direct): break
        case (.openAI, .direct):
            // No smart mode; the dictionary rides along as keywords, and the
            // cleanup pass does the formatting.
            return try await openAITranscribe(audio: audio, mimeType: mimeType, keywords: customVocabulary, deadline: deadline)
        default:
            // The gateways' transcription endpoints have no smart mode or custom
            // vocabulary; the cleanup pass carries the dictionary instead.
            return try await gatewayTranscribe(audio: audio, mimeType: mimeType, model: transcriptionModelID(model, route: route),
                                               deadline: deadline, stage: .transcribe, via: route.endpoint)
        }
        var body: [String: Any] = [
            "model": model,
            "input": [["type": "audio", "mime_type": mimeType, "data": audio.base64EncodedString()]],
        ]
        if let config = Self.transcriptionConfig(mode: mode, customVocabulary: customVocabulary) {
            body["generation_config"] = ["transcription_config": config]
        }
        let data = try await post(
            path: "v1beta/interactions",
            body: try JSONSerialization.data(withJSONObject: body),
            endpoint: endpoint, deadline: deadline, modelLabel: model, modelIsInPath: false, stage: .transcribe
        )
        return try Self.extractInteractionText(from: data)
    }

    /// The ONLY place a transcription_config is constructed.
    ///
    /// NEVER add `language_codes` here. VERIFIED 2026-08-20 against the live API:
    /// sending {"mode":"smart","language_codes":["en-US"]} returns VERBATIM output
    /// with HTTP 200 and no error — smart mode is silently disabled and there is
    /// no runtime signal whatsoever. (The published example pairs them, which is
    /// how this would have shipped.) `custom_vocabulary` is safe to combine.
    /// TranscriptionConfigTests pins this; a comment alone cannot defend it.
    static func transcriptionConfig(mode: TranscriptionMode, customVocabulary: [String]) -> [String: Any]? {
        switch mode {
        case .verbatim:
            // Server default. Omitting the field is byte-identical to sending it.
            return customVocabulary.isEmpty ? nil : ["custom_vocabulary": customVocabulary]
        case .smart:
            var config: [String: Any] = ["mode": "smart"]
            if !customVocabulary.isEmpty { config["custom_vocabulary"] = customVocabulary }
            return config
        }
    }

    /// interactions envelope: {"id","status","steps":[{"type","content":[{"type","text"}]}],"usage"}
    ///
    /// Empty text is returned as "" rather than thrown, exactly as `extractText`
    /// does — GeminiTranscriptionService owns the empty-transcript retry and the
    /// coordinator classifies silence by audio energy. Throwing here would route
    /// a quiet dictation into the failure path instead.
    static func extractInteractionText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        let status = json["status"] as? String ?? "missing"
        guard status == "completed" else { throw mapInteractionStatus(status, json: json) }
        // VERIFIED 2026-09-26 against the live API: a silent clip comes back
        // `completed` with zero output tokens and NO `steps` key at all. That is
        // an empty transcript, not a transport failure — throwing here showed
        // "network" for every quiet dictation.
        guard let steps = json["steps"] as? [[String: Any]] else { return "" }
        return steps
            .filter { ($0["type"] as? String) == "model_output" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
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

    func applyAuth(_ request: inout URLRequest, via: ModelEndpoint = .gemini) {
        // Header, never ?key= — query strings leak into logs and proxies.
        switch via {
        case .gemini:
            if let key = apiKey() {
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            }
        case .openRouter:
            if let key = openRouterKey() {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .vercel:
            if let key = vercelKey() {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .openAI:
            if let key = openAIKey() {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .elevenLabs:
            if let key = elevenLabsKey() {
                request.setValue(key, forHTTPHeaderField: "xi-api-key")
            }
        case .sarvam:
            if let key = sarvamKey() {
                request.setValue(key, forHTTPHeaderField: "api-subscription-key")
            }
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
        guard let error = object?["error"] as? [String: Any] else { return elevenLabsErrorDetail(from: data).message }
        return error["message"] as? String
    }
}
