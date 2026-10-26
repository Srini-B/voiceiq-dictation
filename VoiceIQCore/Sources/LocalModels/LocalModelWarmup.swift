import Foundation
import os
import VoiceIQSpeech

/// Loads the on-device model and releases it at once, so Core ML prepares it
/// for this device before a dictation needs it. The OS drops that prepared
/// copy after an OS update and after long disuse, and preparing it again can
/// take minutes. Nothing stays in memory afterwards.
@MainActor
public enum LocalModelWarmup {
    private static var current: (id: UUID, model: LocalSpeechModel, task: Task<Void, Never>)?

    public struct Outcome: Sendable {
        public let seconds: TimeInterval
        /// False when the session reported a failed load: nothing was prepared.
        public let loaded: Bool
    }

    /// Loads what a dictation would load (the model the on-device settings
    /// use, plus the English tools a dictation in the current language
    /// takes), if it is downloaded and not in use. Returns the load time and
    /// whether the load succeeded, or nil when nothing was loaded.
    public static func run(makeSession: LocalSpeechSessionFactory) async -> Outcome? {
        if let current {
            await current.task.value
            return nil
        }
        let settings = SettingsStore()
        guard settings.localTranscriptionEnabled || settings.localMeetingTranscriptionEnabled else { return nil }
        let model = settings.localTranscriptionEnabled ? settings.localSpeechModel : .parakeet
        let language = settings.localTranscriptionEnabled ? settings.localSpeechLanguage : model.language(code: nil)
        let (options, toolsReady) = LocalTranscriber.sessionOptions(language: language)
        let store = LocalModelStore.store(for: model)
        let id = UUID()
        let session = makeSession(model, FileManager.default.temporaryDirectory, false, options)
        let cancel: @Sendable () async -> Void = { await session.stop() }
        guard let directory = store.acquireSession(id: id, cancel: cancel) else { return nil }
        if toolsReady, LocalModelStore.englishTools.acquireSession(id: id, cancel: cancel) == nil {
            store.releaseSession(id: id)
            return nil
        }
        let started = Date()
        let loaded = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            let ok = await session.load(from: directory)
            loaded.withLock { $0 = ok }
            await session.stop()
        }
        current = (id, model, task)
        await task.value
        store.releaseSession(id: id)
        LocalModelStore.englishTools.releaseSession(id: id)
        current = nil
        return Outcome(seconds: Date().timeIntervalSince(started), loaded: loaded.withLock { $0 })
    }

    /// A dictation went to the cloud while its model was still loading
    /// (`LocalTranscriber.finish`). Its load continues as a warm-up: the
    /// dictation's claims on the stores stay until the load ends, the next
    /// dictation waits for it (`finished`) and then loads fast, and the
    /// session is stopped once loaded. Nothing stays in memory afterwards.
    static func adopt(id: UUID, model: LocalSpeechModel, load: Task<Void, Never>, stop: @escaping @Sendable () async -> Void) {
        let task = Task {
            await load.value
            await stop()
            LocalModelStore.store(for: model).releaseSession(id: id)
            LocalModelStore.englishTools.releaseSession(id: id)
            if current?.id == id { current = nil }
        }
        current = (id, model, task)
    }

    /// A dictation is starting: it takes the model from a warm-up in progress.
    /// The warm-up's load keeps running, and the dictation loads after it
    /// (`finished`), so two Neural Engine compiles never overlap.
    static func yieldToDictation() {
        guard let current else { return }
        LocalModelStore.store(for: current.model).releaseSession(id: current.id)
        LocalModelStore.englishTools.releaseSession(id: current.id)
    }

    /// A warm-up or an adopted dictation load is in progress.
    public static var isLoading: Bool { current != nil }

    /// Polls rather than awaiting the warm-up's task, so a cancelled
    /// dictation stops waiting at once.
    public static func finished() async {
        while current != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
