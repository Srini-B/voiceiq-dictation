import FluidAudio
import Foundation
import VoiceIQSpeech

actor ParakeetSession: LocalSpeechSession {
    private typealias Loaded = (models: AsrModels, tools: EnglishTools)
    private let audioURL: URL
    private let options: LocalSpeechOptions
    private var loading: Task<Loaded, Error>?
    private var recognition: Task<LocalSpeechOutput?, Error>?
    private var manager: AsrManager?
    private var tools = EnglishTools()
    private var stopped = false

    init(audioURL: URL, options: LocalSpeechOptions) {
        self.audioURL = audioURL
        self.options = options
    }

    func append(_ pcm: Data) -> String? { nil }

    func load(from directory: URL) async {
        guard !stopped else { return }
        let started = Date()
        let terms = EnglishVocabulary.terms(options.vocabulary)
        let toolsRoot = options.toolsDirectory
        let task = Task.detached(priority: .userInitiated) { () throws -> Loaded in
            try Task.checkCancellation()
            async let tools = EnglishTools.load(root: toolsRoot, vocabulary: terms)
            let models = try AsrModels.loadLocal(from: directory, version: .v3)
            return (models, try await tools)
        }
        loading = task
        do {
            let loaded = try await task.value
            loading = nil
            guard !stopped else { return }
            manager = AsrManager(config: .default, models: loaded.models)
            tools = loaded.tools
            if !terms.isEmpty, tools.vocabulary == nil {
                Log.transcription.notice("Parakeet vocabulary spotting unavailable; \(terms.count) terms not applied")
            }
            Log.transcription.notice("Parakeet cold load complete in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s, enhancement=\(self.tools.enhancer != nil), vad=\(self.tools.vad != nil), vocabulary=\(self.tools.vocabulary != nil)")
        } catch {
            loading = nil
            Log.transcription.notice("Parakeet load failed; using cloud: \(error.localizedDescription, privacy: .public)")
        }
    }

    func transcribe(framesWritten: Int64) async -> LocalSpeechOutput? {
        guard !stopped, let manager else { return nil }
        let audioURL = audioURL
        let tools = tools
        let task = Task { () throws -> LocalSpeechOutput? in
            guard SpeechAudio.fitsInMemory(framesWritten) else {
                // FluidAudio's disk-backed path keeps memory constant. Enhancement,
                // VAD trimming and vocabulary rescoring need the whole recording
                // in memory, so a long recording is decoded from the raw file.
                try SpeechAudio.validate(audioURL, frames: framesWritten)
                Log.transcription.notice("Parakeet long recording (\(framesWritten) frames): disk-backed decode without enhancement, VAD or vocabulary")
                var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let result = try await manager.transcribeDiskBacked(audioURL, decoderState: &decoder, language: .english)
                try Task.checkCancellation()
                return EnglishText.output(original: result.text, confidence: result.confidence)
            }
            let recorded = try SpeechAudio.read(audioURL, frames: framesWritten)
            let enhanced = try await SpeechAudio.enhanced(recorded, with: tools.enhancer)
            // The decoder and CTC spotter see the same samples, so token
            // timings and CTC frames share one clock.
            let samples = try await SpeechBoundaries.trimmed(enhanced, vad: tools.vad)
            try Task.checkCancellation()
            var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(samples, decoderState: &decoder, language: .english)
            try Task.checkCancellation()
            var corrected: String?
            if let vocabulary = tools.vocabulary {
                do {
                    corrected = try await vocabulary.rescore(text: result.text, timings: result.tokenTimings ?? [], samples: samples)
                } catch {
                    try Task.checkCancellation()
                    Log.transcription.notice("Parakeet vocabulary rescoring failed; keeping base transcript: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Uncalibrated decoder confidence, for diagnostics only.
            return EnglishText.output(original: result.text, corrected: corrected, confidence: result.confidence)
        }
        recognition = task
        let started = Date()
        do {
            let output = try await task.value
            recognition = nil
            guard !stopped, let output else { return nil }
            Log.transcription.notice("Parakeet complete: \(framesWritten) frames, \(output.original.count) characters, confidence \(output.confidence ?? -1, format: .fixed(precision: 3)) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            return output
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
        tools = EnglishTools()
        Log.transcription.notice("Parakeet model references released; no warm model retained")
    }
}
