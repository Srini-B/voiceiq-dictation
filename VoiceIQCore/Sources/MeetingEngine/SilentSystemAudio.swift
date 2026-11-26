import AVFoundation
import Foundation

/// A call the Mac recorded without hearing the other side. When macOS does
/// not allow VoiceiQ to record system audio, the Core Audio tap still runs
/// and `system.caf` is written, but every sample is zero. Real call audio,
/// even a quiet line, is never exact digital silence for a minute.
public enum SilentSystemAudio {
    /// Shorter calls can be quiet for real (everyone on mute while joining).
    static let minimumSeconds = 60.0

    /// True for a recorded call (call detection named its app) of over a
    /// minute whose `system.caf` is all zeros. A recording started by hand
    /// is not checked: with nothing playing, an all-system tap is silent too.
    /// Reads the whole track only when it is silent; call audio stops at
    /// the first sound.
    public static func check(_ meta: MeetingMeta, folder: URL) -> Bool {
        guard meta.source != nil, meta.importedFrom == nil, meta.status != .recording,
              meta.durationSeconds > minimumSeconds else { return false }
        let url = folder.appendingPathComponent("system.caf")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? isAllZero(url)) ?? false
    }

    static func isAllZero(_ url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 160_000) else { return false }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channel = buffer.int16ChannelData?[0] else { break }
            let count = Int(buffer.frameLength) * Int(file.processingFormat.channelCount)
            if UnsafeBufferPointer(start: channel, count: count).contains(where: { $0 != 0 }) { return false }
        }
        return true
    }
}
