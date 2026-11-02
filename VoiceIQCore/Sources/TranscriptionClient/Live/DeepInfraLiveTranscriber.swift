import Foundation

/// Live dictation with Nemotron 3.5 Transcribe on DeepInfra, which only takes
/// whole files and returns no word timings. While recording it sends the open
/// tail of the recording again after each second of new audio, one request at
/// a time, for the pill. Once the tail reaches 12 s, the next request carries
/// only the audio up to the quietest point near its end; that text is locked
/// in and that audio dropped, so no word is heard twice. On stop only the
/// remaining tail is sent, and the transcript is the locked-in text plus that
/// last piece. Every request bills its audio, so a minute of speech costs
/// several minutes. A failed piece or missing audio returns nil, and the saved
/// recording is uploaded as before.
public final class DeepInfraLiveTranscriber: DictationStreaming {
    public let partials: AsyncStream<String>
    private let ring = PCMRing(seconds: 30)
    private let wake: AsyncStream<Void>.Continuation
    private let client: GeminiClient
    private let vocabulary: [String]
    /// Returns the window when cancelled or when it gives up.
    private let pump: Task<Window, Never>

    static let model = AnthropicConfig().transcribeModel
    static let requestDeadline: TimeInterval = 10
    /// Transient errors are skipped; this many in a row end the stream.
    static let maxFailures = 3

    public init(client: GeminiClient, vocabulary: [String]) {
        let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        partials = previews.stream
        wake = signals.continuation
        self.client = client
        self.vocabulary = vocabulary
        let ring = ring
        pump = Task {
            defer { previews.continuation.finish() }
            var window = Window(vocabulary: vocabulary)
            var failures = 0
            for await _ in signals.stream {
                for pcm in ring.drain() { window.append(pcm) }
                guard window.isDue, !Task.isCancelled else { continue }
                let request = window.startRequest()
                do {
                    let text = try await client.deepInfraLiveText(wav: Window.wav(window.tail.prefix(request.bytes)),
                                                                  vocabulary: vocabulary, deadline: Self.requestDeadline)
                    guard !Task.isCancelled else { break }
                    failures = 0
                    window.apply(text, request: request)
                    previews.continuation.yield(String(window.text.suffix(512)))
                } catch {
                    guard !Task.isCancelled else { break }
                    failures += 1
                    Log.transcription.notice("DeepInfra live request failed (\(failures)): \(String(describing: error), privacy: .public)")
                    if failures >= Self.maxFailures {
                        window.gaveUp = true
                        break
                    }
                }
            }
            return window
        }
    }

    public func enqueue(_ pcm: Data) {
        ring.append(pcm)
        wake.yield(())
    }

