import Foundation

/// ElevenLabs Scribe v3 Live for dictation, the streaming twin of the batch
/// Scribe v3 request: the recording streams while the key is down and one
/// commit at key-up closes the turn.
///
/// Unlike `LiveMeetingSession`, which lets the server end segments
/// (`turn_prediction`) and diarizes, dictation commits by hand
/// (`commit_strategy=manual`): the hotkey decides where a turn ends, as with
/// Gemini and OpenAI.
///
/// MEASURED 2026-11-18 on 3–22 s clips streamed in real time: the
/// `committed_transcript` arrived 64–141 ms after the commit, against
/// 1.5–2.2 s for the batch request after key-up on the user's MacBook. An
/// empty `input_audio_chunk` with `commit: true` commits what was sent. Every
/// frame is JSON with a `message_type`; the server opens with
/// `session_started`.
public struct ElevenLabsLiveDialect: LiveDialect {
    public let model = LiveMeetingSession.model
    public let smart: Bool
    public let keyterms: [String]
    public let languages: [String]

    public init(smart: Bool, vocabulary: [String], languages: [String]) {
        self.smart = smart
        self.keyterms = ElevenLabs.keyterms(vocabulary, limit: LiveMeetingSession.keytermLimit,
                                            maxCharacters: LiveMeetingSession.keytermCharacters)
        self.languages = languages
    }

    /// Everything is set in the socket URL. Smart drops fillers and false
    /// starts (`no_verbatim`); the writing model or nothing formats after it.
    var socketURL: URL {
        var items: [(String, String)] = [
            ("model_id", model), ("audio_format", "pcm_16000"), ("commit_strategy", "manual"),
            ("no_verbatim", smart ? "true" : "false"),
        ]
        if languages.count == 1 { items.append(("language_code", languages[0])) }
        if languages.count > 1 {
            items += languages.map { ("secondary_languages", $0) }
            items.append(("multilang_mode", "true"))
        }
        items += keyterms.map { ("keyterms", $0) }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let query = items.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return URL(string: "\(LiveMeetingSession.endpoint.absoluteString)?\(query)")!
    }

    public func transport(apiKey: @escaping @Sendable () -> String) -> WebSocketTransport {
        let url = socketURL
        return WebSocketTransport(sendsText: true) {
            var request = URLRequest(url: url)
            request.setValue(apiKey(), forHTTPHeaderField: "xi-api-key")
            return request
        }
    }

    /// MEASURED 2026-11-18: even with `commit_strategy=manual`, Scribe
    /// commits by itself once a turn holds about 35 s of audio. That commit
    /// would complete the turn the key-up closes before its last words
    /// arrive, so the client commits first: at a pause after 25 s, and at
    /// 30 s regardless. Streaming with a commit every 30 s drew no extra
    /// commit from the server.
    public var activityRoll: (roll: Int, hardLimit: Int) { (25, 30) }
    /// If the server ever commits sooner than measured, the session sees a
    /// commit it did not ask for and falls back to the batch upload.
    public var completesOnlyClosedTurns: Bool { true }

    public func setupFrame() -> Data? { nil }
    public func activityStartFrame() -> Data? { nil }
    public func audioFrame(_ pcm: Data) -> Data { Self.chunk(pcm, commit: false) }
    public func activityEndFrame() -> Data { Self.chunk(Data(), commit: true) }

    static func chunk(_ pcm: Data, commit: Bool) -> Data {
        LiveProtocol.json(["message_type": "input_audio_chunk", "audio_base_64": pcm.base64EncodedString(),
                           "commit": commit, "sample_rate": Int(LiveMeetingSession.sampleRate)])
    }

    public func decode(_ frame: Data) -> [LiveEvent] {
        guard let root = LiveMeetingSession.object(frame), let kind = root["message_type"] as? String else { return [] }
        switch kind {
        case "session_started":
            return [.setupComplete]
        case "partial_transcript":
            let text = (root["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.partial(text)]
        case "committed_transcript":
            let text = (root["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [.turnComplete] : [.final(text), .turnComplete]
        default:
            guard LiveMeetingSession.errorKinds.contains(kind) else { return [] }
            let message = root["error"] as? String ?? kind
            switch kind {
            case "auth_error": return [.failed(LiveFailure(status: 401, code: kind, message: message))]
            case "quota_exceeded": return [.failed(LiveFailure(status: 402, code: kind, message: message))]
            default: return [.failed(LiveFailure(code: kind, message: message))]
            }
        }
    }

    public func reportedUsage(in frame: Data) -> TokenUsage? { nil }

    /// Billed by the audio sent, like the meeting stream.
    public func usage(reported: TokenUsage?, audioSeconds: Double, outputCharacters: Int) -> TokenUsage {
        var usage = ElevenLabs.usage(model: model, seconds: audioSeconds, keyterms: !keyterms.isEmpty)
            ?? TokenUsage.estimated(audioSeconds: audioSeconds, outputCharacters: outputCharacters)
        usage.isEstimated = true
        return usage
    }
}
