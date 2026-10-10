import FluidAudio
import Foundation

/// Conservative voice-activity boundaries. VAD never splits a recording or
/// drops audio inside it; it only removes long silent edges, keeping a wide
/// margin, and the trimmed samples are what every later stage (decoder, CTC
/// timings, onset recovery) sees.
enum SpeechBoundaries {
    /// Below Silero's usual 0.5 so quiet speech counts as speech.
    static let threshold: Float = 0.4
    private static let sampleRate = 16_000
    private static let trimAfter = 2 * sampleRate
    private static let margin = sampleRate
    static let segmentation = VadSegmentationConfig(minSilenceDuration: 1.0, speechPadding: 0.15)

    static func trimmed(_ samples: [Float], vad: VadManager?) async throws -> [Float] {
        guard let vad, !samples.isEmpty else { return samples }
        let segments: [VadSegment]
        do {
            segments = try await vad.segmentSpeech(samples, config: segmentation)
        } catch {
            try Task.checkCancellation()
            Log.transcription.notice("VAD failed; keeping full recording: \(error.localizedDescription, privacy: .public)")
            return samples
        }
        guard let first = segments.first, let last = segments.last else {
            // No detected speech may still be whispered speech; never discard it.
            Log.transcription.notice("VAD found no speech in \(samples.count) samples; keeping full recording")
            return samples
        }
        let speechStart = max(0, first.startSample(sampleRate: sampleRate))
        let speechEnd = min(samples.count, last.endSample(sampleRate: sampleRate))
        let start = speechStart > trimAfter ? speechStart - margin : 0
        let end = samples.count - speechEnd > trimAfter ? speechEnd + margin : samples.count
        Log.transcription.notice("VAD speech \(Double(speechStart) / 16_000, format: .fixed(precision: 2))s-\(Double(speechEnd) / 16_000, format: .fixed(precision: 2))s of \(Double(samples.count) / 16_000, format: .fixed(precision: 2))s in \(segments.count) segments; decoding \(start)..<\(end)")
        guard start < end, end - start >= 2 * sampleRate, start > 0 || end < samples.count else { return samples }
        return Array(samples[start..<end])
    }
}

/// Streaming diagnostics only: measures where speech starts and ends without
/// influencing the decoder. Any VAD error disables the meter for the session.
actor SpeechActivityMeter {
    private var vad: VadManager?
    private var state = VadStreamState.initial()
    private var pending: [Float] = []
    private var firstStart: Int?
    private var lastEnd: Int?

    init(_ vad: VadManager) { self.vad = vad }

    func feed(_ samples: [Float]) async {
        guard vad != nil else { return }
        pending += samples
        while pending.count >= VadManager.chunkSize {
            let chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            await step(chunk)
        }
    }

    /// Returns `(start, end)` sample indices of detected speech, if any.
    func finish() async -> (start: Int, end: Int?)? {
        if !pending.isEmpty { await step(pending) }
        pending = []
        vad = nil
        return firstStart.map { ($0, lastEnd) }
    }

    private func step(_ chunk: [Float]) async {
        guard let vad else { return }
        do {
            let result = try await vad.processStreamingChunk(chunk, state: state, config: SpeechBoundaries.segmentation)
            state = result.state
            if let event = result.event {
                if event.isStart, firstStart == nil { firstStart = event.sampleIndex }
                if event.isEnd { lastEnd = event.sampleIndex }
            }
        } catch {
            self.vad = nil
            Log.transcription.notice("Streaming VAD diagnostics disabled: \(error.localizedDescription, privacy: .public)")
        }
    }
}
