import Foundation
import os
import VoiceIQSpeech

/// One dictation on the on-device model. The model loads while the user
/// speaks; `finish` decodes the saved recording, so the CAF is the only
/// source of the transcript. Nothing is shown while recording.
public final class LocalTranscriber: Sendable {
    private let id: UUID
    private let model: LocalSpeechModel
    private let worker: any LocalSpeechSession
    /// Waits for any warm-up, then loads the model. Starts with the recording.
    private let load: Task<Void, Never>
    /// A load still running `TimeoutPolicy.localColdLoad` after the recording
    /// sends the dictation to Gemini and goes on as a warm-up. The caller
    /// passes whether Gemini can take it.
    private let cloudOnColdLoad: Bool
    /// Set when the load was handed to `LocalModelWarmup`; a later `abort`
    /// must then leave it running.
    private let handedOff = OSAllocatedUnfairLock(initialState: false)

    public enum LoadEvent: Sendable {
        /// The model loaded, in `seconds` from the start of the recording.
        case loaded(LocalSpeechModel, seconds: TimeInterval)
        /// The load failed after `seconds`; the dictation goes to Gemini.
        case failed(LocalSpeechModel, seconds: TimeInterval)
        /// The model was still loading `waited` seconds after the recording
        /// ended; the dictation went to Gemini and the load goes on.
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

    /// The transcriber for a dictation by the on-device settings, or nil when
    /// they pick Gemini or the model is not downloaded or busy.
    @MainActor public static func makeFromSettings(audioURL: URL, cloudOnColdLoad: Bool,
                                                   makeSession: LocalSpeechSessionFactory) -> LocalTranscriber? {
        let settings = SettingsStore()
        guard settings.localTranscriptionEnabled else { return nil }
        return LocalTranscriber(audioURL: audioURL, model: settings.localSpeechModel,
                                language: settings.localSpeechLanguage,
                                cloudOnColdLoad: cloudOnColdLoad, makeSession: makeSession)
    }

    /// `cloudOnColdLoad`: Gemini can transcribe, so a dictation whose model
    /// is still loading after the recording can go there.
    @MainActor public init?(audioURL: URL, model: LocalSpeechModel, language: LocalSpeechLanguage,
                           cloudOnColdLoad: Bool, makeSession: LocalSpeechSessionFactory) {
        let id = UUID()
        let (options, toolsReady) = Self.sessionOptions(language: language)
        let worker = makeSession(model, audioURL, false, options)
        // The warm-ups this dictation takes the model from keep loading its
        // files, so a delete waits for them as well as for this dictation.
        let cancel: @Sendable () async -> Void = {
            await worker.stop()
            await LocalModelWarmup.finished()
        }
        // Both claims or neither: a warm-up keeps its claims unless both
        // stores can be taken over at once.
        let speech = LocalModelStore.store(for: model), tools = LocalModelStore.englishTools
        let warmups = LocalModelWarmup.claimIDs
        guard speech.canAcquire(replacing: warmups), !toolsReady || tools.canAcquire(replacing: warmups),
              let directory = speech.acquireSession(id: id, replacing: warmups, cancel: cancel) else { return nil }
        if toolsReady, tools.acquireSession(id: id, replacing: warmups, cancel: cancel) == nil {
            speech.releaseSession(id: id)
            return nil
        }
        self.id = id
        self.model = model
        self.worker = worker
        self.cloudOnColdLoad = cloudOnColdLoad
        load = Task {
            await LocalModelWarmup.finished(before: id)
            let loadStarted = Date()
            let loaded = await worker.load(from: directory)
            if !Task.isCancelled {
                let seconds = Date().timeIntervalSince(loadStarted)
                Task { @MainActor in Self.onLoadEvent?(loaded ? .loaded(model, seconds: seconds) : .failed(model, seconds: seconds)) }
            }
        }
    }

    /// The transcript of the saved recording, or nil when Gemini should
    /// transcribe it instead: the load failed, or ran past its time.
    public func finish(framesWritten: Int64) async -> TranscriptionResult? {
        if cloudOnColdLoad,
           case .timedOut = await Self.bounded(seconds: TimeoutPolicy.localColdLoad, { [load] in await load.value }),
           !Task.isCancelled {
            // The load cannot be stopped, so it is finished as a warm-up: the
            // stores stay claimed and the next dictation waits for it.
            Log.transcription.notice("On-device model still loading \(TimeoutPolicy.localColdLoad, format: .fixed(precision: 0))s after the recording; using Gemini, load goes on as a warm-up")
            handedOff.withLock { $0 = true }
            let worker = worker
            await LocalModelWarmup.adopt(id: id, model: model, load: load, stop: { await worker.stop() })
            await MainActor.run { Self.onLoadEvent?(.stillLoading(model, waited: TimeoutPolicy.localColdLoad)) }
            return nil
        }
        let deadline = TimeoutPolicy.localLoad + TimeoutPolicy.localTranscribe(frames: framesWritten)
        let outcome = await withTaskCancellationHandler {
            await Self.bounded(seconds: deadline) { [self] in
                await load.value
                return await worker.transcribe(framesWritten: framesWritten)
            }
        } onCancel: {
            self.load.cancel()
            Task { await self.worker.stop() }
        }
        // The models stay claimed until the work has stopped, so a delete or
        // the next dictation never meets an inference still running.
        let (worker, model, id) = (worker, model, id)
        let release: @Sendable () async -> Void = {
            await worker.stop()
            await LocalModelStore.store(for: model).releaseSession(id: id)
            await LocalModelStore.englishTools.releaseSession(id: id)
        }
        if case .finished = outcome {
            await release()
        } else {
            Log.transcription.notice("On-device transcription passed \(deadline, format: .fixed(precision: 0))s; using saved audio with Gemini")
            Task { await release() }
        }
        guard !Task.isCancelled, case .finished(let text?) = outcome else { return nil }
        if let confidence = text.confidence {
            Log.transcription.notice("Parakeet token confidence (uncalibrated): \(confidence)")
        }
        UsageMeter.record(stage: .transcribe, model: model.modelID,
                          usage: TokenUsage(reportedCostUSD: 0, audioSeconds: Double(framesWritten) / 16_000))
        return TranscriptionResult(rawTranscript: text.original, cleanedTranscript: text.normalized, modelID: model.modelID)
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
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
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
        guard !handedOff.withLock({ $0 }) else { return }
        load.cancel()
        await worker.stop()
        await LocalModelStore.store(for: model).releaseSession(id: id)
        await LocalModelStore.englishTools.releaseSession(id: id)
    }
}
