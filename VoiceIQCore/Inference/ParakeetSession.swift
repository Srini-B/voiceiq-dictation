import AVFoundation
import FluidAudio
import Foundation
import VoiceIQSpeech

actor ParakeetSession: LocalSpeechSession {
    private let audioURL: URL
    private var loading: Task<AsrModels, Error>?
    private var recognition: Task<String, Error>?
    private var manager: AsrManager?
    private var stopped = false

    init(audioURL: URL) { self.audioURL = audioURL }

    func append(_ pcm: Data) -> String? { nil }

    func load(from directory: URL) async {
        guard !stopped else { return }
        let started = Date()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try AsrModels.loadLocal(from: directory, version: .v3)
        }
        loading = task
        do {
            let models = try await task.value
            loading = nil
            guard !stopped else { return }
            manager = AsrManager(config: .default, models: models)
            Log.transcription.notice("Parakeet cold load complete in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        } catch {
            loading = nil
            Log.transcription.notice("Parakeet load failed; using cloud: \(error.localizedDescription, privacy: .public)")
        }
    }

    func transcribe(framesWritten: Int64) async -> String? {
        guard !stopped, let manager else { return nil }
        let audioURL = audioURL
        let task = Task {
            let file = try AVAudioFile(forReading: audioURL)
            guard file.length == framesWritten, file.fileFormat.sampleRate == 16_000,
                  file.fileFormat.channelCount == 1 else { throw CocoaError(.fileReadCorruptFile) }
            try Task.checkCancellation()
            var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(audioURL, decoderState: &decoder)
            try Task.checkCancellation()
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        recognition = task
        let started = Date()
        do {
            let text = try await task.value
            recognition = nil
            guard !stopped, !text.isEmpty else { return nil }
            Log.transcription.notice("Parakeet complete: \(framesWritten) frames, \(text.count) characters in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            return text
        } catch {
            recognition = nil
            Log.transcription.notice("Parakeet failed; using saved-audio cloud transcription: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Joins in-flight Core ML work before deletion can remove its model files.
    func stop() async {
        stopped = true
        let loading = loading
        let recognition = recognition
        loading?.cancel()
        recognition?.cancel()
        _ = await loading?.result
        _ = await recognition?.result
        self.loading = nil
        self.recognition = nil
        await manager?.cleanup()
        manager = nil
        Log.transcription.notice("Parakeet model references released; no warm model retained")
    }
}
