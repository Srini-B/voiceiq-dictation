import Foundation
import os
import VoiceIQSpeech

/// The CAF remains authoritative. Missing stream bytes disqualify local output,
/// rather than passing a fluent but incomplete transcript to cleanup.
public final class LocalTranscriber: DictationStreaming, Sendable {
    public let partials: AsyncStream<String>
    private let partialSink: AsyncStream<String>.Continuation
    private let id: UUID
    private let model: LocalSpeechModel
    private let worker: any LocalSpeechSession
    /// Live PCM is pumped into the session for display-only previews.
    private let previewing: Bool
    /// Nemotron's streamed transcript is the final transcript, so every
    /// recorded byte must have been accepted. Fluid Speech Mini previews are
    /// disposable; its final transcript is a separate decode of the recording.
    private let strict: Bool
    private let ring = PCMRing(seconds: 30)
    private let wake: AsyncStream<Void>.Continuation
    private let pump: Task<Void, Never>

    /// Fluid Speech Mini previews cost one decode per second of speech, so
    /// they run only where the app shows live text: the Mac pill. iPhone and
    /// iPad have no such surface.
    static func previews(_ model: LocalSpeechModel, realtime: Bool) -> Bool {
        guard realtime else { return false }
        switch model {
        case .nemotron: return true
        case .parakeet:
            #if os(macOS)
            return true
            #else
            return false
            #endif
        }
    }

    @MainActor public init?(audioURL: URL, model: LocalSpeechModel, realtime: Bool,
                           makeSession: LocalSpeechSessionFactory) {
        let id = UUID()
        let previewing = Self.previews(model, realtime: realtime)
        let strict = model == .nemotron && previewing
        // Nemotron wants its native chunk; Fluid Speech Mini re-decodes, so
        // one second keeps the preview moving without stacking decodes.
        let chunkBytes = model == .nemotron ? 71_680 : PCMRing.bytesPerSecond
        let toolsReady = LocalModelStore.englishTools.state == .ready
        let vocabulary = DictionaryStore().entries().prefix(256).map {
            LocalSpeechOptions.Term(text: $0.term, aliases: $0.misspelling.map { [$0] } ?? [])
        }
        let options = LocalSpeechOptions(
            vocabulary: vocabulary,
            toolsDirectory: toolsReady ? LocalModelManifest.englishTools.installDirectory : nil
        )
        let worker = makeSession(model, audioURL, previewing, options)
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
        self.previewing = previewing
        self.strict = strict
        wake = signals.continuation
        let ring = ring
        pump = Task {
            defer {
                previews.continuation.yield("")
                previews.continuation.finish()
            }
            await worker.load(from: directory)
            guard previewing else { return }
            // A rejected chunk or a dropped one ends a strict session, because
            // its stream can no longer become the transcript. A preview-only
            // session just stops previewing; its final decode is unaffected.
            for await _ in signals.stream {
                guard !Task.isCancelled else { return }
                if ring.didDrop && strict { await worker.stop(); return }
                for pcm in ring.drainCoalesced(minBytes: chunkBytes, flushAll: false) {
                    guard let preview = await worker.append(pcm) else {
                        if strict { await worker.stop() }
                        return
                    }
                    ring.markAccepted(pcm.count)
                    previews.continuation.yield(String(preview.suffix(512)))
                }
            }
            guard strict, !Task.isCancelled else { return }
            guard !ring.didDrop else { await worker.stop(); return }
            for pcm in ring.drainCoalesced(minBytes: chunkBytes, flushAll: true) {
                guard await worker.append(pcm) != nil else { await worker.stop(); return }
                ring.markAccepted(pcm.count)
            }
        }
    }

    public func enqueue(_ pcm: Data) {
        guard previewing else { return }
        ring.append(pcm)
        wake.yield(())
    }

    public func finish(framesWritten: Int64) async -> TranscriptionResult? {
        partialSink.finish()
        wake.finish()
        let deadline = TimeoutPolicy.localLoad + TimeoutPolicy.localTranscribe(frames: framesWritten)
        let outcome = await withTaskCancellationHandler {
            await Self.bounded(seconds: deadline) { [self] in
                await pump.value
                guard !strict || (!ring.didDrop && ring.acceptedBytes == framesWritten * 2) else {
                    return nil as LocalSpeechOutput?
                }
                return await worker.transcribe(framesWritten: framesWritten)
            }
        } onCancel: {
            self.pump.cancel()
            Task { await self.worker.stop() }
        }
        if case .finished = outcome {
            await worker.stop()
        } else {
            Log.transcription.notice("On-device transcription passed \(deadline, format: .fixed(precision: 0))s; using saved audio with cloud transcription")
            Task { await worker.stop() }
        }
        await LocalModelStore.store(for: model).releaseSession(id: id)
        await LocalModelStore.englishTools.releaseSession(id: id)
        guard !Task.isCancelled, case .finished(let text?) = outcome else { return nil }
        if let confidence = text.confidence {
            Log.transcription.notice("Parakeet token confidence (uncalibrated): \(confidence)")
        }
        UsageMeter.record(stage: .transcribe, model: model.modelID,
                          usage: TokenUsage(reportedCostUSD: 0, audioSeconds: Double(framesWritten) / 16_000))
        return TranscriptionResult(rawTranscript: text.original, cleanedTranscript: text.normalized,
                                   modelID: model.modelID, normalizedTranscript: text.normalized)
    }

    private enum Bounded<T: Sendable>: Sendable {
        case finished(T)
        case timedOut
    }

    /// Core ML work cannot be cancelled, so a stalled in-process session is
    /// abandoned instead of joined: past the deadline the caller moves on and
    /// the work keeps its task. The Mac helper bounds its own steps with the
    /// same numbers and is killed first, so this fires only in-process (iOS).
    private static func bounded<T: Sendable>(
        seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T
    ) async -> Bounded<T> {
        let settled = OSAllocatedUnfairLock(initialState: false)
        let claim: @Sendable () -> Bool = { settled.withLock { let first = !$0; $0 = true; return first } }
        return await withCheckedContinuation { continuation in
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                if claim() { continuation.resume(returning: .timedOut) }
            }
            Task {
                let value = await operation()
                timer.cancel()
                if claim() { continuation.resume(returning: .finished(value)) }
            }
        }
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
