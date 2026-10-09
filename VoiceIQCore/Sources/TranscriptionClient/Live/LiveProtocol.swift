import Foundation

/// What the server said. Deliberately small: everything a streaming API sends
/// that VoiceiQ does not act on becomes no event rather than a case, so an API
/// that grows new message types does not start throwing in the middle of
/// someone's dictation.
public enum LiveEvent: Equatable, Sendable {
    /// The credential was accepted and the session is configured. Audio sent
    /// before this arrives is buffered, not lost.
    case setupComplete
    /// A speculative hypothesis, replaced by later ones. **Display only.**
    /// This must never reach the cursor, History, or `rawTranscript`.
    case partial(String)
    /// More text for an open item's hypothesis (OpenAI sends deltas, not the
    /// whole hypothesis). Display only, like `partial`.
    case itemDelta(itemID: String, text: String)
    /// Authoritative text for the oldest turn the server has not finished
    /// (Gemini: the API has no item IDs and finishes turns in order). Several
    /// may arrive for one turn; they are joined.
    case final(String)
    /// The server finished the oldest unfinished turn (Gemini's
    /// `generationComplete`). Follows that turn's finals.
    case turnComplete
    /// The server took a commit and named the item that holds it (OpenAI).
    /// Commits are acknowledged in the order they were sent, so this fixes
    /// the item's place in the transcript.
    case committed(itemID: String)
    /// The finished transcript of one committed item (OpenAI). Items may
    /// finish out of order; the session places them by `committed`.
    case itemFinal(itemID: String, text: String)
    /// The server is closing the session — the 10-minute cap, or its own reasons.
    case goAway(timeLeft: TimeInterval?)
    /// An error envelope. Terminal for the session.
    case failed(LiveFailure)
}

/// The socket, behind a protocol so every failure mode in this file can be
/// exercised against a scripted fake with no network: setup timeout, mid-stream
/// drop, clean finish, server goAway, double-abort.
///
/// `close()` must be idempotent, must fail any pending `send` or `receive`
/// promptly, and must make a later `connect()` throw.
public protocol LiveTransport: AnyObject, Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

/// How a live session ended. Only `.completed` may replace the real transcript,
/// and even then only after the caller has reconciled `acceptedBytes` against
/// the frames written to disk.
public enum LiveOutcome: Equatable, Sendable {
    /// Clean: setup completed, nothing dropped, the last turn was ended, and
    /// every ended turn has its final transcript.
    case completed(String)
    /// The server heard the whole recording and found no words in it. Not a
    /// live failure: the batch path decides.
    case silent
    /// Anything else. The batch path over the CAF takes over; the words are on
    /// disk regardless. The string is for the log, never for the user.
    case unusable(String)
}

public enum LiveError: Error, Equatable, CustomStringConvertible {
    /// The server answered the setup with an error.
    case refused(String)
    /// No go-ahead within the setup timeout. The socket was closed.
    case setupTimedOut
    /// The session or transport was closed, or the starting task cancelled.
    case aborted

    public var description: String {
        switch self {
        case .refused(let why): return "refused: \(why)"
        case .setupTimedOut: return "setup timed out"
        case .aborted: return "aborted"
        }
    }
}

/// Everything that varies per Gemini Live session.
public struct LiveSetup: Equatable, Sendable {
    public var model: String
    public var smart: Bool
    public var customVocabulary: [String]

    public init(model: String = "gemini-3.5-transcribe-live",
                smart: Bool = true,
                customVocabulary: [String] = []) {
        self.model = model
        self.smart = smart
        self.customVocabulary = customVocabulary
    }
}

/// The wire format of one streaming transcription API. `LiveTranscriptionSession`
/// owns the ring, the send order, turn rollover and the finish rules; a dialect
/// only builds and reads frames, so every one of them is testable without a
/// socket.
public protocol LiveDialect: Sendable {
    /// For usage records.
    var model: String { get }
    /// Nil when the socket URL carries the whole configuration.
    func setupFrame() -> Data?
    /// When a long turn is closed and the next opened, in seconds of audio:
    /// at the first quiet frame after `roll`, and at `hardLimit` regardless.
    var activityRoll: (roll: Int, hardLimit: Int) { get }
    /// Whether a rolled turn must be finished by the server before the next
    /// one opens. Gemini drops a turn it is closing when the next opens at once.
    var waitsForTurnCloseOnRoll: Bool { get }
    /// The shortest turn the API accepts, in bytes of the app's 16 kHz PCM. A
    /// shorter final turn is padded with silence rather than refused.
    var minimumTurnBytes: Int { get }
    /// `pcm` is the app's 16 kHz mono Int16; a dialect resamples if its API
    /// needs another rate.
    func audioFrame(_ pcm: Data) -> Data
    /// Flushes any samples retained by a resampler before committing a turn.
    func audioTailFrame() -> Data?
    /// Nil when the API opens the next turn by itself.
    func activityStartFrame() -> Data?
    func activityEndFrame() -> Data
    /// Every event in one server frame, in the order they must be applied.
    func decode(_ frame: Data) -> [LiveEvent]
    /// Usage the server reported in this frame, if any.
    func reportedUsage(in frame: Data) -> TokenUsage?
    /// What the session cost, from the largest reported usage or, without
    /// one, the audio sent and text received.
    func usage(reported: TokenUsage?, audioSeconds: Double, outputCharacters: Int) -> TokenUsage
}

extension LiveDialect {
    public var activityRoll: (roll: Int, hardLimit: Int) {
        (LiveTranscriptionSession.activityRollSeconds, LiveTranscriptionSession.activityHardLimitSeconds)
    }
    public var waitsForTurnCloseOnRoll: Bool { true }
    public var minimumTurnBytes: Int { 0 }
    public func audioTailFrame() -> Data? { nil }
}

