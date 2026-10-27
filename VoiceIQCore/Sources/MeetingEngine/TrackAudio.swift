import AVFoundation
import Foundation

/// One recorded track (mic or system) of a meeting, read for transcription.
///
/// Only the stretches with sound are sent, so a 30-minute call where the far
/// side talks for 8 minutes costs 8 minutes of audio tokens. MEASURED
/// 2026-09-27 on a 30.6-minute Meet call: the system track was louder than its
/// room tone in 27% of 100 ms windows and the mic in 10%.
public struct TrackAudio: Sendable {
    public static let sampleRate = 16_000.0
    static let window = 1_600 // 100 ms

    public let url: URL
    public let frames: Int64
    /// dBFS per 100 ms window.
    public let levels: [Double]
    /// The quietest tenth of the track: its room tone.
    public let floor: Double
    /// The level of loud speech: the 90th percentile of windows above room tone.
    public let speechLevel: Double

    public init(url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        self.url = url
        self.frames = file.length
        var levels: [Double] = []
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Self.window * 40))!
        var carry: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channel = buffer.int16ChannelData?[0] else { break }
            carry.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            var start = 0
            while carry.count - start >= Self.window {
                levels.append(Self.dBFS(carry[start..<(start + Self.window)]))
                start += Self.window
            }
            carry.removeFirst(start)
        }
        self.levels = levels
        let sorted = levels.sorted()
        let floor = sorted.isEmpty ? -120 : sorted[sorted.count / 10]
        let active = sorted.filter { $0 > floor + 10 }
        self.floor = floor
        self.speechLevel = active.isEmpty ? floor : active[active.count * 9 / 10]
    }

    public var duration: Double { Double(frames) / Self.sampleRate }


    /// Stretches with sound, padded and merged across short pauses, split so
    /// none is longer than `maxLength`. Seconds from the start of the track.
    public func activeRegions(margin: Double = 10, pad: Double = 0.4, bridge: Double = 1.0,
                              maxLength: Double = 60) -> [ClosedRange<Double>] {
        let threshold = max(floor + margin, -70)
        var regions: [ClosedRange<Double>] = []
        for (index, level) in levels.enumerated() where level > threshold {
            let start = max(0, Double(index) / 10 - pad), end = min(duration, Double(index + 1) / 10 + pad)
            if let last = regions.last, start <= last.upperBound + bridge {
                regions[regions.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                regions.append(start...end)
            }
        }
        return regions.flatMap { region -> [ClosedRange<Double>] in
            stride(from: region.lowerBound, to: region.upperBound, by: maxLength).map {
                $0...min(region.upperBound, $0 + maxLength)
            }
        }
    }

    /// Brings speech up to about -20 dBFS. MEASURED 2026-09-27: a Meet call's
    /// system track peaked near -60 dBFS for most speech, and the transcriber
    /// returned 9 words for a five-minute stretch that had a conversation in it.
    public var gain: Double {
        speechLevel > floor ? min(pow(10, (-20 - speechLevel) / 20), 40) : 1
    }

    public func samples(_ range: ClosedRange<Double>) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let start = AVAudioFramePosition(max(0, range.lowerBound) * Self.sampleRate)
        let end = min(file.length, AVAudioFramePosition(range.upperBound * Self.sampleRate))
        guard end > start else { return [] }
        file.framePosition = start
        let count = AVAudioFrameCount(end - start)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        try file.read(into: buffer, frameCount: count)
        guard let channel = buffer.int16ChannelData?[0] else { return [] }
        let gain = self.gain
        return UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)).map {
            Int16(clamping: Int((Double($0) * gain).rounded()))
        }
    }

    static func dBFS(_ samples: ArraySlice<Int16>) -> Double {
        var sum = 0.0
        for sample in samples { let value = Double(sample) / 32_768; sum += value * value }
        return 20 * log10(max((sum / Double(max(1, samples.count))).squareRoot(), 1e-6))
    }
}

/// Both tracks of a call as one timeline.
///
/// The mix is not an average: each track is brought to speech level first.
/// When the mic still carries the far side's echo, it is ducked while the far
/// side talks so the echo does not double it; that also ducks the owner
/// talking over the far side. A mic that went through `EchoCanceller` is
/// mixed at full level instead. MEASURED 2026-09-27 on the first four
/// minutes of a Meet call: the averaged mix gave 110 words under one label;
/// the levelled, ducked mix gave 155 words under two labels.
public struct CallAudio: Sendable {
    public let mic: TrackAudio
    public let system: TrackAudio
    /// The far side's speech per 100 ms window.
    let systemSpeech: [Bool]
    /// Windows where the mic is turned down: the far side's speech, held 300
    /// ms after it stops for the echo tail. Empty when the mic is echo-free.
    let duck: [Bool]
    let micSpeech: [Bool]
    /// The mic carries no echo worth ducking; speech on it is the owner's
    /// even while the far side talks.
    public let micIsEchoFree: Bool
    /// The recording started on a call `CallDetector` found (`MeetingMeta.source`).
    public let detectedCall: Bool

