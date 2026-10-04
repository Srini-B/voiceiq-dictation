import Foundation

/// Sarvam: Saaras V4 for speech-to-text (`TranscriptionSource.sarvam`, also
/// meetings) and `sarvam-105b` as the writing model (`WritingSource.sarvam`).
///
/// Probed 2026-10-03 with a real key (docs.sarvam.ai/api-reference-docs):
///  - Sync `POST /speech-to-text`, multipart, `api-subscription-key` header.
///    FLAC accepted. Hard 30 s limit (400 past it). `language_code=unknown`
///    auto-detects and the answer carries `language_probability`. `keyterms`
///    is one field holding a JSON array of strings. No speaker labels here.
///  - Batch `POST /speech-to-text/job/v1` (answers 202) → upload URL → `PUT` the file to
///    Azure (needs `x-ms-blob-type: BlockBlob` and an audio `Content-Type`,
///    or `start` refuses the file) → `start` → poll `status` → `download-files`
///    → `GET` the JSON. 81 s of audio took about 6 s. Diarization is batch
///    only. `download-files` can still say "Pending" for a second after
///    `status` says Completed, so it is retried.
///  - Chat `POST /v1/chat/completions`, OpenAI-shaped, string content only.
///    `reasoning_effort: null` turns thinking off. No image input.
///  - Errors `{"error": {message, code, request_id}}`: 403 bad key, 400 bad
///    request, 429 rate limit or `insufficient_quota_error`.
///  - Prices are in rupees: see `PriceBook.pricesINR`.
public enum Sarvam {
    public static let sttModel = "saaras:v4"
    /// The usage label of a diarized batch job, priced at ₹45 an hour.
    public static let diarizeModel = "saaras:v4:diarize"
    public static let chatModel = "sarvam-105b"
    static let apiBase = URL(string: "https://api.sarvam.ai")!
    static let syncLimitSeconds: Double = 30
    static let keytermLimit = 50
    static let keytermCharacters = 64

    /// Dictionary terms as the API takes them: deduped, at most 50, each at
    /// most 64 characters.
    static func keyterms(_ vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in vocabulary {
            let term = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty, term.count <= keytermCharacters, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == keytermLimit { break }
        }
        return terms
    }

