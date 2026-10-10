import Foundation
import VoiceIQSpeech

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

    @MainActor public init?(audioURL: URL, model: LocalSpeechModel, realtime: Bool,
                           makeSession: LocalSpeechSessionFactory) {
        let id = UUID()
        let streaming = model == .nemotron && realtime
        let toolsReady = LocalModelStore.englishTools.state == .ready
        let vocabulary = DictionaryStore().entries().prefix(256).map {
            LocalSpeechOptions.Term(text: $0.term, aliases: $0.misspelling.map { [$0] } ?? [])
        }
        let options = LocalSpeechOptions(
            vocabulary: vocabulary,
            toolsDirectory: toolsReady ? LocalModelManifest.englishTools.installDirectory : nil
        )
        let worker = makeSession(model, audioURL, streaming, options)
        let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancel: @Sendable () async -> Void = {
            signals.continuation.finish()
            previews.continuation.yield("")
            previews.continuation.finish()
            await worker.stop()
        }
        guard let directory = LocalModelStore.store(for: model).acquireSession(id: id, cancel: cancel) else { return nil }
        if toolsReady, LocalModelStore.englishTools.acquireSession(id: id, cancel: cancel) == nil {
            LocalModelStore.store(for: model).releaseSession(id: id)
            return nil
        }
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
                return nil as LocalSpeechOutput?
            }
            return await worker.transcribe(framesWritten: framesWritten)
        } onCancel: {
            self.pump.cancel()
            Task { await self.worker.stop() }
        }
        await worker.stop()
        await LocalModelStore.store(for: model).releaseSession(id: id)
        await LocalModelStore.englishTools.releaseSession(id: id)
        guard !Task.isCancelled, let text else { return nil }
        if let confidence = text.confidence {
            Log.transcription.notice("Parakeet token confidence (uncalibrated): \(confidence)")
        }
        UsageMeter.record(stage: .transcribe, model: model.modelID,
                          usage: TokenUsage(reportedCostUSD: 0, audioSeconds: Double(framesWritten) / 16_000))
        return TranscriptionResult(rawTranscript: text.original, cleanedTranscript: text.normalized,
                                   modelID: model.modelID, normalizedTranscript: text.normalized)
    }

    public func abort() async {
        partialSink.finish()
        wake.finish()
        pump.cancel()
        await worker.stop()
        await pump.value
        await LocalModelStore.store(for: model).releaseSession(id: id)
        await LocalModelStore.englishTools.releaseSession(id: id)
    }
}