/// Gemini's Live API, through the `LiveProtocol` frames below.
public struct GeminiLiveDialect: LiveDialect {
    public let setup: LiveSetup
    public init(setup: LiveSetup) { self.setup = setup }

    public var model: String { setup.model }
    public func setupFrame() -> Data? { LiveProtocol.setupFrame(setup) }
    public func audioFrame(_ pcm: Data) -> Data { LiveProtocol.audioFrame(pcm) }
    public func activityStartFrame() -> Data? { LiveProtocol.activityStartFrame() }
    public func activityEndFrame() -> Data { LiveProtocol.activityEndFrame() }
    public func decode(_ frame: Data) -> [LiveEvent] { LiveProtocol.decodeAll(frame) }

    /// `usageMetadata` on a server frame, in the REST field names.
    public func reportedUsage(in frame: Data) -> TokenUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              let meta = (root["usageMetadata"] ?? root["usage_metadata"]) as? [String: Any]
        else { return nil }
        return TokenUsage.fromUsageMetadata(meta)
    }

    public func usage(reported: TokenUsage?, audioSeconds: Double, outputCharacters: Int) -> TokenUsage {
        reported ?? TokenUsage.estimated(audioSeconds: audioSeconds, outputCharacters: outputCharacters,
                                         audioTokensPerSecond: PriceBook.audioTokensPerSecond(model: model))
    }
}

/// Frame construction and decoding for the Gemini Live API WebSocket, as pure
/// functions over `Data` so every one of them is testable without a socket.
public enum LiveProtocol {

    public static let audioMIME = "audio/pcm;rate=16000"

    /// The ONLY place a live setup frame is constructed.
    ///
    /// **NEVER add `languageCodes` here without probing it first.** On the
    /// interactions endpoint, sending `language_codes` alongside `mode: smart`
    /// returns VERBATIM output with HTTP 200, no error, and no runtime signal of
    /// any kind — the formatting silently stops happening. Omitting the field is
    /// also what the docs prescribe for automatic language detection.
    ///
    /// Manual VAD is not optional here: VoiceiQ decides turn boundaries from the
    /// hotkey, so server-side voice detection would cut turns in the middle of
    /// someone pausing to think.
    public static func setupFrame(_ setup: LiveSetup) -> Data {
        var transcription: [String: Any] = ["mode": setup.smart ? "SMART" : "VERBATIM"]
        if !setup.customVocabulary.isEmpty {
            transcription["customVocabulary"] = setup.customVocabulary
        }
        return json([
            "setup": [
                "model": "models/\(setup.model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
                "realtimeInputConfig": [
                    "automaticActivityDetection": ["disabled": true],
                ],
            ] as [String: Any],
        ])
    }

    public static func audioFrame(_ pcm: Data) -> Data {
        json(["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": audioMIME]]])
    }

    public static func activityStartFrame() -> Data {
        json(["realtimeInput": ["activityStart": [:] as [String: Any]]])
    }

    public static func activityEndFrame() -> Data {
        json(["realtimeInput": ["activityEnd": [:] as [String: Any]]])
    }

    /// The first event in one server frame; see `decodeAll`.
    public static func decode(_ data: Data) -> LiveEvent? {
        decodeAll(data).first
    }

    /// Decodes every event in one server frame.
    ///
    /// Unrecognised content yields nothing. An unknown message is not a reason
    /// to tear down a session that is otherwise transcribing someone's
    /// sentence; the fallback to the batch path is reserved for failures that
    /// actually cost words.
    ///
    /// A frame can carry a final for the turn that just closed and an interim
    /// for the one that opened. The final comes first, and `turnComplete` last,
    /// so a turn's text is in place before the turn counts as finished.
    public static func decodeAll(_ data: Data) -> [LiveEvent] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        if root["setupComplete"] != nil || root["setup_complete"] != nil {
            return [.setupComplete]
        }
        if let error = root["error"] as? [String: Any] {
            return [.failed(LiveFailure.decode(error))]
        }
        var events: [LiveEvent] = []
        if let away = (root["goAway"] ?? root["go_away"]) as? [String: Any] {
            events.append(.goAway(timeLeft: ((away["timeLeft"] ?? away["time_left"]) as? String).flatMap(LiveFailure.duration)))
        }
        guard let content = (root["serverContent"] ?? root["server_content"]) as? [String: Any] else {
            return events
        }
        if let away = (content["goAway"] ?? content["go_away"]) as? [String: Any] {
            events.append(.goAway(timeLeft: ((away["timeLeft"] ?? away["time_left"]) as? String).flatMap(LiveFailure.duration)))
        }
        if let text = transcriptText(content, "inputTranscription", "input_transcription") {
            events.append(.final(text))
        }
        if let text = transcriptText(content, "interimInputTranscription", "interim_input_transcription") {
            events.append(.partial(text))
        }
        if (content["generationComplete"] ?? content["generation_complete"]) as? Bool == true {
            events.append(.turnComplete)
        }
        return events
    }

    /// True for the frame the server sends once it has finished transcribing a
    /// closed turn.
    public static func isGenerationComplete(_ data: Data) -> Bool {
        decodeAll(data).contains(.turnComplete)
    }

    /// Accepts both camelCase and snake_case because the two documented clients
    /// disagree about which the socket speaks, and guessing wrong here would look
    /// exactly like a model that transcribes nothing.
    private static func transcriptText(_ content: [String: Any], _ camel: String, _ snake: String) -> String? {
        guard let node = (content[camel] ?? content[snake]) as? [String: Any],
              let text = node["text"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }

    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
