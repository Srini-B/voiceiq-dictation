import Foundation
import os
import VoiceIQSpeech

/// The CAF remains authoritative: the final transcript always decodes the
/// saved recording, never the live preview.
public final class LocalTranscriber: DictationStreaming, Sendable {
    public var runsOnDevice: Bool { true }
    public let partials: AsyncStream<String>
    private let partialSink: AsyncStream<String>.Continuation
    private let id: UUID
    private let model: LocalSpeechModel
    private let worker: any LocalSpeechSession
    /// Live PCM is pumped into the session for display-only previews. They
    /// are disposable; the final transcript is a separate decode of the recording.
    private let previewing: Bool
    private let ring = PCMRing(seconds: 30)
    private let wake: AsyncStream<Void>.Continuation
    /// Waits for any warm-up, then loads the model. Starts with the recording.
    private let load: Task<Void, Never>
    private let pump: Task<Void, Never>
    /// A load still running `TimeoutPolicy.localColdLoad` after the recording
    /// sends the dictation to the cloud provider and goes on as a warm-up.
    /// The caller passes whether a provider can take it.
    private let cloudOnColdLoad: Bool
    /// Set when the load was handed to `LocalModelWarmup`; the coordinator's
    /// later `abort` must then leave it running.
    private let handedOff = OSAllocatedUnfairLock(initialState: false)

    /// Previews cost one decode per second of speech, so they run only where
    /// the app shows live text: the Mac pill. iPhone and iPad have no such surface.
    static func previews(realtime: Bool) -> Bool {
        #if os(macOS)
        return realtime
        #else
        return false
        #endif
    }

    public enum LoadEvent: Sendable {
        /// The model loaded, in `seconds` from the start of the recording.
        case loaded(LocalSpeechModel, seconds: TimeInterval)
        /// The load failed after `seconds`; the dictation goes to the cloud.
        case failed(LocalSpeechModel, seconds: TimeInterval)
        /// The model was still loading `waited` seconds after the recording
        /// ended; the dictation went to the cloud and the load goes on.
        case stillLoading(LocalSpeechModel, waited: TimeInterval)
    }

    /// Called for each dictation's model load, so the app can put it in its
    /// session log next to the dictation.
    @MainActor public static var onLoadEvent: ((LoadEvent) -> Void)?

    /// What a dictation in `language` loads: the dictionary terms and, for
    /// English, the installed English tools. The warm-up uses the same
    /// options so it prepares every model a dictation will load.
    @MainActor static func sessionOptions(language: LocalSpeechLanguage) -> (options: LocalSpeechOptions, toolsReady: Bool) {
        // The English tools would trim and reformat other languages as English.
        let toolsReady = language.isEnglish && LocalModelStore.englishTools.state == .ready
        let vocabulary = DictionaryStore().entries().prefix(256).map {
            LocalSpeechOptions.Term(text: $0.term, aliases: $0.misspelling.map { [$0] } ?? [])
        }
        let options = LocalSpeechOptions(
            vocabulary: vocabulary,
            toolsDirectory: toolsReady ? LocalModelManifest.englishTools.installDirectory : nil,
            language: language.code
        )
        return (options, toolsReady)
    }

    /// `cloudOnColdLoad`: the provider can transcribe, so a dictation whose
    /// model is still loading after the recording can go to the cloud.
    @MainActor public init?(audioURL: URL, model: LocalSpeechModel, language: LocalSpeechLanguage, realtime: Bool,
                           cloudOnColdLoad: Bool, makeSession: LocalSpeechSessionFactory) {
        let id = UUID()
        let previewing = Self.previews(realtime: realtime)
        let (options, toolsReady) = Self.sessionOptions(language: language)
        let worker = makeSession(model, audioURL, previewing, options)
        let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancel: @Sendable () async -> Void = {
            signals.continuation.finish()
            previews.continuation.yield("")
            previews.continuation.finish()
            await worker.stop()
        }
        LocalModelWarmup.yieldToDictation()
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
        wake = signals.continuation
        self.cloudOnColdLoad = cloudOnColdLoad
        let ring = ring
        let load = Task {
            await LocalModelWarmup.finished(before: id)
            let loadStarted = Date()
            let loaded = await worker.load(from: directory)
            if !Task.isCancelled {
                // Not awaited: the log is diagnostics, the pump is waiting on this task.
                let seconds = Date().timeIntervalSince(loadStarted)
                Task { @MainActor in Self.onLoadEvent?(loaded ? .loaded(model, seconds: seconds) : .failed(model, seconds: seconds)) }
            }
        }
        self.load = load
        pump = Task {
            defer {
                previews.continuation.yield("")
                previews.continuation.finish()
            }
            await load.value
            guard previewing, !Task.isCancelled else { return }
            // A rejected chunk stops previewing; the final decode is unaffected.
            // One second per decode keeps the preview moving without stacking decodes.
            for await _ in signals.stream {
                guard !Task.isCancelled else { return }
                for pcm in ring.drainCoalesced(minBytes: PCMRing.bytesPerSecond, flushAll: false) {
                    guard let preview = await worker.append(pcm) else { return }
                    previews.continuation.yield(String(preview.suffix(512)))
                }
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
        if cloudOnColdLoad,
           case .timedOut = await Self.bounded(seconds: TimeoutPolicy.localColdLoad, { [load] in await load.value }),
           !Task.isCancelled {
            // The load cannot be stopped, so it is finished as a warm-up: the
            // stores stay claimed and the next dictation waits for it.
            Log.transcription.notice("On-device model still loading \(TimeoutPolicy.localColdLoad, format: .fixed(precision: 0))s after the recording; using cloud transcription, load goes on as a warm-up")
            pump.cancel()
            handedOff.withLock { $0 = true }
            let worker = worker
            await LocalModelWarmup.adopt(id: id, model: model, load: load, stop: { await worker.stop() })
            await MainActor.run { Self.onLoadEvent?(.stillLoading(model, waited: TimeoutPolicy.localColdLoad)) }
            return nil
        }
        let deadline = TimeoutPolicy.localLoad + TimeoutPolicy.localTranscribe(frames: framesWritten)
        let outcome = await withTaskCancellationHandler {
            await Self.bounded(seconds: deadline) { [self] in
                await pump.value
                return await worker.transcribe(framesWritten: framesWritten)
            }
        } onCancel: {
            self.load.cancel()
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
        guard !handedOff.withLock({ $0 }) else { return }
        load.cancel()
        pump.cancel()
        await worker.stop()
        await pump.value
        await LocalModelStore.store(for: model).releaseSession(id: id)
        await LocalModelStore.englishTools.releaseSession(id: id)
    }
}
