import Foundation

// A Swift port, for measurement only, of the parts of Hex's offline meeting
// pass that differ from VoiceiQ's: how a track is cut into chunks, how the
// chunks' words are joined, and how microphone lines that echo the far side
// are dropped. Ported from Hex (github.com/anomalyco/hex, MIT, Copyright (c)
// 2026 Christopher Langton) at b67dd262: src/meeting/transcript.rs,
// src/meeting/chunk_level.rs, src/meeting/echo.rs and
// src/transcription/pause_segmenter.rs. Constants and rules are Hex's.

enum Hex {
    static let rate = 16_000
    static let frame = rate / 50

    static func ms(_ samples: Int) -> Int { samples * 1_000 / rate }
}

// MARK: - Pauses (pause_segmenter.rs)

/// Speech is a 20 ms frame at least 12 dB above an adaptive noise floor and
/// never quieter than -55 dBFS. The floor falls at once and rises slowly.
struct SpeechFrames {
    private var floorDB: Float?

    mutating func isSpeech(_ frame: ArraySlice<Float>) -> Bool {
        let count = Float(frame.count)
        let mean = frame.reduce(0, +) / count
        let energy = frame.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / count
        let level = energy.isFinite ? 10 * log10(max(energy, 1e-18)) : 0
        let floor: Float
        if let current = floorDB, level >= current { floor = current + 0.06 } else { floor = max(level, -90) }
        floorDB = floor
        return level > max(floor + 12, -55)
    }
}

/// A cut in the middle of a pause: 600 ms of quiet once a piece is 3 s long,
/// 300 ms once it is 8 s long.
struct PauseSegmenter {
    private var speech = SpeechFrames()
    private var position = 0, pieceStart = 0, silentFrames = 0, heardSpeech = false

    mutating func push(_ frame: ArraySlice<Float>) -> Int? {
        position += Hex.frame
        if speech.isSpeech(frame) {
            silentFrames = 0
            heardSpeech = true
            return nil
        }
        silentFrames += 1
        let piece = position - pieceStart
        let pause = piece >= 8 * Hex.rate ? Hex.rate * 3 / 10 : Hex.rate * 6 / 10
        guard heardSpeech, piece >= 3 * Hex.rate, silentFrames * Hex.frame >= pause else { return nil }
        let cut = position - silentFrames * Hex.frame / 2
        pieceStart = cut
        silentFrames = 0
        heardSpeech = false
        return cut
    }
}

// MARK: - A quiet microphone (chunk_level.rs)

/// The track's loud level over its last minute, a second at a time, each
/// second at the level two of its frames reached.
struct TrackLevel {
    private var blocks: [Float] = []
    private var loudest = -Float.infinity, second = -Float.infinity
    private var samples = 0

    mutating func hear(_ frame: ArraySlice<Float>) {
        let energy = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)
        let level = max(10 * log10(max(energy, 1e-12)), -120)
        if level > loudest { second = loudest; loudest = level } else if level > second { second = level }
        samples += frame.count
        if samples >= Hex.rate {
            samples -= Hex.rate
            if blocks.count == 60 { blocks.removeFirst() }
            blocks.append(second)
            loudest = -.infinity
            second = -.infinity
        }
    }

    /// One for a normal, silent or unheard track; otherwise a raise of up to 30 dB towards -20 dBFS.
    var gain: Float {
        guard let loud = (blocks + [second]).filter(\.isFinite).max(), loud < -35, loud >= -60 else { return 1 }
        return pow(10, min(-20 - loud, 30) / 20)
    }

    /// Every 20 ms frame is under -60 dBFS.
    static func silent(_ samples: [Float]) -> Bool {
        let threshold = pow(Float(10), -6)
        return stride(from: 0, to: samples.count, by: Hex.frame).allSatisfy { start in
            let frame = samples[start..<min(samples.count, start + Hex.frame)]
            return frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count) < threshold
        }
    }

    static func raise(_ samples: inout [Float], gain: Float) {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let limited = peak > 0 ? min(gain, 0.891 / peak) : gain
        guard limited > 1 else { return }
        for index in samples.indices { samples[index] = min(1, max(-1, samples[index] * limited)) }
    }
}

// MARK: - Chunks (transcript.rs, Chunker)

struct HexChunk {
    /// Offset of `samples[0]` in the track.
    var start: Int
    /// Leading samples shared with the previous chunk.
    var overlap: Int
    /// Trailing samples the next chunk hears again.
    var tail: Int
    var samples: [Float]
}

