import AVFoundation
import FluidAudio
import Foundation

protocol LocalSpeechSession: Actor {
    func load(from directory: URL) async
    /// Nil rejects the audio; otherwise the string is the display-only preview.
    func append(_ pcm: Data) async -> String?
    func transcribe(framesWritten: Int64) async -> String?
    func stop() async
}

func makeLocalSpeechSession(model: LocalSpeechModel, audioURL: URL, streaming: Bool) -> any LocalSpeechSession {
    switch model {
    case .parakeet: return ParakeetSession(audioURL: audioURL)
    case .nemotron: return NemotronSession(audioURL: audioURL, streaming: streaming)
    }
}

/// The CAF remains authoritative. Missing stream bytes disqualify local output,
/// rather than passing a fluent but incomplete transcript to cleanup.
public final class LocalTranscriber: DictationStreaming, Sendable {
    public let partials: AsyncStream<String>
    private let partialSink: AsyncStream<String>.Continuation
    private let id: UUID
    private let model: LocalSpeechModel
    private let worker: any LocalSpeechSession
    private let streaming: Bool
    private let ring = PCMRing(seconds: 30)
    private let wake: AsyncStream<Void>.Continuation
    private let pump: Task<Void, Never>

    @MainActor public init?(audioURL: URL, model: LocalSpeechModel, realtime: Bool) {
        let id = UUID()
        let streaming = model == .nemotron && realtime
        #if os(macOS)
        let worker: any LocalSpeechSession = LocalRemoteSession(audioURL: audioURL, model: model, streaming: streaming)
        #else
        let worker = makeLocalSpeechSession(model: model, audioURL: audioURL, streaming: streaming)
        #endif
        let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard let directory = LocalModelStore.store(for: model).acquireSession(id: id, cancel: {
            signals.continuation.finish()
            previews.continuation.yield("")
            previews.continuation.finish()
            await worker.stop()
        }) else { return nil }
        partials = previews.stream
        partialSink = previews.continuation
        self.id = id
        self.model = model
        self.worker = worker
        self.streaming = streaming
        wake = signals.continuation
        let ring = ring
        pump = Task {
            defer {
                previews.continuation.yield("")
                previews.continuation.finish()
            }
            await worker.load(from: directory)
            guard streaming else { return }
            for await _ in signals.stream {
                guard !Task.isCancelled, !ring.didDrop else { await worker.stop(); return }
                for pcm in ring.drainCoalesced(minBytes: 71_680, flushAll: false) {
                    guard let preview = await worker.append(pcm) else { await worker.stop(); return }
                    ring.markAccepted(pcm.count)
                    previews.continuation.yield(String(preview.suffix(512)))
                }
            }
            guard !Task.isCancelled, !ring.didDrop else { await worker.stop(); return }
            for pcm in ring.drainCoalesced(minBytes: 71_680, flushAll: true) {
                guard await worker.append(pcm) != nil else { await worker.stop(); return }
                ring.markAccepted(pcm.count)
            }
        }
    }

    public func enqueue(_ pcm: Data) {
        guard streaming else { return }
        ring.append(pcm)
        wake.yield(())
    }

    public func finish(framesWritten: Int64) async -> TranscriptionResult? {
        partialSink.finish()
        wake.finish()
        let text = await withTaskCancellationHandler {
            await pump.value
            guard !Task.isCancelled, !streaming || (!ring.didDrop && ring.acceptedBytes == framesWritten * 2) else {
                return nil as String?
            }
            return await worker.transcribe(framesWritten: framesWritten)
        } onCancel: {
            self.pump.cancel()
            Task { await self.worker.stop() }
        }
        await worker.stop()
        await LocalModelStore.store(for: model).releaseSession(id: id)
        guard !Task.isCancelled, let text else { return nil }
        UsageMeter.record(stage: .transcribe, model: model.modelID,
                          usage: TokenUsage(reportedCostUSD: 0, audioSeconds: Double(framesWritten) / 16_000))
        return TranscriptionResult(rawTranscript: text, cleanedTranscript: text, modelID: model.modelID)
    }

    public func abort() async {
        partialSink.finish()
        wake.finish()
        pump.cancel()
        await worker.stop()
        await pump.value
        await LocalModelStore.store(for: model).releaseSession(id: id)
    }
}

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
                  file.fileFormat.channelCount == 1 else { throw TranscriptionError.emptyTranscript }
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
