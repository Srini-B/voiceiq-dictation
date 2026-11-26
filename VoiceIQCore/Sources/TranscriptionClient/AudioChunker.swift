import AVFoundation
import Foundation

/// Splits a long CAF into request-sized frame ranges for the batch transcriber.
///
/// Recordings are unbounded now, but one inline interactions request is not:
/// 20 MB of base64 FLAC is roughly ten to twelve minutes of 16 kHz speech. Each
/// cut is moved back to the quietest 100 ms inside a short window before the
/// nominal boundary, so a chunk edge lands between words rather than through one.
enum AudioChunker {
    /// Nominal chunk length. Ten minutes was the previous whole-recording cap,
    /// so this request size has a long dogfood history.
    static let maxChunkSeconds: Double = 600
    /// How far back from the nominal boundary to look for silence.
    static let searchWindowSeconds: Double = 8
    static let hopSeconds: Double = 0.1

    /// The frames to send, without leading and trailing silence, split into
    /// request-sized ranges; `fileFrames` is the whole recording's length.
    static func ranges(cafURL: URL) throws -> (ranges: [Range<AVAudioFramePosition>], fileFrames: AVAudioFramePosition) {
        let file = try AVAudioFile(forReading: cafURL, commonFormat: .pcmFormatInt16, interleaved: true)
        let rate = file.processingFormat.sampleRate
        let speech = speechRange(in: file)
        let total = speech.upperBound
        let maxFrames = AVAudioFramePosition(rate * maxChunkSeconds)
        guard speech.count > maxFrames else { return ([speech], file.length) }

        var ranges: [Range<AVAudioFramePosition>] = []
        var start = speech.lowerBound
        while start < total {
            let nominal = start + maxFrames
            guard nominal < total else {
                ranges.append(start..<total)
                break
            }
            let cut = quietestFrame(in: file, before: nominal)
            ranges.append(start..<cut)
            start = cut
        }
        return (ranges, file.length)
    }

    // Silence trimming, after Parrot's `SilenceTrimmer` (humanitas-labs/parrot,
    // MIT): 10 ms frames, a frame is voiced when its RMS clears both an absolute
    // floor and 5% (−26 dB) of the loud level, and a margin of real audio stays
    // on each side for soft onsets and trailing consonants.
    static let trimFrameSeconds = 0.01
    static let trimFloor = 0.003 * 32_768
    static let trimRelativeLevel = 0.05
    static let trimLeadSeconds = 0.25
    static let trimTrailSeconds = 0.35
    /// The loud level is the one at least this many frames (50 ms) reach, not
    /// the single loudest frame, so a key click cannot raise the bar over
    /// quiet speech. Parrot uses the loudest frame.
    static let trimLoudFrames = 5

    /// The recording without its leading and trailing silence, margins kept.
    /// The whole file when nothing clears the bar or the file can't be read,
    /// so trimming can cost a few seconds of silence sent, never a word.
    static func speechRange(in file: AVAudioFile) -> Range<AVAudioFramePosition> {
        let whole: Range<AVAudioFramePosition> = 0..<file.length
        let rate = file.processingFormat.sampleRate
        let frameLength = Int(rate * trimFrameSeconds)
        let channels = Int(file.processingFormat.channelCount)
        let blockFrames = AVAudioFrameCount(frameLength * 100)
        guard frameLength > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames)
        else { return whole }

