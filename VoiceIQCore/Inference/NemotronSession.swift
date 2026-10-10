import AVFoundation
import FluidAudio
import Foundation
import VoiceIQSpeech

actor NemotronSession: LocalSpeechSession {
    private let audioURL: URL
    private let streaming: Bool
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var loading: Task<StreamingNemotronMultilingualAsrManager, Error>?
    private var processing: Task<String, Error>?
    private var acceptedFrames: Int64 = 0
    private var stopped = false
    private var failed = false

    init(audioURL: URL, streaming: Bool) {
        self.audioURL = audioURL
        self.streaming = streaming
    }

    func load(from directory: URL) async {
        guard !stopped else { return }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadModels(from: directory)
            return manager
        }
        loading = task
        do {
            let loaded = try await task.value
            loading = nil
            guard !stopped else { await loaded.cleanup(); return }
            manager = loaded
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
        let task = Task {
            try Task.checkCancellation()
            _ = try await manager.process(samples: samples)
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

    func transcribe(framesWritten: Int64) async -> String? {
        guard !stopped, !failed, let manager else { return nil }
        guard !streaming || acceptedFrames == framesWritten else { return nil }
        let audioURL = audioURL
        let streaming = streaming
        let task = Task {
            let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.length == framesWritten, file.fileFormat.sampleRate == 16_000,
                  file.fileFormat.channelCount == 1 else { throw CocoaError(.fileReadCorruptFile) }
            let chunk = await manager.config.chunkSamples
            if !streaming {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunk), file.length - file.framePosition)))
                    guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    _ = try await manager.process(samples: Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
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
                timings: primary.timings, file: file, manager: manager
            )
        }
        processing = task
        do {
            let text = try await task.value
            processing = nil
            return !stopped && !text.isEmpty ? text : nil
        } catch {
            processing = nil
            failed = true
            Log.transcription.notice("Nemotron finalization failed; using saved-audio cloud transcription: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
    }
}
