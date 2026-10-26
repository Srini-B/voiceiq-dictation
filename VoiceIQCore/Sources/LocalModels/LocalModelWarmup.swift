import Foundation
import os
import VoiceIQSpeech

/// Loads the on-device model and releases it at once, so Core ML prepares it
/// for this device before a dictation needs it. The OS drops that prepared
/// copy after an OS update and after long disuse, and preparing it again can
/// take minutes. Nothing stays in memory afterwards.
@MainActor
public enum LocalModelWarmup {
    private struct Entry {
        let id: UUID
        let model: LocalSpeechModel
        let task: Task<Void, Never>
    }

    /// The load in progress. Only one model loads at a time.
    private static var current: Entry?
    /// Adopted dictation loads waiting for `current` to end, in order. Each
    /// becomes `current` in turn, so an adopted load never replaces the load
    /// it is itself waiting for.
    private static var pending: [Entry] = []

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
        current = Entry(id: id, model: model, task: task)
        await task.value
        store.releaseSession(id: id)
        LocalModelStore.englishTools.releaseSession(id: id)
        ended(id)
        return Outcome(seconds: Date().timeIntervalSince(started), loaded: loaded.withLock { $0 })
    }

    /// A dictation went to the cloud while its model was still loading
    /// (`LocalTranscriber.finish`). Its load continues as a warm-up: the
    /// dictation's claims on the stores stay until the load ends, the next
    /// dictation waits for it (`finished`) and then loads fast, and the
    /// session is stopped once loaded. Nothing stays in memory afterwards.
    /// A load that is itself waiting for a warm-up in progress queues behind
    /// it and becomes the warm-up when that one ends.
    static func adopt(id: UUID, model: LocalSpeechModel, load: Task<Void, Never>, stop: @escaping @Sendable () async -> Void) {
        let entry = Entry(id: id, model: model, task: Task {
            await load.value
            await stop()
            LocalModelStore.store(for: model).releaseSession(id: id)
            LocalModelStore.englishTools.releaseSession(id: id)
            ended(id)
        })
        if current == nil {
            current = entry
        } else {
            pending.append(entry)
        }
    }

    /// The load `id` ended; the next adopted load, if any, takes its place.
    private static func ended(_ id: UUID) {
        guard current?.id == id else { return }
        current = pending.isEmpty ? nil : pending.removeFirst()
    }

    /// A dictation is starting: it takes the model from the warm-ups in
    /// progress and queued. Their loads keep running, and the dictation loads
    /// after them (`finished(before:)`), so two model compiles never overlap.
    static func yieldToDictation() {
        for entry in [current].compactMap({ $0 }) + pending {
            LocalModelStore.store(for: entry.model).releaseSession(id: entry.id)
            LocalModelStore.englishTools.releaseSession(id: entry.id)
        }
    }

    /// A warm-up or an adopted dictation load is in progress.
    public static var isLoading: Bool { current != nil }

    /// Waits for every warm-up and adopted load to end. Polls rather than
    /// awaiting their tasks, so a cancelled caller stops waiting at once.
    public static func finished() async {
        while current != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Waits until the dictation load `id` may start: no load is in progress,
    /// or `id` itself has become the load in progress after being adopted.
    static func finished(before id: UUID) async {
        while let current, current.id != id, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