    /// Speaker turns of a diarized answer, each as one `DiarizedWord`, the
    /// way OpenAI's diarizer is read. `timestamps.words` are not words but
    /// ~30 s pieces, so they carry nothing finer.
    static func diarizedWords(_ json: [String: Any]) -> [DiarizedWord] {
        let entries = (json["diarized_transcript"] as? [String: Any])?["entries"] as? [[String: Any]] ?? []
        let words: [DiarizedWord] = entries.compactMap { entry in
            guard let text = (entry["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return DiarizedWord(text: text, speaker: (entry["speaker_id"] as? String).map { "speaker_\($0)" },
                                start: (entry["start_time_seconds"] as? NSNumber)?.doubleValue,
                                end: (entry["end_time_seconds"] as? NSNumber)?.doubleValue)
        }
        if !words.isEmpty { return words }
        let text = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [DiarizedWord(text: text, speaker: nil)]
    }

    static func usage(seconds: Double) -> TokenUsage { TokenUsage(audioSeconds: seconds) }

    /// `max_tokens` for a writing call. Omitted, the API stops at 2,048
    /// tokens, which truncates the rewrite of a long dictation (Indic text
    /// tokenizes at close to one token a character). The answer is at most
    /// about the prompt's size, so one token per prompt character is a safe
    /// ceiling. The plan caps it (Starter 4,096, Pro 16,384, Business
    /// 128,000); a budget over the cap is a 400 that names the cap, and
    /// `sarvamChat` retries at it.
    static func outputBudget(promptCharacters: Int) -> Int {
        min(32_768, max(4_096, promptCharacters))
    }

    /// The ceiling quoted by a `max_tokens` rejection: "max_tokens (N)
    /// exceeds the maximum output length of 128000 tokens for sarvam-105b."
    static func maxTokensCeiling(in message: String) -> Int? {
        guard message.contains("max_tokens"),
              let range = message.range(of: "maximum output length of ") else { return nil }
        let digits = message[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}

extension GeminiClient {
    /// One recording to Saaras V4: the sync endpoint under 30 s, a batch job
    /// above it. `verbatim` keeps fillers and spoken numbers as said.
    func sarvamTranscribe(audio: Data, audioSeconds: Double, keyterms vocabulary: [String], verbatim: Bool,
                          language: SarvamLanguage, deadline: TimeInterval) async throws -> String {
        let keyterms = Sarvam.keyterms(vocabulary)
        let mode = verbatim ? "verbatim" : "transcribe"
        let fx = Task { await FXRates.refresh() }
        let json: [String: Any]
        if audioSeconds <= Sarvam.syncLimitSeconds {
            var form = MultipartForm()
            form.field("model", Sarvam.sttModel)
            form.field("language_code", language.rawValue)
            form.field("mode", mode)
            if !keyterms.isEmpty, let encoded = try? JSONSerialization.data(withJSONObject: keyterms) {
                form.field("keyterms", String(decoding: encoded, as: UTF8.self))
            }
            form.file("file", filename: "audio.flac", mimeType: "audio/flac", data: audio)
            let data = try await post(path: "speech-to-text", body: form.body, endpoint: Sarvam.apiBase,
                                      deadline: deadline, modelLabel: Sarvam.sttModel, stage: .transcribe,
                                      via: .sarvam, extraHeaders: ["Content-Type": form.contentType])
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw TranscriptionError.network("unparseable_response")
            }
            json = parsed
        } else {
            var parameters: [String: Any] = ["model": Sarvam.sttModel, "mode": mode, "language_code": language.rawValue,
                                             "with_timestamps": false, "with_diarization": false]
            if !keyterms.isEmpty { parameters["keyterms"] = keyterms }
            json = try await sarvamBatch(audio: audio, parameters: parameters, deadline: deadline,
                                         stage: .transcribe, modelLabel: Sarvam.sttModel)
        }
        await fx.value
        UsageMeter.record(stage: .transcribe, model: Sarvam.sttModel, usage: Sarvam.usage(seconds: audioSeconds))
        if let code = json["language_code"] as? String {
            Log.transcription.info("sarvam heard \(code, privacy: .public) (p=\((json["language_probability"] as? NSNumber)?.doubleValue ?? -1, format: .fixed(precision: 2)))")
        }
        return (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Speaker-labelled turns of one meeting window from a diarized batch
    /// job. Labels (`speaker_1`, …) are per request; `SpeakerLinker` maps them.
    func sarvamDiarize(audio: Data, audioSeconds: Double, language: SarvamLanguage,
                       deadline: TimeInterval) async throws -> [DiarizedWord] {
        let fx = Task { await FXRates.refresh() }
        let parameters: [String: Any] = ["model": Sarvam.sttModel, "mode": "transcribe", "language_code": language.rawValue,
                                         "with_timestamps": true, "with_diarization": true]
        let json = try await sarvamBatch(audio: audio, parameters: parameters, deadline: deadline,
                                         stage: .meetingTranscribe, modelLabel: Sarvam.diarizeModel)
        await fx.value
        UsageMeter.record(stage: .meetingTranscribe, model: Sarvam.diarizeModel, usage: Sarvam.usage(seconds: audioSeconds))
        return Sarvam.diarizedWords(json)
    }

    /// The writing model. Screenshots and audio never reach it: the model
    /// takes text only, and `cleanup` drops them before calling this.
    func sarvamChat(prompt: String, deadline: TimeInterval, stage: UsageStage,
                    jsonObject: Bool = false, jsonSchema: [String: Any]? = nil) async throws -> String {
        // Today's rate for the usage row, fetched alongside the call. A row
        // booked before it lands is back-filled by `UsageMeter`.
        Task { await FXRates.refresh() }
        var body: [String: Any] = [
            "model": Sarvam.chatModel,
            "messages": [["role": "user", "content": prompt]],
            "reasoning_effort": NSNull(),
            "temperature": 0.1,
            "max_tokens": Sarvam.outputBudget(promptCharacters: prompt.count),
        ]
        if jsonObject || jsonSchema != nil {
            // `json_schema` is not documented; `json_object` answered valid
            // JSON for the dictation schema in every probe (2026-10-03).
            body["response_format"] = ["type": "json_object"]
        }
        func send() async throws -> Data {
            try await post(path: "v1/chat/completions", body: try JSONSerialization.data(withJSONObject: body),
                           endpoint: Sarvam.apiBase, deadline: deadline, modelLabel: Sarvam.chatModel,
                           stage: stage, via: .sarvam)
        }
        let data: Data
        do {
            data = try await send()
        } catch TranscriptionError.badRequest(let message) {
            // Over the plan's cap: once more at the cap, which the message
            // names. A Starter plan then gets 4,096 tokens, the API's own
            // ceiling for it, rather than no rewrite at all.
            guard let ceiling = Sarvam.maxTokensCeiling(in: message),
                  ceiling < (body["max_tokens"] as? Int ?? 0) else { throw TranscriptionError.badRequest(message) }
            Log.transcription.info("GeminiClient: sarvam max_tokens capped at \(ceiling, privacy: .public)")
            body["max_tokens"] = ceiling
            data = try await send()
        }
        return try Self.extractGatewayMessage(from: data)
    }

    /// A one-token chat: 200 for a usable key, 403 for a bad one. There is no
    /// cheaper authenticated read.
    public func validateSarvamKey() async -> KeyCheck {
        var request = URLRequest(url: Sarvam.apiBase.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, via: .sarvam)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": Sarvam.chatModel, "max_tokens": 1, "reasoning_effort": NSNull(),
            "messages": [["role": "user", "content": "hi"]],
        ] as [String: Any])
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200, 429: return .valid // a throttled or unfunded key still exists
        case 500...599: return .unreachable
        default: return .rejected(Self.errorMessage(from: data))
        }
    }

    // MARK: - Batch jobs

    /// Runs one file through a batch job and returns its output JSON.
    private func sarvamBatch(audio: Data, parameters: [String: Any], deadline: TimeInterval,
                             stage: UsageStage, modelLabel: String) async throws -> [String: Any] {
        let started = Date()
        func remaining() -> TimeInterval { max(5, deadline - Date().timeIntervalSince(started)) }
        func step(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            let data = try await post(path: path, body: try JSONSerialization.data(withJSONObject: body),
                                      endpoint: Sarvam.apiBase, deadline: min(60, remaining()), modelLabel: modelLabel,
                                      modelIsInPath: false, stage: stage, via: .sarvam)
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw TranscriptionError.network("unparseable_response")
            }
            return json
        }
        let job = try await step("speech-to-text/job/v1", ["job_parameters": parameters])
        guard let jobID = job["job_id"] as? String else { throw TranscriptionError.network("sarvam_no_job_id") }
        let fileName = "0.flac"
        let upload = try await step("speech-to-text/job/v1/upload-files", ["job_id": jobID, "files": [fileName]])
        guard let uploadURL = ((upload["upload_urls"] as? [String: Any])?[fileName] as? [String: Any])?["file_url"] as? String,
              let url = URL(string: uploadURL) else { throw TranscriptionError.network("sarvam_no_upload_url") }
        try await sarvamBlob(.put(audio), url: url, deadline: remaining())
        _ = try await step("speech-to-text/job/v1/\(jobID)/start", [:])

        // 81 s of audio finished in about 6 s; a ten-minute window may take a
        // minute. Sarvam's FAQ asks Starter plans to poll no faster than every
        // 3 s, and a throttled poll waits out the job here rather than letting
        // the caller's retry start a second job.
        // A sleep never runs past the deadline: a long Retry-After ends the
        // job as a timeout instead of waiting it out.
        func pause(_ seconds: TimeInterval) async throws {
            let left = deadline - Date().timeIntervalSince(started)
            guard seconds < left else { throw TranscriptionError.timeout }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        var wait: TimeInterval = 3
        var outputName = "0.json"
        while true {
            let status: [String: Any]
            do {
                status = try await sarvamGet(path: "speech-to-text/job/v1/\(jobID)/status", deadline: min(30, remaining()))
            } catch TranscriptionError.rateLimitedTransient(let retryAfter) {
                try await pause(max(wait, retryAfter ?? 0))
                continue
            }
            switch status["job_state"] as? String {
            case "Completed":
                let detail = (status["job_details"] as? [[String: Any]])?.first
                if detail?["state"] as? String == "Failed" {
                    throw TranscriptionError.network("sarvam_file_failed: \(detail?["error_message"] as? String ?? "")")
                }
                // The output is named by the job, not the input ("0.json" so
                // far); the status lists it.
                if let name = (detail?["outputs"] as? [[String: Any]])?.first?["file_name"] as? String, !name.isEmpty {
                    outputName = name
                }
            case "Failed":
                throw TranscriptionError.network("sarvam_job_failed: \(status["error_message"] as? String ?? "")")
            default:
                try await pause(wait)
                wait = min(5, wait * 1.5)
                continue
            }
            break
        }
        var download: [String: Any] = [:]
        for attempt in 0..<6 {
            do {
                download = try await step("speech-to-text/job/v1/download-files", ["job_id": jobID, "files": [outputName]])
                break
            } catch TranscriptionError.badRequest(let message) where message.contains("not in COMPLETED") {
                // Still pending after the retries is a slow job, not a bad
                // request: the retry queue keeps a `.network` row.
                guard attempt < 5 else { throw TranscriptionError.network("sarvam_output_pending") }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        guard let downloadURL = ((download["download_urls"] as? [String: Any])?[outputName] as? [String: Any])?["file_url"] as? String,
              let url = URL(string: downloadURL) else { throw TranscriptionError.network("sarvam_no_download_url") }
        let data = try await sarvamBlob(.get, url: url, deadline: remaining())
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        return json
    }

    private func sarvamGet(path: String, deadline: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: Sarvam.apiBase.appendingPathComponent(path))
        request.timeoutInterval = deadline
        applyAuth(&request, via: .sarvam)
        let (data, response) = try await Self.sarvamData(for: request, deadline: deadline)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.network("non-http") }
        switch http.statusCode {
        case 200:
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw TranscriptionError.network("unparseable_response")
            }
            return json
        case 403: throw TranscriptionError.auth
        case 429: throw TranscriptionError.rateLimitedTransient(retryAfter: Self.retryDelaySeconds(from: data, headers: http))
        default: throw TranscriptionError.network(Self.errorMessage(from: data) ?? "http_\(http.statusCode)")
        }
    }

    private enum BlobOperation { case put(Data), get }

    /// The signed Azure URLs the job hands out. No Sarvam key goes to Azure.
    @discardableResult
    private func sarvamBlob(_ operation: BlobOperation, url: URL, deadline: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = deadline
        if case .put(let body) = operation {
            request.httpMethod = "PUT"
            request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
            request.setValue("audio/flac", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await Self.sarvamData(for: request, deadline: deadline)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw TranscriptionError.network("sarvam_blob_\((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }

    private static func sarvamData(for request: URLRequest, deadline: TimeInterval) async throws -> (Data, URLResponse) {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await withDeadline(seconds: deadline) { [session, request] in try await session.data(for: request) }
        } catch is DeadlineExceeded {
            throw TranscriptionError.timeout
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: throw TranscriptionError.offline
            case .timedOut: throw TranscriptionError.timeout
            default: throw TranscriptionError.network(error.code.rawValue.description)
            }
        }
    }
}