    /// A window belongs to the far side when the system track is near its own
    /// speech level and, relative to each track's speech level, louder than
    /// the mic. MEASURED 2026-09-27 on a Meet call: the system track's room
    /// tone was -87 dBFS and its speech -32, so "above room tone" also caught
    /// keyboard clicks and hiss, and the owner's id counted 758 far-side
    /// windows to 229 mic-only ones. With this test it counted 119 to 422.
    public init(mic: TrackAudio, system: TrackAudio, micIsEchoFree: Bool = false, detectedCall: Bool = false) {
        self.mic = mic; self.system = system; self.micIsEchoFree = micIsEchoFree; self.detectedCall = detectedCall
        let micSpeech = mic.speechLevel, systemSpeech = system.speechLevel
        let count = max(mic.levels.count, system.levels.count)
        let far = (0..<count).map { index -> Bool in
            guard index < system.levels.count else { return false }
            let level = system.levels[index]
            let micLevel = index < mic.levels.count ? mic.levels[index] : -120
            // An echo-free mic's level says nothing about the far side.
            return level > systemSpeech - 15 && (micIsEchoFree || level - systemSpeech >= micLevel - micSpeech)
        }
        var held = far
        for (index, active) in far.enumerated() where active {
            for next in max(0, index - 1)..<min(held.count, index + 4) { held[next] = true }
        }
        self.systemSpeech = far
        self.duck = micIsEchoFree ? [] : held
        let micThreshold = mic.floor + 10
        self.micSpeech = mic.levels.map { $0 > micThreshold }
    }

    /// How far the mic sits above its own room tone while only the far side
    /// talks, in dB: the echo left in it. MEASURED 2026-09-27 on a Meet call
    /// through laptop speakers: 23.5 dB before `EchoCanceller`, 0.5 dB after;
    /// on a synthetic call 15.5 and 0.7.
    public var residualEcho: Double {
        let levels = systemSpeech.indices.filter { systemSpeech[$0] && $0 < mic.levels.count }.map { mic.levels[$0] }.sorted()
        guard !levels.isEmpty else { return 0 }
        return levels[levels.count / 2] - mic.floor
    }

    public var duration: Double { max(mic.duration, system.duration) }
    /// The far side talked: this is a call, and the mic is the note owner.
    /// A recording of a detected call needs only a few seconds of the far
    /// side. MEASURED 2026-10-27: a 2.5-minute Meet call in Safari had 15.9 s,
    /// so the owner was never told apart and got a participant's name.
    public var isOnline: Bool { Double(systemSpeech.filter { $0 }.count) / 10 >= (detectedCall ? 5 : 20) }

    /// Speech on either track, padded and merged across short pauses.
    public func activeRegions(maxLength: Double = 60) -> [ClosedRange<Double>] {
        let merged = (mic.activeRegions(maxLength: .infinity) + system.activeRegions(maxLength: .infinity))
            .sorted { $0.lowerBound < $1.lowerBound }
            .reduce(into: [ClosedRange<Double>]()) { out, region in
                if let last = out.last, region.lowerBound <= last.upperBound + 1 {
                    out[out.count - 1] = last.lowerBound...max(last.upperBound, region.upperBound)
                } else { out.append(region) }
            }
        return merged.flatMap { region in
            stride(from: region.lowerBound, to: region.upperBound, by: maxLength).map { $0...min(region.upperBound, $0 + maxLength) }
        }
    }

    public func samples(_ range: ClosedRange<Double>) throws -> [Int16] {
        let near = try mic.samples(range), far = try system.samples(range)
        let first = Int(range.lowerBound * TrackAudio.sampleRate)
        return (0..<max(near.count, far.count)).map { index in
            let window = (first + index) / TrackAudio.window
            let gain = window < duck.count && duck[window] ? 0.2 : 1.0
            let value = Double(index < far.count ? far[index] : 0) + gain * Double(index < near.count ? near[index] : 0)
            return Int16(clamping: Int(value.rounded()))
        }
    }

