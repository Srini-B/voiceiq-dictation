import AVFoundation
import Foundation

/// Finds the speech in a recording, so the silence before and after it is
/// not uploaded.
enum SpeechRange {
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
        return withMargins(voiced, frameLength: frameLength, length: length, rate: rate)
    }

    private static func withMargins(_ voiced: ClosedRange<Int>, frameLength: Int, length: AVAudioFramePosition,
                                    rate: Double) -> Range<AVAudioFramePosition>? {
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
}
