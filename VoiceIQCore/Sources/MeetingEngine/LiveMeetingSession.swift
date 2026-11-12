#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation

/// The transcript the Meetings window shows while ElevenLabs is the
/// transcription provider and a meeting records: the mic and system tracks
/// mixed into one ElevenLabs Scribe v3 Live stream with realtime diarization.
/// It is for watching the call only. The saved transcript is still made from
/// the tracks by Scribe v3 after the meeting stops (`MeetingTranscriber`).
///
/// MEASURED 2026-11-12 on two real four-person meetings from the AMI corpus
/// (180 s each, against its hand-made speaker labels): Scribe v3 Live gave
/// the right speaker to 95.0% and 73.7% of its words, batch Scribe v3 to
/// 93.6% and 67.6%, but Live wrote 8% and 17% fewer words, the most where
/// people talked over each other. Notes need the words, so batch stays.
///
/// From the realtime API reference, the AsyncAPI spec and the guides (read
/// 2026-11-12):
///  - Everything is set in the socket URL (`socketURL`); the server's
///    `session_started` is the go-ahead. Audio goes as `input_audio_chunk`
///    JSON text frames with base64 16 kHz PCM.
///  - `commit_strategy=turn_prediction` (v3 Live only): the server closes a
///    segment when its voice activity detection hears the silence threshold
///    or when the model predicts the speaker finished (`turn_probability` ≥
///    0.9), whichever comes first, so segments end where turns end and the
///    client never commits. MEASURED: 22 segments on 180 s of a four-person
///    meeting.
///  - `diarize=true` (v3 Live only) follows every commit with one
///    `diarized_transcript` `{segment_index, words: [{text, start, end, type,
///    speaker_id}]}`, with times from the start of the session (measured).
///    `speakers_merged` `{from_speaker_id, to_speaker_id}` says two ids were
///    one person: every earlier `from` becomes `to`, merges chain, ids are
///    never reused.
///  - Not with `filter_background_audio` (refused with `diarize`, and the
///    other voices are the meeting) or `transcript_edit` (no word times).
///  - The longest session is not documented (`session_time_limit_exceeded`
///    exists). A failed session shows that it stopped; the recording goes on.
public actor LiveMeetingSession {
    public enum Track: Sendable { case mic, system }

    public static let model = "scribe_v3_live"
    static let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    static let sampleRate = 16_000.0
    /// The realtime API's limits: 50 `keyterms` of up to 20 characters, and
    /// a keyterm library of up to 10,000 terms of up to 50 characters, sent
    /// once in the first audio chunk and billed once with the keyterms.
    static let keytermLimit = 50, keytermCharacters = 20
    static let libraryLimit = 10_000, libraryCharacters = 50
    /// Audio waiting to be sent, in tap buffers; more is dropped.
    static let backlog = 3_000
    static let errorKinds: Set<String> = [
        "error", "auth_error", "quota_exceeded", "commit_throttled", "unaccepted_terms", "rate_limited",
        "queue_overflow", "resource_exhausted", "session_time_limit_exceeded", "input_error", "invalid_request",
        "chunk_size_exceeded", "insufficient_audio_activity", "transcriber_error",
    ]

    public let keyterms: [String]
    public let library: [String]
    private let transport: LiveTransport
    private let onUpdate: @Sendable (LiveMeetingTranscript) -> Void
    private let audio: AsyncStream<(Track, Data)>
    private let input: AsyncStream<(Track, Data)>.Continuation
    private var mix: LiveCallMix
    private var sentSamples = 0
    private var segments: [Int: [DiarizedWord]] = [:]
    private var merges: [String: String] = [:]
    private var lines: [TranscriptSegment] = []
    private var problem: String?
    private var closing = false
    private var sending: Task<Void, Never>?, receiving: Task<Void, Never>?

    init(transport: LiveTransport, vocabulary: [String], tracks: Int,
         onUpdate: @escaping @Sendable (LiveMeetingTranscript) -> Void) {
        self.transport = transport; self.onUpdate = onUpdate
        keyterms = ElevenLabs.keyterms(vocabulary, limit: Self.keytermLimit, maxCharacters: Self.keytermCharacters)
        library = ElevenLabs.keyterms(vocabulary, limit: Self.libraryLimit, maxCharacters: Self.libraryCharacters)
        mix = LiveCallMix(tracks: tracks)
        (audio, input) = AsyncStream.makeStream(of: (Track, Data).self, bufferingPolicy: .bufferingOldest(Self.backlog))
    }

    /// Scribe v3 Live over `key`, with the dictionary and the spoken languages.
    public static func elevenLabs(key: String, tracks: Int, vocabulary: [String], languages: [String],
                                  onUpdate: @escaping @Sendable (LiveMeetingTranscript) -> Void) -> LiveMeetingSession {
        let terms = ElevenLabs.keyterms(vocabulary, limit: keytermLimit, maxCharacters: keytermCharacters)
        let url = socketURL(keyterms: terms, languages: languages)
        let transport = WebSocketTransport(sendsText: true) {
            var request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            return request
        }
        return LiveMeetingSession(transport: transport, vocabulary: vocabulary, tracks: tracks, onUpdate: onUpdate)
    }

    /// One spoken language fixes `language_code`. Several limit detection to
    /// them (`secondary_languages`) and turn on `multilang_mode` (v3 Live
    /// only), which writes each language in its own script, even when the
    /// speaker switches mid-sentence. List values repeat; `+`, `&` and `=`
    /// are escaped so a term cannot split the query.
    static func socketURL(keyterms: [String], languages: [String]) -> URL {
        var items: [(String, String)] = [
            ("model_id", model), ("audio_format", "pcm_16000"), ("commit_strategy", "turn_prediction"),
            ("diarize", "true"), ("no_verbatim", "true"),
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
        return URL(string: "\(endpoint.absoluteString)?\(query)")!
    }

    /// From a tap's audio thread: one converted 16 kHz mono Int16 buffer.
    /// Buffered until `start` connects.
    public nonisolated func push(_ track: Track, _ pcm: Data) {
        input.yield((track, pcm))
    }

    /// Connects and waits for `session_started`.
    public func start(timeout: TimeInterval = 10) async throws {
        let transport = self.transport
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { transport.close() }
        }
        defer { watchdog.cancel() }
        try await transport.connect()
        while true {
            let root = Self.object(try await transport.receive())
            let kind = root?["message_type"] as? String
            if kind == "session_started" { break }
            if let kind, Self.errorKinds.contains(kind) { throw LiveError.aborted }
        }
        receiving = Task { await self.receiveLoop() }
        sending = Task { await self.sendLoop() }
    }

    /// Closes the session when the meeting stops and returns the seconds of
    /// audio sent, which ElevenLabs bills. Nothing waits for the last
    /// segment: the window stops showing this transcript at once, and the
    /// saved one comes from the tracks.
    public func finish() -> Double {
        abort()
        return Double(sentSamples) / Self.sampleRate
    }

    public func abort() {
        closing = true
        input.finish()
        transport.close()
        receiving?.cancel()
    }

    private func sendLoop() async {
        for await (track, pcm) in audio {
            guard problem == nil, !closing else { continue }
            do {
                for chunk in mix.push(track, Self.samples(pcm)) { try await send(chunk) }
            } catch { if !closing { fail("send: \(error)") } }
        }
    }

    private func send(_ chunk: [Int16]) async throws {
        let base64 = chunk.withUnsafeBytes { Data($0) }.base64EncodedString()
        var extra: [String: Any] = [:]
        if sentSamples == 0, library.count > keyterms.count { extra["keyterm_library"] = library }
        try await transport.send(Self.chunk(base64, extra: extra))
        sentSamples += chunk.count
    }

    private func receiveLoop() async {
        while !closing {
            do { handle(try await transport.receive()) } catch {
                if !closing { fail("receive: \(error)") }
                return
            }
        }
    }

    func handle(_ frame: Data) {
        guard let root = Self.object(frame), let kind = root["message_type"] as? String else { return }
        switch kind {
        case "diarized_transcript":
            guard let index = (root["segment_index"] as? NSNumber)?.intValue else { return }
            segments[index] = ElevenLabs.diarizedWords(root)
            publish(partial: "")
        case "speakers_merged":
            guard let from = root["from_speaker_id"] as? String, let to = root["to_speaker_id"] as? String, from != to else { return }
            merges[from] = to
            publish(partial: "")
        case "partial_transcript":
            update(partial: (root["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            if Self.errorKinds.contains(kind) { fail("\(kind): \(root["error"] as? String ?? "no detail")") }
        }
    }

    private func publish(partial: String) {
        lines = SpeakerLinker.turns(timedWords()).map {
            TranscriptSegment(speaker: $0.speaker, text: $0.text, chunkIndex: 0, start: $0.start, end: $0.end)
        }
        update(partial: partial)
    }

    private func update(partial: String) {
        var shown = LiveMeetingTranscript()
        shown.segments = lines; shown.partial = partial; shown.stopped = problem != nil
        onUpdate(shown)
    }

    private func fail(_ why: String) {
        guard problem == nil else { return }
        problem = why
        Log.meeting.error("live meeting transcript stopped: \(why, privacy: .public)")
        update(partial: "")
    }

    /// Diarized words under ids "s1", "s2" in order of first word, after
    /// every merge so far. A word without a speaker keeps the previous one's.
    func timedWords() -> [TimedWord] {
        func resolve(_ speaker: String) -> String {
            var id = speaker, hops = 0
            while let next = merges[id], hops < merges.count { id = next; hops += 1 }
            return id
        }
        var ids: [String: String] = [:], out: [TimedWord] = [], lastKey = "", lastEnd = 0.0
        for index in segments.keys.sorted() {
            for word in segments[index] ?? [] {
                let key = word.speaker.map(resolve) ?? lastKey
                let id = ids[key] ?? "s\(ids.count + 1)"
                ids[key] = id; lastKey = key
                let start = word.start ?? lastEnd
                let end = max(start, word.end ?? start)
                out.append(TimedWord(text: word.text, speaker: id, start: start, end: end))
                lastEnd = end
            }
        }
        return out
    }

    static func object(_ frame: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any]
    }

    static func samples(_ pcm: Data) -> [Int16] {
        var out = [Int16](repeating: 0, count: pcm.count / 2)
        _ = out.withUnsafeMutableBytes { pcm.copyBytes(to: $0) }
        return out
    }

    static func chunk(_ base64: String, extra: [String: Any] = [:]) -> Data {
        let body: [String: Any] = ["message_type": "input_audio_chunk", "audio_base_64": base64, "commit": false,
                                   "sample_rate": Int(sampleRate)]
        return (try? JSONSerialization.data(withJSONObject: body.merging(extra) { first, _ in first })) ?? Data()
    }
}

/// What the Meetings window shows while a meeting records.
public struct LiveMeetingTranscript: Equatable, Sendable {
    /// Finished turns, speakers as "s1", "s2" in order of first word (not
    /// yet "You": the owner is told apart from the tracks after it stops).
    public var segments: [TranscriptSegment] = []
    /// The words of the turn still being heard.
    public var partial = ""
    /// The live session failed; the transcript is made when the meeting stops.
    public var stopped = false
    public init() {}
}

/// The two tracks as one stream, in 100 ms chunks on the recording's
/// timeline. The mic is turned down while the far side talks, as
/// `CallAudio.samples` does, so its echo of the far side is not heard twice.
/// A track more than a second behind the other has lost that audio (a tap
/// delivers in real time or not at all, as when a device reconnects), so it
/// is padded with silence up to the other and what it sends next lines up
/// with now.
struct LiveCallMix {
    static let chunk = 1_600
    static let maxLag = 16_000
    /// About -40 dBFS.
    static let farSpeechRMS = 330.0
    static let duckGain = 0.2
    /// Chunks the mic stays down after the far side stops: the echo tail.
    static let duckHold = 3

    /// 1 records the mic alone (iOS).
    let tracks: Int
    private var mic: [Int16] = [], system: [Int16] = []
    private var ducked = 0

    init(tracks: Int) { self.tracks = tracks }

    mutating func push(_ track: LiveMeetingSession.Track, _ samples: [Int16]) -> [[Int16]] {
        switch track {
        case .mic: mic += samples
        case .system: system += samples
        }
        var out: [[Int16]] = []
        let n = Self.chunk
        while true {
            if tracks == 1 {
                guard mic.count >= n else { break }
                out.append(Array(mic.prefix(n))); mic.removeFirst(n); continue
            }
            if mic.count < n, system.count >= n + Self.maxLag { mic += Array(repeating: 0, count: system.count - mic.count) }
            if system.count < n, mic.count >= n + Self.maxLag { system += Array(repeating: 0, count: mic.count - system.count) }
            guard mic.count >= n, system.count >= n else { break }
            out.append(mixChunk(n))
        }
        return out
    }

    private mutating func mixChunk(_ n: Int) -> [Int16] {
        let far = system.prefix(n), near = mic.prefix(n)
        let rms = (far.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(n)).squareRoot()
        ducked = rms > Self.farSpeechRMS ? Self.duckHold : max(0, ducked - 1)
        let gain = ducked > 0 ? Self.duckGain : 1
        let mixed = zip(far, near).map { Int16(clamping: Int((Double($0) + gain * Double($1)).rounded())) }
        system.removeFirst(n); mic.removeFirst(n)
        return mixed
    }
}

#if canImport(AVFoundation)
extension AVAudioPCMBuffer {
    /// The samples of a mono interleaved Int16 buffer.
    var int16Data: Data {
        guard let channel = int16ChannelData else { return Data() }
        return Data(bytes: channel[0], count: Int(frameLength) * MemoryLayout<Int16>.size)
    }
}
#endif