/// Chunks end at the first pause after 6 s. Without one by 10 s the chunk is
/// cut there and the next one starts 2 s earlier.
struct HexChunker {
    static let minimum = Hex.rate * 3, target = Hex.rate * 6, maximum = Hex.rate * 10
    static let overlapSamples = Hex.rate * 2, minimumTail = Hex.rate * 3 / 10

    private var buffer: [Float] = []
    private var bufferStart = 0, chunkStart = 0, overlap = 0
    private var segmenter = PauseSegmenter()
    private var pauses: [Int] = []
    private var level = TrackLevel()
    /// Only the microphone's chunks are raised.
    let raises: Bool

    init(microphone: Bool) { raises = microphone }

    private var end: Int { bufferStart + buffer.count }

    mutating func push(_ samples: ArraySlice<Float>) -> [HexChunk] {
        var start = samples.startIndex
        while start < samples.endIndex {
            let frame = samples[start..<min(samples.endIndex, start + Hex.frame)]
            // The segmenter waits for a whole frame; a last partial one never completes.
            if frame.count == Hex.frame, let cut = segmenter.push(frame) { pauses.append(cut) }
            if raises { level.hear(frame) }
            start += Hex.frame
        }
        buffer.append(contentsOf: samples)
        var chunks: [HexChunk] = []
        while let chunk = next() { chunks.append(chunk) }
        return chunks
    }

    /// The rest of the audio as one last chunk, when at least 0.3 s follows the previous one.
    func finish() -> HexChunk? {
        end >= chunkStart + Self.minimumTail ? chunk(from: chunkStart - overlap, to: end, tail: 0) : nil
    }

    private func chunk(from begin: Int, to cut: Int, tail: Int) -> HexChunk {
        var samples = Array(buffer[(begin - bufferStart)..<(cut - bufferStart)])
        if raises, !TrackLevel.silent(samples) { TrackLevel.raise(&samples, gain: level.gain) }
        return HexChunk(start: begin, overlap: overlap, tail: tail, samples: samples)
    }

    private mutating func next() -> HexChunk? {
        let start = chunkStart
        pauses.removeAll { $0 < start + Self.minimum }
        let limit = start + Self.maximum
        let cut: Int, nextOverlap: Int
        if let preferred = pauses.first(where: { $0 >= start + Self.target && $0 <= min(limit, end) }) {
            (cut, nextOverlap) = (preferred, 0)
        } else if end >= limit {
            if let pause = pauses.last(where: { $0 <= limit }) { (cut, nextOverlap) = (pause, 0) } else { (cut, nextOverlap) = (limit, Self.overlapSamples) }
        } else {
            return nil
        }
        let made = chunk(from: start - overlap, to: cut, tail: nextOverlap)
        let keepFrom = cut - nextOverlap
        buffer.removeFirst(keepFrom - bufferStart)
        bufferStart = keepFrom
        chunkStart = cut
        overlap = nextOverlap
        return made
    }
}

// MARK: - Joining chunks (transcript.rs, TrackTranscript)

struct HexWord: Equatable {
    var startMs: Int
    var endMs: Int
    var text: String
}

/// One sentence of one track.
struct HexEntry: Equatable {
    var microphone: Bool
    var startMs: Int
    var endMs: Int
    var words: [HexWord]
    var text: String { words.map(\.text).joined(separator: " ") }
}

struct HexTrackTranscript {
    static let sentencePauseMs = 600, seamMaxWords = 12, seamAnchorMs = 300

    let microphone: Bool
    private(set) var entries: [HexEntry] = []
    /// Words of a sentence the next chunk can still change.
    private var words: [HexWord] = []
    private var settledMs = 0

    init(microphone: Bool) { self.microphone = microphone }

