import FluidAudio
import Foundation
import VoiceIQSpeech

/// Nemotron decodes the recorded audio as is. Dictionary terms are not passed
/// to its decoder: FluidAudio's greedy hotword bias looped on short terms
/// ("Cal" turned a hesitation into "Ca Ca Ca…") and raised word error rate on
/// replayed dictations. The dictionary still reaches cleanup and replacement.
actor NemotronSession: LocalSpeechSession {
    private typealias Loaded = (manager: StreamingNemotronMultilingualAsrManager, tools: EnglishTools)
    private let audioURL: URL
    private let streaming: Bool
    private let options: LocalSpeechOptions
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var tools = EnglishTools()
    private var meter: SpeechActivityMeter?
    private var loading: Task<Loaded, Error>?
    private var processing: Task<String, Error>?
    private var acceptedFrames: Int64 = 0
    /// Start of the decoder's input, kept for onset recovery.
    private var opening: [Float] = []
    private var stopped = false
    private var failed = false

    init(audioURL: URL, streaming: Bool, options: LocalSpeechOptions) {
        self.audioURL = audioURL
        self.streaming = streaming
        self.options = options
    }

    func load(from directory: URL) async {
        guard !stopped else { return }
        let toolsRoot = options.toolsDirectory
        let task = Task.detached(priority: .userInitiated) { () throws -> Loaded in
            try Task.checkCancellation()
            async let tools = EnglishTools.load(root: toolsRoot)
            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadModels(from: directory)
            try Task.checkCancellation()
            await manager.setLanguage("en-US")
            await manager.setForcedPrefix(true)
            let loadedTools = try await tools
            try Task.checkCancellation()
            return (manager, loadedTools)
        }
        loading = task
        do {
            let loaded = try await task.value
            loading = nil
            guard !stopped else { await loaded.manager.cleanup(); return }
            manager = loaded.manager
            tools = loaded.tools
            if streaming {
                meter = tools.vad.map(SpeechActivityMeter.init)
            }
            Log.transcription.notice("Nemotron English: vad=\(self.tools.vad != nil)")
        } catch {
            loading = nil
            failed = true
            Log.transcription.notice("Nemotron load failed; using cloud: \(error.localizedDescription, privacy: .public)")
        }
    }

    func append(_ pcm: Data) async -> String? {
        guard streaming, !stopped, !failed, let manager, pcm.count.isMultiple(of: 2) else { return nil }
        // Capture supplies little-endian Int16. Avoid aligned loads from Data.
        let samples: [Float] = pcm.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 2).map { offset in
                Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32_768
            }
        }
        let meter = meter
        let task = Task {
            try Task.checkCancellation()
            try await self.decode(samples, manager: manager, meter: meter)
            return await manager.getPartialTranscript()
        }
        processing = task
        do {
            let preview = try await task.value
            processing = nil
            guard !stopped else { return nil }
            acceptedFrames += Int64(samples.count)
            return String(preview.suffix(512))
        } catch {
            processing = nil
            failed = true
            Log.transcription.notice("Nemotron streaming failed; rejecting partial transcript")
            return nil
        }
    }

    func transcribe(framesWritten: Int64) async -> LocalSpeechOutput? {
        guard !stopped, !failed, let manager else { return nil }
        guard !streaming || acceptedFrames == framesWritten else { return nil }
        let audioURL = audioURL
        let streaming = streaming
        let tools = tools
        let meter = meter
        let task = Task {
            let chunk = await manager.config.chunkSamples
            if streaming {
                try SpeechAudio.validate(audioURL, frames: framesWritten)
                if let speech = await meter?.finish() {
                    Log.transcription.notice("Nemotron VAD speech start \(Double(speech.start) / 16_000, format: .fixed(precision: 2))s, end \(speech.end.map { Double($0) / 16_000 } ?? -1, format: .fixed(precision: 2))s of \(Double(framesWritten) / 16_000, format: .fixed(precision: 2))s")
                }
            } else if !SpeechAudio.fitsInMemory(framesWritten) {
                // VAD trimming needs the whole recording and is skipped.
                Log.transcription.notice("Nemotron long recording (\(framesWritten) frames): chunked decode, no VAD trim")
                try await SpeechAudio.forEachChunk(audioURL, frames: framesWritten, size: chunk) { samples in
                    try await self.decode(samples, manager: manager, meter: nil)
                }
            } else {
                let recorded = try SpeechAudio.read(audioURL, frames: framesWritten)
                let samples = try await SpeechBoundaries.trimmed(recorded, vad: tools.vad)
                for start in stride(from: 0, to: samples.count, by: chunk) {
                    try Task.checkCancellation()
                    try await self.decode(Array(samples[start..<min(start + chunk, samples.count)]), manager: manager, meter: nil)
                }
            }
            try Task.checkCancellation()
            // finish() only pads an incomplete chunk. Even an exact-boundary
            // stop needs decoder lookahead to emit the last spoken words.
            // This silence is not recorded audio and must not affect byte accounting.
            _ = try await manager.process(samples: [Float](repeating: 0, count: chunk))
            let primary = try await manager.finishWithTokenTimings()
            return try await NemotronOnsetRecovery.recover(
                text: primary.text.trimmingCharacters(in: .whitespacesAndNewlines),
                timings: primary.timings, opening: self.opening, manager: manager
            )
        }
        processing = task
        do {
            let text = try await task.value
            processing = nil
            guard !stopped else { return nil }
            return EnglishText.output(original: text)
        } catch {
            processing = nil
            failed = true
            Log.transcription.notice("Nemotron finalization failed; using saved-audio cloud transcription: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Feeds the decoder and records the opening audio it actually received.
    private func decode(
        _ samples: [Float], manager: StreamingNemotronMultilingualAsrManager, meter: SpeechActivityMeter?
    ) async throws {
        guard !samples.isEmpty else { return }
        _ = try await manager.process(samples: samples)
        let limit = await manager.config.chunkSamples * 3
        if opening.count < limit { opening += samples.prefix(limit - opening.count) }
        await meter?.feed(samples)
    }

    func stop() async {
        stopped = true
        let loading = loading
        let processing = processing
        loading?.cancel()
        processing?.cancel()
        _ = await loading?.result
        _ = await processing?.result
        self.loading = nil
        self.processing = nil
        await manager?.cleanup()
        manager = nil
        tools = EnglishTools()
        meter = nil
        opening = []
    }
}
