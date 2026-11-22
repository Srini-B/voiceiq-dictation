#if os(macOS)
import AVFoundation
import os

/// When a meeting track last carried sound louder than a quiet room, to tell
/// a call that ended from one where nobody is talking right now.
public final class SoundClock: @unchecked Sendable {
    /// About −40 dBFS RMS: below speech at a laptop mic, above a quiet room.
    static let threshold: Float = 0.01
    private let last = OSAllocatedUnfairLock(initialState: Date())

    public var lastSound: Date { last.withLock { $0 } }

    /// From the tap's I/O queue, with 16-bit mono audio.
    func hear(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = Float(samples[index]) / Float(Int16.max)
            sum += sample * sample
        }
        if (sum / Float(buffer.frameLength)).squareRoot() >= Self.threshold {
            last.withLock { $0 = Date() }
        }
    }
}
#endif
