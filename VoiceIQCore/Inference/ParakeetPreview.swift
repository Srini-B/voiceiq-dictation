import FluidAudio
import Foundation

/// Display-only live text for Fluid Speech Mini. The model decodes whole
/// utterances and has no streaming state, so the preview re-decodes the open
/// tail of the recording after each chunk. Once the tail outgrows
/// `commitSamples`, the words before the last `holdback` second move into
/// `committed` and the audio under them is dropped at a pause, which keeps
/// every decode under the model's 15 s input. The final transcript never comes
/// from here; `ParakeetSession.transcribe` decodes the saved recording.
struct ParakeetPreview {
    static let sampleRate = 16_000
    /// Decode no sooner than this; shorter audio gives unstable text.
    static let minimumSamples = sampleRate
    /// Commit once the tail reaches 12 s so tail + the next chunk stays under
    /// `ASRConstants.maxModelSamples` (15 s).
    static let commitSamples = 12 * sampleRate
    /// Tokens inside the last second may still change with more audio.
    static let holdback: TimeInterval = 1

    private(set) var committed = ""
    private(set) var tail: [Float] = []
    private var tailText = ""

    var text: String {
        let tail = Self.dropOverlap(tailText, after: committed)
        return committed.isEmpty ? tail : (tail.isEmpty ? committed : committed + " " + tail)
    }

    var isReady: Bool { tail.count >= Self.minimumSamples }

    mutating func append(_ pcm: Data) {
        // Capture supplies little-endian Int16. Avoid aligned loads from Data.
        pcm.withUnsafeBytes { bytes in
            tail.reserveCapacity(tail.count + bytes.count / 2)
            for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
                tail.append(Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32_768)
            }
        }
    }

    /// Applies a decode of the first `decoded` samples of `tail`; more audio
    /// may have arrived while the decode ran.
    mutating func apply(text: String, timings: [TokenTiming], decoded: Int) {
        let decoded = min(decoded, tail.count)
        guard decoded >= Self.commitSamples else {
            tailText = text
            return
        }
        guard let cut = Self.cutPoint(timings, tail: tail[..<decoded]) else {
            // Silence or one long token: keep only the holdback audio.
            commit(text)
            tail.removeFirst(max(0, decoded - Int(Self.holdback * Double(Self.sampleRate))))
            return
        }
        commit(Self.join(timings[..<cut.token]))
        tailText = Self.join(timings[cut.token...])
        tail.removeFirst(cut.sample)
    }

    /// Cuts are only looked for this far back, so the tail after a commit
    /// still spans several seconds of context.
    static let cutWindow: TimeInterval = 6
    /// Energy is measured over 150 ms: a stop consonant's closure is shorter
    /// and so never looks like the pause between phrases.
    static let energyWindow = sampleRate * 3 / 20
    /// Token times are encoder-frame emissions and were seen to run up to two
    /// frames ahead of the audio. A word emitted this soon after the cut may
    /// have been spoken before it, so it is committed; if the kept audio
    /// decodes it again, `dropOverlap` hides the repeat. The other bias would
    /// lose words, which nothing could repair.
    static let lead: TimeInterval = 0.2

    /// Where the tail restarts: the middle of the quietest stretch inside the
    /// cut window, so the next decode starts in a pause rather than inside a
    /// word, and the first word-initial token emitted clearly after it. Nil
    /// when no word starts before the holdback.
    static func cutPoint(_ timings: [TokenTiming], tail: ArraySlice<Float>) -> (token: Int, sample: Int)? {
        let rate = Double(sampleRate)
        let latest = Double(tail.count) / rate - holdback
        let onsets = timings.indices.filter { timings[$0].token.hasPrefix(" ") }
        guard onsets.contains(where: { timings[$0].startTime <= latest }) else { return nil }
        let sample = quietest(tail, from: Int(max(0, latest - cutWindow) * rate), to: Int(latest * rate)) + energyWindow / 2
        let time = Double(sample) / rate
        return (onsets.first(where: { timings[$0].startTime > time + lead }) ?? timings.count, sample)
    }

    /// Start of the lowest-energy `energyWindow` whose start lies in `from..<to`.
    private static func quietest(_ samples: ArraySlice<Float>, from: Int, to: Int) -> Int {
        let upper = min(to, samples.count - energyWindow)
        var best = (sample: max(0, min(from, upper)), energy: Float.greatestFiniteMagnitude)
        guard from <= upper else { return best.sample }
        for start in stride(from: from, through: upper, by: sampleRate / 100) {
            var energy: Float = 0
            for sample in samples[start..<(start + energyWindow)] { energy += sample * sample }
            if energy < best.energy { best = (start, energy) }
        }
        return best.sample
    }

    private mutating func commit(_ text: String) {
        let trimmed = Self.dropOverlap(text.trimmingCharacters(in: .whitespaces), after: committed)
        guard !trimmed.isEmpty else { return }
        committed = committed.isEmpty ? trimmed : committed + " " + trimmed
        tailText = ""
    }

    /// `incoming` without the leading words (up to three) that repeat the end
    /// of `committed`, compared without case or punctuation.
    static func dropOverlap(_ incoming: String, after committed: String) -> String {
        let before = committed.split(separator: " ").suffix(3).map(normalize)
        let words = incoming.split(separator: " ")
        for count in stride(from: min(3, before.count, words.count), through: 1, by: -1)
        where before.suffix(count).elementsEqual(words.prefix(count).map(normalize)) {
            return words.dropFirst(count).joined(separator: " ")
        }
        return incoming
    }

    private static func normalize(_ word: Substring) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Timing tokens already carry SentencePiece boundaries as spaces.
    private static func join(_ timings: ArraySlice<TokenTiming>) -> String {
        timings.map(\.token).joined().trimmingCharacters(in: .whitespaces)
    }
}