    /// `timed` are the chunk's words with times from the chunk's start.
    mutating func accept(_ chunk: HexChunk, words timed: [HexWord]) {
        let chunkMs = Hex.ms(chunk.start), durationMs = Hex.ms(chunk.samples.count)
        let nextSeam = chunkMs + durationMs - Hex.ms(chunk.tail) / 2
        settledMs = max(settledMs, nextSeam)
        guard !timed.isEmpty || !words.isEmpty else { return finish() }
        var incoming = timed.compactMap { word -> HexWord? in
            let text = word.text.trimmingCharacters(in: .whitespaces)
            let start = min(max(word.startMs, 0), durationMs)
            let end = min(max(word.endMs, start), durationMs)
            return text.isEmpty ? nil : HexWord(startMs: chunkMs + start, endMs: chunkMs + end, text: text)
        }
        if chunk.overlap > 0, let (kept, skipped) = Self.seamAnchor(words, incoming, overlapStartMs: chunkMs, overlapMs: Hex.ms(chunk.overlap)) {
            words.removeLast(words.count - kept)
            incoming.removeFirst(skipped)
        } else if chunk.overlap > 0 {
            let seam = chunkMs + Hex.ms(chunk.overlap) / 2
            words.removeAll { $0.startMs >= seam }
            incoming.removeAll { $0.startMs < seam }
            let previous = words.isEmpty
                ? (entries.last?.words.map { Self.normalize($0.text) } ?? [])
                : words.map { Self.normalize($0.text) }
            incoming.removeFirst(Self.repeatedPrefix(previous, incoming.map { Self.normalize($0.text) }))
        }
        words += incoming
        publish(seamMs: nextSeam, all: chunk.tail == 0)
    }

    mutating func finish() {
        if let end = words.map(\.endMs).max() { settledMs = max(settledMs, end + 1) }
        publish(seamMs: settledMs, all: true)
    }

    /// Sentences no later chunk can change become entries: all of them when
    /// nothing overlaps the next chunk, else those wholly before the seam and
    /// closed by punctuation or a later sentence.
    private mutating func publish(seamMs: Int, all: Bool) {
        let groups = Self.sentenceGroups(words)
        var published = groups.count
        if !all {
            published = 0
            for (index, group) in groups.enumerated() {
                let closed = Self.endsSentence(words[group.upperBound - 1].text)
                    || (index + 1 < groups.count && words[groups[index + 1].lowerBound].startMs < seamMs)
                guard words[group].allSatisfy({ $0.startMs < seamMs }), closed else { break }
                published += 1
            }
        }
        for group in groups.prefix(published) {
            let sentence = Array(words[group])
            entries.append(HexEntry(microphone: microphone, startMs: sentence[0].startMs,
                                    endMs: sentence.map(\.endMs).max() ?? 0, words: sentence))
        }
        words.removeFirst(published < groups.count ? groups[published].lowerBound : words.count)
    }

    static func endsSentence(_ text: String) -> Bool { text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") }

    /// A sentence ends after sentence punctuation or before a 600 ms pause.
    static func sentenceGroups(_ words: [HexWord]) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        for (index, word) in words.enumerated() {
            if let group = groups.last, !endsSentence(words[group.upperBound - 1].text),
               word.startMs - (words[group].map(\.endMs).max() ?? 0) < sentencePauseMs {
                groups[groups.count - 1] = group.lowerBound..<(index + 1)
            } else {
                groups.append(index..<(index + 1))
            }
        }
        return groups
    }

    /// A word both chunks heard in their overlap within 300 ms of each other,
    /// nearest the overlap's middle: how many pending words to keep and how
    /// many incoming ones to skip.
    static func seamAnchor(_ previous: [HexWord], _ incoming: [HexWord], overlapStartMs: Int, overlapMs: Int) -> (Int, Int)? {
        let end = overlapStartMs + overlapMs, middle = overlapStartMs + overlapMs / 2
        let inOverlap = { (word: HexWord) in word.startMs >= overlapStartMs && word.startMs < end }
        var best: (distance: Int, kept: Int, skipped: Int)?
        for (kept, old) in previous.enumerated() where inOverlap(old) {
            let oldText = normalize(old.text)
            guard !oldText.isEmpty else { continue }
            for (skipped, new) in incoming.enumerated() where inOverlap(new) {
                guard abs(old.startMs - new.startMs) <= seamAnchorMs, normalize(new.text) == oldText else { continue }
                let distance = abs(old.startMs - middle)
                if best == nil || distance < best!.distance { best = (distance, kept + 1, skipped + 1) }
            }
        }
        return best.map { ($0.kept, $0.skipped) }
    }

    /// How many words (2 to 12) at the start of `next` repeat the end of `previous`.
    static func repeatedPrefix(_ previous: [String], _ next: [String]) -> Int {
        let longest = min(previous.count, next.count, seamMaxWords)
        guard longest >= 2 else { return 0 }
        return stride(from: longest, through: 2, by: -1).first { Array(previous.suffix($0)) == Array(next.prefix($0)) } ?? 0
    }