    /// Stretches where the owner talks over the far side, padded and merged.
    /// Only meaningful with an echo-free mic: otherwise mic sound under the
    /// far side is mostly echo.
    public func overlapRegions(minimum: Double = 0.5, pad: Double = 0.5) -> [ClosedRange<Double>] {
        guard micIsEchoFree else { return [] }
        var regions: [ClosedRange<Double>] = [], start: Int?
        let count = min(systemSpeech.count, micSpeech.count)
        for index in 0...count {
            let both = index < count && systemSpeech[index] && micSpeech[index]
            if both, start == nil { start = index }
            if !both, let first = start {
                start = nil
                guard Double(index - first) / 10 >= minimum else { continue }
                let region = max(0, Double(first) / 10 - pad)...min(duration, Double(index) / 10 + pad)
                if let last = regions.last, region.lowerBound <= last.upperBound + 1 {
                    regions[regions.count - 1] = last.lowerBound...region.upperBound
                } else { regions.append(region) }
            }
        }
        return regions
    }

    /// Which track a stretch of speech came from, in 100 ms windows. With an
    /// echo-free mic, a window where both talk counts for both; otherwise mic
    /// speech under the far side may be echo and counts for the far side.
    public func sources(_ range: ClosedRange<Double>) -> (mic: Int, system: Int) {
        let first = max(0, Int(range.lowerBound * 10)), last = Int(range.upperBound * 10)
        guard first <= last else { return (0, 0) }
        var result = (mic: 0, system: 0)
        for index in first...last {
            let far = index < systemSpeech.count && systemSpeech[index]
            let near = index < micSpeech.count && micSpeech[index]
            if far { result.system += 1 }
            if near && (!far || micIsEchoFree) { result.mic += 1 }
        }
        return result
    }
}

/// Audio assembled for one request: reference clips of speakers already known,
/// then the stretches of this window, with the map back to meeting time.
public struct AssembledAudio: Sendable {
    public var samples: [Int16] = []
    /// Where each known speaker's reference clips sit in `samples`, in seconds.
    public var anchors: [String: ClosedRange<Double>] = [:]
    /// Where the window's own audio starts in `samples`.
    public var bodyStart: Double = 0
    /// (seconds into `samples`, seconds into the meeting, length).
    var pieces: [(at: Double, track: Double, length: Double)] = []

    static let gap = 0.3
    static let anchorGap = 1.0

    public var duration: Double { Double(samples.count) / TrackAudio.sampleRate }

    mutating func appendSilence(_ seconds: Double) {
        samples.append(contentsOf: repeatElement(0, count: Int(seconds * TrackAudio.sampleRate)))
    }

    mutating func appendAnchor(id: String, clips: [ClosedRange<Double>], from audio: CallAudio) throws {
        let start = duration
        for clip in clips { samples.append(contentsOf: try audio.samples(clip)); appendSilence(Self.gap) }
        anchors[id] = start...duration
        appendSilence(Self.anchorGap)
    }

    mutating func appendBody(_ regions: [ClosedRange<Double>], from audio: CallAudio) throws {
        try appendBody(regions, source: audio.samples)
    }

    mutating func appendBody(_ regions: [ClosedRange<Double>], source: (ClosedRange<Double>) throws -> [Int16]) throws {
        bodyStart = duration
        for region in regions {
            let at = duration
            let piece = try source(region)
            samples.append(contentsOf: piece)
            pieces.append((at, region.lowerBound, Double(piece.count) / TrackAudio.sampleRate))
            appendSilence(Self.gap)
        }
    }

    /// Meeting time for a span inside the body, kept inside the one stretch
    /// it overlaps most: a segment the model stamps across the silence
    /// between two stretches would otherwise swallow everything between them,
    /// and one stamped slightly early would land in the stretch before.
    public func trackSpan(_ start: Double, _ end: Double) -> ClosedRange<Double>? {
        guard start >= bodyStart - 0.2, start <= duration + 1, !pieces.isEmpty else { return nil }
        let finish = max(start, end)
        let piece = pieces.max { a, b in
            func overlap(_ p: (at: Double, track: Double, length: Double)) -> Double {
                min(finish, p.at + p.length) - max(start, p.at) - (start == finish ? abs(start - p.at) : 0)
            }
            return overlap(a) < overlap(b)
        }!
        let begin = piece.track + min(max(0, start - piece.at), piece.length)
        return begin...max(begin, piece.track + min(max(0, finish - piece.at), piece.length))
    }

    /// Meeting time for a time inside the body, or nil for anchor audio.
    public func trackTime(_ seconds: Double) -> Double? {
        guard seconds >= bodyStart - 0.2, seconds <= duration + 1,
              let piece = pieces.last(where: { $0.at <= seconds + 0.05 }) ?? pieces.first else { return nil }
        return piece.track + min(max(0, seconds - piece.at), piece.length)
    }
}
