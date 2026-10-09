import Foundation

/// `audio.input.transcription.delay` on an OpenAI realtime transcription
/// session: lower shows words sooner, higher hears more context first.
public enum OpenAILiveDelay: String, CaseIterable, Sendable {
    case minimal, low, medium, high, xhigh
}

/// OpenAI's realtime transcription session (`gpt-live-transcribe`), over
/// `WebSocketTransport.openAIEndpoint`.
///
/// Per developers.openai.com/api/docs/guides/realtime-transcription (read
/// 2026-10-08) and a probe on 2026-09-28:
///  - The server sends `session.created`, then `session.updated` once our
///    configuration applies; the latter is the go-ahead.
///  - `audio/pcm` at 24 kHz. 16 kHz is rejected (`integer_below_min_value`),
///    so the app's 16 kHz capture is resampled here.
///  - `turn_detection` must be `null`: the model supports neither server nor
///    semantic VAD, and the hotkey decides turns anyway.
///    `input_audio_buffer.commit` ends a turn.
///  - Completion events from different turns may arrive in any order. Each
///    commit is acknowledged by `input_audio_buffer.committed` with the
///    item's ID, and the session orders finals by those acknowledgements.
///
/// Create one dialect per session: the resampler carries state between frames.
public struct OpenAILiveDialect: LiveDialect {
    public let model: String
    public let delay: OpenAILiveDelay
    public let keywords: [String]
    private let resampler = PCMResampler16to24()

    static let sampleRate = 24_000
    /// The realtime API refuses to commit less than 100 ms of audio.
    static let minimumCommitBytes = PCMRing.bytesPerSecond / 10

    public init(model: String = "gpt-live-transcribe", delay: OpenAILiveDelay = .low, keywords: [String] = []) {
        self.model = model
        self.delay = delay
        self.keywords = GeminiClient.openAIKeywords(keywords)
    }

    /// Every item is ordered by its commit, so a rolled turn need not wait.
    public var waitsForTurnCloseOnRoll: Bool { false }
    public var minimumTurnBytes: Int { Self.minimumCommitBytes }

    public func setupFrame() -> Data? {
        var transcription: [String: Any] = ["model": model, "delay": delay.rawValue]
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        return LiveProtocol.json([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": Self.sampleRate],
                    "transcription": transcription,
                    "turn_detection": NSNull(),
                ] as [String: Any]],
            ] as [String: Any],
        ])
    }

    public func audioFrame(_ pcm: Data) -> Data {
        LiveProtocol.json(["type": "input_audio_buffer.append", "audio": resampler.process(pcm).base64EncodedString()])
    }

    public func activityStartFrame() -> Data? { nil }

    public func audioTailFrame() -> Data? {
        let tail = resampler.flush()
        guard !tail.isEmpty else { return nil }
        return LiveProtocol.json(["type": "input_audio_buffer.append", "audio": tail.base64EncodedString()])
    }

    public func activityEndFrame() -> Data { LiveProtocol.json(["type": "input_audio_buffer.commit"]) }

    public func decode(_ frame: Data) -> [LiveEvent] {
        guard let root = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              let type = root["type"] as? String else { return [] }
        let itemID = root["item_id"] as? String
        switch type {
        case "session.updated":
            return [.setupComplete]
        case "error":
            return [.failed(LiveFailure.decode(root["error"]))]
        case "input_audio_buffer.committed":
            guard let itemID else { return [.failed(LiveFailure(message: "commit acknowledged without an item ID"))] }
            return [.committed(itemID: itemID)]
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID, let delta = root["delta"] as? String, !delta.isEmpty else { return [] }
            return [.itemDelta(itemID: itemID, text: delta)]
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID else { return [.failed(LiveFailure(message: "transcript without an item ID"))] }
            // An empty transcript is a finished, silent turn.
            let text = (root["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return [.itemFinal(itemID: itemID, text: text)]
        case "conversation.item.input_audio_transcription.failed":
            return [.failed(LiveFailure.decode(root["error"]))]
        default:
            return []
        }
    }

    /// Billing is by the audio sent, so the session total is computed from
    /// that instead of from per-turn reports.
    public func reportedUsage(in frame: Data) -> TokenUsage? { nil }

    public func usage(reported: TokenUsage?, audioSeconds: Double, outputCharacters: Int) -> TokenUsage {
        var usage = TokenUsage.fromAudioMinutes(seconds: audioSeconds, model: model)
            ?? TokenUsage.estimated(audioSeconds: audioSeconds, outputCharacters: outputCharacters)
        usage.isEstimated = true
        return usage
    }

    /// 16 kHz → 24 kHz in one shot, for callers outside a session.
    static func upsample16to24(_ pcm: Data) -> Data {
        let resampler = PCMResampler16to24()
        return resampler.process(pcm) + resampler.flush()
    }
}

/// 16 kHz → 24 kHz mono Int16 by linear interpolation, continuous across
/// frames. It keeps the previous frame's last sample, so each frame's first
/// output interpolates against real audio, not a held edge. At most one output
/// sample waits for the next frame.
final class PCMResampler16to24: @unchecked Sendable {
    private let lock = NSLock()
    /// The last input sample of the previous frame.
    private var carry: Int16?
    /// Position of the next output sample in thirds of an input sample,
    /// relative to `carry` (or to the frame's first sample when there is none).
    private var position = 0

    func process(_ pcm: Data) -> Data {
        let count = pcm.count / 2
        guard count > 0 else { return Data() }
        lock.lock(); defer { lock.unlock() }
        var input: [Int16] = []
        input.reserveCapacity(count + 1)
        if let carry { input.append(carry) }
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                input.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
            }
        }
        var output: [Int16] = []
        output.reserveCapacity(count * 3 / 2 + 1)
        while position / 3 + 1 < input.count {
            let lower = position / 3
            let fraction = Double(position % 3) / 3
            let value = Double(input[lower]) * (1 - fraction) + Double(input[lower + 1]) * fraction
            output.append(Int16(value.rounded()))
            position += 2
        }
        position -= 3 * (input.count - 1)
        carry = input.last
        return output.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The held sample, when a stream ends on it.
    func flush() -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let carry else { return Data() }
        var output: [Int16] = []
        while position < 3 {
            output.append(carry.littleEndian)
            position += 2
        }
        self.carry = nil
        position = 0
        return output.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
