import AVFoundation
import Foundation

/// Speech that ended in a pause while the recording goes on: the frames
/// `AudioChunker.speechRange` will send at key-up if no more speech comes, and
/// their samples.
public struct PausedSpeech: Sendable {
    public let range: Range<AVAudioFramePosition>
    public let samples: [Int16]
}

/// The recording so far, kept in memory as it is written so a pause can be
/// checked without reading the file: its 16 kHz samples and their 10 ms RMS
/// levels, framed as `AudioChunker` frames the file. Kept for the first
/// `maxSeconds` only; a longer recording is never sent early.
struct RecordedSpeech {
    static let sampleRate = 16_000.0
    static let maxSeconds = 120.0
    private static let frameLength = Int(sampleRate * AudioChunker.trimFrameSeconds)

    private var samples: [Int16] = []
    private var levels: [Double] = []
    private(set) var isTooLong = false

    mutating func append(_ buffer: UnsafeBufferPointer<Int16>) {
        guard !isTooLong else { return }
        guard Double(samples.count + buffer.count) <= Self.sampleRate * Self.maxSeconds else {
            isTooLong = true
            samples = []
            levels = []
            return
        }
        samples.append(contentsOf: buffer)
        while (levels.count + 1) * Self.frameLength <= samples.count {
            let start = levels.count * Self.frameLength
            var sum = 0.0
            for sample in samples[start..<(start + Self.frameLength)] {
                sum += Double(sample) * Double(sample)
            }
            levels.append((sum / Double(Self.frameLength)).squareRoot())
        }
    }

    /// The speech, once the speaker has said `minimumSpeech` seconds and
    /// then been silent for `pause` seconds.
    func pausedSpeech(after pause: Double, minimumSpeech: Double) -> PausedSpeech? {
        guard !isTooLong,
              let range = AudioChunker.pausedSpeech(levels: levels, frameLength: Self.frameLength,
                                                     length: AVAudioFramePosition(samples.count),
                                                     rate: Self.sampleRate, pause: pause, minimumSpeech: minimumSpeech)
        else { return nil }
        return PausedSpeech(range: range, samples: Array(samples[Int(range.lowerBound)..<Int(range.upperBound)]))
    }

    /// Seconds from the last voiced frame to the end of the recording.
    var trailingSilence: Double? {
        guard !isTooLong, let voiced = AudioChunker.voicedFrames(levels) else { return nil }
        return Double(samples.count - (voiced.upperBound + 1) * Self.frameLength) / Self.sampleRate
    }
}
