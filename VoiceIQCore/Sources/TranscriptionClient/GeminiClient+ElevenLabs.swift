import Foundation

/// ElevenLabs Scribe: speech-to-text only, used in place of the provider's
/// transcription model when Settings picks it (`TranscriptionSource`).
///
/// From the API reference (elevenlabs.io/docs/api-reference/speech-to-text,
/// read 2026-09-28; not yet run against a real key):
///  - Batch: `POST /v1/speech-to-text`, multipart, `xi-api-key` header,
///    `model_id=scribe_v2`. FLAC is accepted. The response is
///    `{text, language_code, words, audio_duration_secs?}` with no usage block,
///    so the call is priced here from the audio length.
///  - `keyterms` bias recognition, repeated once per term as in the official
///    SDKs. Each must be under 50 characters and at most five words, without
///    `< > { } [ ] \`. They add $0.05 an hour, and more than 100 of them make
///    every request bill at least 20 s, so at most 100 are sent.
///  - `tag_audio_events=false` keeps "(laughter)" out of the text;
///    `no_verbatim=true` drops fillers and false starts, which is what smart
///    mode means on Gemini.
///  - Errors: `{"detail": {"type", "code", "message"}}`; 401 bad key, 402 no
///    credits, 422 schema validation, 429 rate or concurrency limits.
public enum ElevenLabs {
    public static let batchModel = "scribe_v2"
    static let apiBase = URL(string: "https://api.elevenlabs.io/v1")!

    static let batchKeytermLimit = 100
    static let batchKeytermCharacters = 49

    /// Dictionary terms ElevenLabs will accept, in dictionary order, deduped.
    static func keyterms(_ vocabulary: [String], limit: Int, maxCharacters: Int) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in vocabulary {
            let term = raw.replacingOccurrences(of: #"[<>{}\[\]\\\r\n]"#, with: " ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty, term.count <= maxCharacters,
                  term.split(separator: " ").count <= 5,
                  seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == limit { break }
        }
        return terms
    }

