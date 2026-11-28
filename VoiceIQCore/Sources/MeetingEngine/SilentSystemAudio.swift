import AVFoundation
import Foundation

/// A call the Mac recorded without hearing the other side. When macOS does
/// not allow VoiceiQ to record system audio, the Core Audio tap still runs
/// and `system.caf` is written, but every sample is zero; a tap that missed
/// the call's sound writes noise near −84 dBFS. Real call audio is never
/// that quiet for a minute (`SystemTapWatch.quietPeak`).
public enum SilentSystemAudio {
    /// Shorter calls can be quiet for real (everyone on mute while joining).
    static let minimumSeconds = 60.0

    /// Why the other side went unheard: `zeros` when macOS gave the tap no
    /// sound at all (system audio recording not allowed), `quiet` when the
    /// track carries only noise (a missed or muted call).
    public enum Unheard: Sendable { case zeros, quiet }

    /// Set for a recorded call (call detection named its app) of over a
    /// minute whose `system.caf` is quiet throughout. A recording started by hand
    /// is not checked: with nothing playing, an all-system tap is silent too.
    /// Reads the whole track only when it is silent; call audio stops at
    /// the first sound.
    public static func check(_ meta: MeetingMeta, folder: URL) -> Unheard? {
        guard meta.source != nil, meta.importedFrom == nil, meta.status != .recording,
              meta.durationSeconds > minimumSeconds else { return nil }
        let url = folder.appendingPathComponent("system.caf")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try? unheard(url)) ?? nil
    }

    static func unheard(_ url: URL) throws -> Unheard? {
        var zeros = true
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 160_000) else { return false }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channel = buffer.int16ChannelData?[0] else { break }
            let count = Int(buffer.frameLength) * Int(file.processingFormat.channelCount)
            let samples = UnsafeBufferPointer(start: channel, count: count)
            if !SystemTapWatch.isQuiet(samples) { return nil }
            if zeros, samples.contains(where: { $0 != 0 }) { zeros = false }
        }
        return zeros ? .zeros : .quiet
    }
}