    public func finish(framesWritten: Int64) async -> TranscriptionResult? {
        // A request in flight is dropped: the last piece covers its audio.
        stop()
        var window = await pump.value
        guard !window.gaveUp else {
            Log.transcription.notice("DeepInfra live fallback: requests kept failing")
            return nil
        }
        for pcm in ring.drain() { window.append(pcm) }
        guard window.received == framesWritten * 2 else {
            Log.transcription.notice("DeepInfra live fallback: received \(window.received) of \(framesWritten * 2) PCM bytes")
            return nil
        }
        var text = window.text
        if window.hasUnheardAudio {
            do {
                text = window.text(withLastPiece: try await client.deepInfraLiveText(
                    wav: Window.wav(window.tail), vocabulary: vocabulary, deadline: Self.requestDeadline))
            } catch {
                Log.transcription.notice("DeepInfra live fallback: last piece failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard !Task.isCancelled else { return nil }
        Log.transcription.notice("DeepInfra live complete: \(window.received) PCM bytes, last piece \(window.tail.count) bytes")
        return TranscriptionResult(rawTranscript: text, cleanedTranscript: text, modelID: Self.model)
    }

    public func abort() async { stop() }

    private func stop() {
        wake.finish()
        pump.cancel()
    }

    /// The locked-in text and the audio after it, as 16 kHz mono
    /// little-endian Int16 PCM.
    struct Window {
        static let sampleRate = 16_000
        static let bytesPerSecond = PCMRing.bytesPerSecond
        /// A shorter clip gives unstable text.
        static let minimumBytes = bytesPerSecond
        /// New audio needed before the next preview.
        static let stepBytes = bytesPerSecond
        static let commitBytes = 12 * bytesPerSecond
        /// The last second may hold a word still being spoken; cuts stay before it.
        static let holdbackBytes = bytesPerSecond
        /// Cuts are looked for this far back from the holdback.
        static let cutWindowBytes = 6 * bytesPerSecond
        /// Loudness is measured in 10 ms blocks.
        static let blockBytes = bytesPerSecond / 100
        /// Silence each piece keeps at a cut. More made Nemotron fill the
        /// silence with a dictionary word from the prompt.
        static let marginBytes = bytesPerSecond / 10

        /// One request: the first `bytes` of `tail`, and `received` when it
        /// started. A commit locks its text in and drops `tail` up to
        /// `resume`, which skips the silence between `bytes` and `resume`.
        struct Request {
            let bytes: Int
            let received: Int64
            var resume: Int?
        }

        /// Single-word dictionary terms, normalized; see `withoutLeakedTerms`.
        let vocabulary: Set<String>
        private(set) var committed = ""
        private(set) var tail = Data()
        /// Every byte appended, for the reconciliation against the saved recording.
        private(set) var received: Int64 = 0
        var gaveUp = false
        private var tailText = ""
        private var requestedAt: Int64 = 0
        /// `received` when a preview last heard the whole tail.
        private var previewedAt: Int64?

        init(vocabulary: [String] = []) {
            self.vocabulary = Set(vocabulary.filter { !$0.contains(" ") }.map { Self.normalize(Substring($0)) })
        }

        var text: String { text(withLastPiece: tailText) }

        func text(withLastPiece piece: String) -> String {
            let piece = withoutLeakedTerms(piece)
            return committed.isEmpty ? piece : (piece.isEmpty ? committed : committed + " " + piece)
        }

        var isDue: Bool { tail.count >= Self.minimumBytes && received - requestedAt >= Int64(Self.stepBytes) }

        var hasUnheardAudio: Bool { !tail.isEmpty && previewedAt != received }

        mutating func append(_ pcm: Data) {
            tail.append(pcm)
            received += Int64(pcm.count)
        }

        mutating func startRequest() -> Request {
            requestedAt = received
            guard tail.count >= Self.commitBytes else {
                return Request(bytes: tail.count, received: received)
            }
            let pause = Self.longestPause(tail)
            return Request(bytes: pause.end, received: received, resume: pause.resume)
        }

        mutating func apply(_ text: String, request: Request) {
            let text = withoutLeakedTerms(text)
            guard let resume = request.resume else {
                tailText = text
                previewedAt = request.received
                return
            }
            if !text.isEmpty { committed = committed.isEmpty ? text : committed + " " + text }
            tail.removeFirst(resume)
            tailText = ""
            previewedAt = nil
            // Preview what is left at once rather than after another second.
            requestedAt = 0
        }

        /// The longest quiet run of 10 ms blocks in the six seconds before
        /// the holdback, so a cut lands between sentences rather than at a
        /// comma or inside a word. A block is quiet up to three times the
        /// quietest block's level, and never above `silenceEnergy`, because
        /// the audio between `end` and `resume` is dropped: `end` keeps
        /// `marginBytes` of the run on the piece before it and `resume` on
        /// the piece after. With no such run (speech over steady noise), the
        /// cut is the middle of the quietest block and nothing is dropped.
        static func longestPause(_ pcm: Data) -> (end: Int, resume: Int) {
            let last = (pcm.count - holdbackBytes) / blockBytes
            let first = max(0, last - cutWindowBytes / blockBytes)
            let levels: [Double] = pcm.withUnsafeBytes { bytes in
                (first..<last).map { block in
                    var energy = 0.0
                    for sample in stride(from: block * blockBytes, to: (block + 1) * blockBytes, by: 2) {
                        let value = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: sample, as: Int16.self)))
                        energy += value * value
                    }
                    return energy
                }
            }
            // 3x the RMS, at least about -62 dBFS and at most about -45 dBFS.
            let quiet = min(max((levels.min() ?? 0) * 9, 1e5), Self.silenceEnergy)
            var best = (start: first, length: 0)
            var run = (start: first, length: 0)
            for (index, level) in levels.enumerated() {
                if level <= quiet {
                    run = run.length == 0 ? (first + index, 1) : (run.start, run.length + 1)
                    if run.length >= best.length { best = run }
                } else {
                    run.length = 0
                }
            }
            guard best.length > 0 else {
                let quietest = levels.indices.min { levels[$0] < levels[$1] } ?? 0
                let cut = (first + quietest) * blockBytes + blockBytes / 2
                return (cut, cut)
            }
            let start = best.start * blockBytes, length = best.length * blockBytes
            let margin = min(marginBytes, length / 2)
            return (start + margin, start + length - margin)
        }

        /// A 10 ms block's energy at about -45 dBFS RMS: quieter than speech,
        /// so audio this quiet can be dropped without losing words.
        static let silenceEnergy = Double(blockBytes / 2) * pow(32_768 * 0.0056, 2)

        /// The piece without a dictionary term that stands alone at its
        /// start or end. Nemotron sometimes writes a word from the `prompt`
        /// into the short silence at a piece's edge ("waveform. VoiceiQ
        /// Third, we…" on 2026-11-02, never in whole-recording uploads). A
        /// leaked term at the start runs straight into a capitalized word;
        /// at the end it follows a sentence end and has no punctuation.
        func withoutLeakedTerms(_ piece: String) -> String {
            var words = piece.split(separator: " ")
            guard words.count > 1, !vocabulary.isEmpty else { return piece }
            func isBareTerm(_ word: Substring) -> Bool {
                word.last.map { $0.isLetter || $0.isNumber } == true && vocabulary.contains(Self.normalize(word))
            }
            if isBareTerm(words[0]), words[1].first?.isUppercase == true { words.removeFirst() }
            if words.count > 1, let last = words.last, isBareTerm(last),
               let before = words[words.count - 2].last, ".?!".contains(before) { words.removeLast() }
            return words.joined(separator: " ")
        }

        static func normalize(_ word: Substring) -> String {
            word.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        /// A 44-byte RIFF header in front of the PCM.
        static func wav(_ pcm: Data) -> Data {
            var data = Data(capacity: 44 + pcm.count)
            func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count))
            data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
            put(UInt32(sampleRate)); put(UInt32(bytesPerSecond)); put(UInt16(2)); put(UInt16(16))
            data.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count))
            data.append(pcm)
            return data
        }
    }
}