    /// The spoken words of a diarized response; spacing and audio events are dropped.
    static func diarizedWords(_ json: [String: Any]) -> [DiarizedWord] {
        let words = json["words"] as? [[String: Any]] ?? []
        return words.compactMap { word in
            guard (word["type"] as? String ?? "word") == "word",
                  let text = (word["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return DiarizedWord(text: text, speaker: word["speaker_id"] as? String,
                                start: (word["start"] as? NSNumber)?.doubleValue,
                                end: (word["end"] as? NSNumber)?.doubleValue)
        }
    }

    /// What a batch transcription costs: the list price for its audio plus
    /// the keyterm add-on when terms were sent.
    static func batchUsage(seconds: Double, withKeyterms: Bool) -> TokenUsage? {
        guard var usage = TokenUsage.fromAudioMinutes(seconds: seconds, model: batchModel) else { return nil }
        if withKeyterms {
            usage.reportedCostUSD = (usage.reportedCostUSD ?? 0) + seconds / 60 * PriceBook.elevenLabsKeytermsPerMinute
        }
        return usage
    }
}

extension GeminiClient {
    /// One recording to Scribe v2. `audioSeconds` prices the call when the
    /// response leaves out `audio_duration_secs`.
    func elevenLabsTranscribe(audio: Data, keyterms vocabulary: [String], noVerbatim: Bool,
                              audioSeconds: Double, deadline: TimeInterval) async throws -> String {
        let keyterms = ElevenLabs.keyterms(vocabulary, limit: ElevenLabs.batchKeytermLimit,
                                           maxCharacters: ElevenLabs.batchKeytermCharacters)
        var form = MultipartForm()
        form.field("model_id", ElevenLabs.batchModel)
        form.file("file", filename: "audio.flac", mimeType: "audio/flac", data: audio)
        form.field("tag_audio_events", "false")
        form.field("timestamps_granularity", "none")
        form.field("diarize", "false")
        if noVerbatim { form.field("no_verbatim", "true") }
        for term in keyterms { form.field("keyterms", term) }
        let data = try await post(path: "speech-to-text", body: form.body, endpoint: ElevenLabs.apiBase,
                                  deadline: deadline, modelLabel: ElevenLabs.batchModel, stage: .transcribe,
                                  via: .elevenLabs, extraHeaders: ["Content-Type": form.contentType])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let json else { throw TranscriptionError.network("unparseable_response") }
        let seconds = (json["audio_duration_secs"] as? NSNumber)?.doubleValue ?? audioSeconds
        if let usage = ElevenLabs.batchUsage(seconds: seconds, withKeyterms: !keyterms.isEmpty) {
            UsageMeter.record(stage: .transcribe, model: ElevenLabs.batchModel, usage: usage)
        }
        return (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Speaker-labelled, word-timed transcript of one meeting window from
    /// Scribe v2. Labels (`speaker_0`, …) are per request, like Gemini's
    /// native diarizer, so the caller links them through anchor clips.
    func elevenLabsDiarize(audio: Data, audioSeconds: Double, deadline: TimeInterval) async throws -> [DiarizedWord] {
        var form = MultipartForm()
        form.field("model_id", ElevenLabs.batchModel)
        form.file("file", filename: "audio.flac", mimeType: "audio/flac", data: audio)
        form.field("tag_audio_events", "false")
        form.field("timestamps_granularity", "word")
        form.field("diarize", "true")
        let data = try await post(path: "speech-to-text", body: form.body, endpoint: ElevenLabs.apiBase,
                                  deadline: deadline, modelLabel: ElevenLabs.batchModel, stage: .meetingTranscribe,
                                  via: .elevenLabs, extraHeaders: ["Content-Type": form.contentType])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        let seconds = (json["audio_duration_secs"] as? NSNumber)?.doubleValue ?? audioSeconds
        if let usage = ElevenLabs.batchUsage(seconds: seconds, withKeyterms: false) {
            UsageMeter.record(stage: .meetingTranscribe, model: ElevenLabs.batchModel, usage: usage)
        }
        return ElevenLabs.diarizedWords(json)
    }

    /// `GET /v1/user`: 200 for a usable key. A key scoped to speech-to-text
    /// only is refused this read for a missing permission, which still proves
    /// the key exists, so that answer counts as valid. A bad key answers 401
    /// with `code: unauthorized, status: invalid_api_key` (checked 2026-09-28).
    public func validateElevenLabsKey() async -> KeyCheck {
        var request = URLRequest(url: ElevenLabs.apiBase.appendingPathComponent("user"))
        request.timeoutInterval = 10
        applyAuth(&request, via: .elevenLabs)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200: return .valid
        case 500...599: return .unreachable
        case 401, 403:
            let detail = Self.elevenLabsErrorDetail(from: data)
            if (detail.kinds + [detail.message ?? ""]).contains(where: { $0.lowercased().contains("permission") }) { return .valid }
            return .rejected(detail.message)
        default: return .rejected(Self.elevenLabsErrorDetail(from: data).message)
        }
    }

    /// `detail` is an object (`type`, `code`, the legacy `status`, and
    /// `message`), a string, or FastAPI's list of validation errors.
    static func elevenLabsErrorDetail(from data: Data) -> (kinds: [String], message: String?) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch root?["detail"] {
        case let detail as [String: Any]:
            return (["type", "code", "status"].compactMap { detail[$0] as? String }, detail["message"] as? String)
        case let detail as String:
            return ([], detail)
        case let list as [[String: Any]]:
            return (["invalid_parameters"], list.first?["msg"] as? String)
        default:
            return ([], nil)
        }
    }

    /// `quota_exceeded` (legacy `status`, now `code`) or the `payment_required`
    /// type: the key works, the credit balance does not.
    static func isElevenLabsQuota(_ detail: (kinds: [String], message: String?)) -> Bool {
        detail.kinds.contains { kind in
            let lower = kind.lowercased()
            return lower.contains("quota") || lower.contains("payment") || lower.contains("credit")
        }
    }
}