        var levels: [Double] = []
        levels.reserveCapacity(Int(file.length) / frameLength + 1)
        file.framePosition = 0
        while file.framePosition < file.length {
            let count = min(blockFrames, AVAudioFrameCount(file.length - file.framePosition))
            do { try file.read(into: buffer, frameCount: count) } catch { return whole }
            guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { break }
            var offset = 0
            while offset + frameLength <= Int(buffer.frameLength) {
                var sum = 0.0
                for i in offset..<(offset + frameLength) {
                    let s = Double(samples[i * channels])
                    sum += s * s
                }
                levels.append((sum / Double(frameLength)).squareRoot())
                offset += frameLength
            }
        }
        return speechRange(levels: levels, frameLength: frameLength, length: file.length, rate: rate) ?? whole
    }

    /// The speech in `levels` (10 ms RMS frames of a recording `length` frames
    /// long), margins kept; nil when nothing clears the bar.
    static func speechRange(levels: [Double], frameLength: Int, length: AVAudioFramePosition,
                            rate: Double) -> Range<AVAudioFramePosition>? {
        guard let voiced = voicedFrames(levels) else { return nil }
        let start = max(0, AVAudioFramePosition(voiced.lowerBound * frameLength) - AVAudioFramePosition(rate * trimLeadSeconds))
        let end = min(length, AVAudioFramePosition((voiced.upperBound + 1) * frameLength) + AVAudioFramePosition(rate * trimTrailSeconds))
        return start < end ? start..<end : nil
    }

    /// The first and last voiced 10 ms frames.
    static func voicedFrames(_ levels: [Double]) -> ClosedRange<Int>? {
        guard levels.count > trimLoudFrames else { return nil }
        let threshold = voicedThreshold(levels)
        guard let first = levels.firstIndex(where: { $0 >= threshold }),
              let last = levels.lastIndex(where: { $0 >= threshold }) else { return nil }
        return first...last
    }

    /// The level a 10 ms frame needs to count as speech: the absolute floor,
    /// or 5% of the loud level, whichever is higher.
    static func voicedThreshold(_ levels: [Double]) -> Double {
        max(trimFloor, levels.sorted(by: >)[trimLoudFrames - 1] * trimRelativeLevel)
    }

    /// For a recording still in progress: the range `speechRange` will give
    /// at key-up if no more speech comes, once the speaker has said at least
    /// `minimumSpeech` seconds and then been silent for `pause` seconds. The
    /// pause is at least the trailing margin, so the range is already complete.
    static func pausedSpeech(levels: [Double], frameLength: Int, length: AVAudioFramePosition, rate: Double,
                             pause: Double, minimumSpeech: Double) -> Range<AVAudioFramePosition>? {
        guard let voiced = voicedFrames(levels) else { return nil }
        let silence = Double(length - AVAudioFramePosition((voiced.upperBound + 1) * frameLength)) / rate
        guard silence >= max(pause, trimTrailSeconds) else { return nil }
        let threshold = voicedThreshold(levels)
        let spoken = Double(levels[voiced].filter { $0 >= threshold }.count * frameLength) / rate
        guard spoken >= minimumSpeech else { return nil }
        return speechRange(levels: levels, frameLength: frameLength, length: length, rate: rate)
    }

    /// The start of the lowest-RMS hop inside `[boundary - window, boundary]`.
    private static func quietestFrame(in file: AVAudioFile, before boundary: AVAudioFramePosition) -> AVAudioFramePosition {
        let rate = file.processingFormat.sampleRate
        let window = AVAudioFramePosition(rate * searchWindowSeconds)
        let hop = AVAudioFrameCount(rate * hopSeconds)
        let windowStart = max(0, boundary - window)
        let frames = AVAudioFrameCount(boundary - windowStart)
        guard frames > hop,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { return boundary }
        file.framePosition = windowStart
        do { try file.read(into: buffer, frameCount: frames) } catch { return boundary }
        guard let samples = buffer.int16ChannelData?[0], buffer.frameLength > hop else { return boundary }
        let channels = Int(file.processingFormat.channelCount)

        var best = boundary
        var bestEnergy = Double.infinity
        var offset: AVAudioFrameCount = 0
        while offset + hop <= buffer.frameLength {
            var energy = 0.0
            for i in Int(offset)..<Int(offset + hop) {
                let s = Double(samples[i * channels])
                energy += s * s
            }
            if energy < bestEnergy {
                bestEnergy = energy
                best = windowStart + AVAudioFramePosition(offset)
            }
            offset += hop
        }
        return best
    }
}