    static func normalize(_ word: String) -> String {
        String(word.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }
}

// MARK: - Echo by signal (echo.rs)

enum EchoSignal { case bleed, local }

/// Both tracks' 20 ms frame energies on one timeline. A microphone span is
/// bleed when delayed, quieter far-side audio explains its sound, and local
/// when it is louder than that predicts.
final class EchoEnvelope {
    static let silentDB: Float = -100
    private let system: [Float], microphone: [Float]
    private var couplings: [Int: (Float, Int)?] = [:]

    init(system: [Float], microphone: [Float]) {
        self.system = Self.frames(system)
        self.microphone = Self.frames(microphone)
    }

    static func frames(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count - Hex.frame + 1, by: Hex.frame).map { start in
            var sum = 0.0
            for sample in samples[start..<(start + Hex.frame)] { sum += Double(sample) * Double(sample) }
            return Float(10 * log10(sum / Double(Hex.frame) + 1e-10))
        }
    }

    private func at(_ frames: [Float], _ index: Int) -> Float {
        index >= 0 && index < frames.count ? frames[index] : Self.silentDB
    }

    /// The best envelope correlation and lag, in frames, of the microphone
    /// behind the far side, over a minute on each side of a 10 s block.
    private func coupling(_ first: Int, _ last: Int) -> (Float, Int)? {
        let block = (first + last) / 2 / 500
        if let known = couplings[block] { return known }
        let center = block * 500 + 250, reach = 3_000
        var best: (Float, Int)?
        for lag in -15...30 {
            var pairs: [(Float, Float)] = []
            for frame in max(center - reach, 0)..<max(max(center - reach, 0), min(center + reach, microphone.count)) {
                let far = at(system, frame - lag)
                if far > -55 { pairs.append((at(microphone, frame), far)) }
            }
            guard pairs.count >= 25 else { continue }
            let correlation = Self.pearson(pairs)
            if best == nil || correlation > best!.0 { best = (correlation, lag) }
        }
        couplings[block] = .some(best)
        return best
    }

    func assess(_ startMs: Int, _ endMs: Int) -> EchoSignal? {
        guard let (share, burst) = locality(startMs, endMs) else { return nil }
        if share >= 0.5 { return .local }
        if share <= 0.2, burst < 25 { return .bleed }
        return nil
    }

    /// The share of the span's sound frames the far side does not explain,
    /// and the most such frames in any one second.
    func locality(_ startMs: Int, _ endMs: Int) -> (share: Float, burst: Int)? {
        let first = startMs / 20, last = max(endMs / 20, first + 1)
        let contextStart = max(startMs - 5_000, 0) / 20
        let contextEnd = max(min((endMs + 5_000) / 20, microphone.count), last)
        let best = coupling(first, last)

        var floorLevels = (contextStart..<max(contextStart, contextEnd)).map { at(microphone, $0) }
        guard let floor = Self.percentile(&floorLevels, 0.1) else { return nil }
        let active = (first..<last).filter { at(microphone, $0) >= floor + 6 }
        guard let (correlation, lag) = best, correlation >= 0.2 else {
            return active.count >= 10 ? (1, min(active.count, 50)) : nil
        }

        let remote = { (frame: Int) -> Float in
            let source = frame - lag
            var level = self.at(self.system, source + 1) - 1.5
            for reverb in 0...8 { level = max(level, self.at(self.system, source - reverb) - Float(reverb) * 1.5) }
            return max(level, Self.silentDB)
        }
        let spanGain = { (span: Range<Int>, minimum: Int) -> Float? in
            var loud = span.map { self.at(self.system, $0 - lag) }.filter { $0 > -55 }
            guard loud.count >= minimum, let threshold = Self.percentile(&loud, 0.5) else { return nil }
            var differences = span.filter { self.at(self.system, $0 - lag) >= threshold }
                .map { self.at(self.microphone, $0) - remote($0) }
            return Self.percentile(&differences, 0.35)
        }
        let sides = [spanGain(contextStart..<max(contextStart, first), 10), spanGain(last..<max(last, contextEnd), 10)].compactMap { $0 }
        guard let gain = sides.max() ?? spanGain(contextStart..<max(contextStart, contextEnd), 1) else { return nil }

        let local = active.filter { at(microphone, $0) > max(gain + remote($0), floor) + 9 }
        if active.count < 10 {
            let remoteFrames = (first..<last).filter { remote($0) > -55 }.count
            return local.isEmpty && remoteFrames * 2 >= last - first ? (0, 0) : nil
        }
        var burst = 0, from = 0
        for (to, frame) in local.enumerated() {
            while local[from] <= frame - 50 { from += 1 }
            burst = max(burst, to + 1 - from)
        }
        return (Float(local.count) / Float(active.count), burst)
    }

    static func pearson(_ pairs: [(Float, Float)]) -> Float {
        let count = Float(pairs.count)
        let meanX = pairs.reduce(Float(0)) { $0 + $1.0 / count }, meanY = pairs.reduce(Float(0)) { $0 + $1.1 / count }
        var covariance: Float = 0, varianceX: Float = 0, varianceY: Float = 0
        for (x, y) in pairs {
            covariance += (x - meanX) * (y - meanY)
            varianceX += (x - meanX) * (x - meanX)
            varianceY += (y - meanY) * (y - meanY)
        }
        let denominator = (varianceX * varianceY).squareRoot()
        return denominator <= .ulpOfOne ? 0 : covariance / denominator
    }

    static func percentile(_ values: inout [Float], _ fraction: Float) -> Float? {
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[Int((Float(values.count - 1) * fraction).rounded())]
    }
}

// MARK: - Echo by words (transcript.rs, suppress_echo)

enum HexEcho {
    static let windowMs = 1_500, utteranceGapMs = 700, sentenceWords = 3
    static let similarity: Float = 0.6

    /// Drops microphone utterances that echo the far side: the signal says
    /// bleed, or it cannot tell and 60% of the words repeat far-side speech
    /// within 1.5 s. `entries` are in start order. Returns the kept entries
    /// and how many utterances were dropped.
    static func suppress(_ entries: [HexEntry], signal: (Int, Int) -> EchoSignal?) -> ([HexEntry], Int) {
        let system = entries.filter { !$0.microphone }
        let microphone = entries.indices.filter { entries[$0].microphone }.sorted { entries[$0].startMs < entries[$1].startMs }
        var utterances: [[Int]] = []
        for index in microphone {
            if let last = utterances.last?.last, entries[index].startMs - entries[last].endMs <= utteranceGapMs {
                utterances[utterances.count - 1].append(index)
            } else {
                utterances.append([index])
            }
        }
        func isEcho(_ spoken: [String], _ start: Int, _ end: Int, _ judgeWords: Bool) -> Bool {
            switch signal(start, end) {
            case .bleed?: return true
            case .local?: return false
            case nil: return judgeWords && score(spoken, start, end, remote: system) >= similarity
            }
        }
        var dropped = Set<Int>()
        var count = 0
        for utterance in utterances {
            let spoken = utterance.flatMap { tokens(entries[$0].text) }
            let end = utterance.map { entries[$0].endMs }.max() ?? 0
            if isEcho(spoken, entries[utterance[0]].startMs, end, true) {
                count += 1
                // A sentence the signal shows is local survives its echoing neighbours.
                for index in utterance where tokens(entries[index].text).count < sentenceWords
                    || signal(entries[index].startMs, entries[index].endMs) != .local {
                    dropped.insert(index)
                }
                continue
            }
            guard utterance.count > 1 else { continue }
            for index in utterance {
                let own = tokens(entries[index].text)
                if isEcho(own, entries[index].startMs, entries[index].endMs, own.count >= sentenceWords) {
                    count += 1
                    dropped.insert(index)
                }
            }
        }
        return (entries.indices.filter { !dropped.contains($0) }.map { entries[$0] }, count)
    }

    /// The share of `spoken` that far-side speech within the window contains.
    static func score(_ spoken: [String], _ startMs: Int, _ endMs: Int, remote: [HexEntry]) -> Float {
        let start = max(startMs - windowMs, 0), end = endMs + windowMs
        let heard = remote.filter { $0.startMs < end && start < $0.endMs }.flatMap { tokens($0.text) }
        guard !heard.isEmpty, !spoken.isEmpty else { return 0 }
        return Float(spoken.filter { token in heard.contains { matches(token, $0) } }.count) / Float(spoken.count)
    }

    static func tokens(_ text: String) -> [String] {
        text.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }.map { String(String.UnicodeScalarView($0)).lowercased() }
    }

    static func matches(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        let a = Array(left), b = Array(right)
        guard a.count >= 3, b.count >= 3 else { return false }
        var previous = Array(0...b.count), current = [Int](repeating: 0, count: b.count + 1)
        for (row, character) in a.enumerated() {
            current[0] = row + 1
            for (column, other) in b.enumerated() {
                current[column + 1] = min(previous[column] + (character != other ? 1 : 0), previous[column + 1] + 1, current[column] + 1)
            }
            swap(&previous, &current)
        }
        return 1 - Float(previous[b.count]) / Float(max(a.count, b.count)) >= similarity
    }
}
