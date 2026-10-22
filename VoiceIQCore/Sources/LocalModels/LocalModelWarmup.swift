import Foundation
import VoiceIQSpeech

/// Loads the on-device model and releases it at once, so Core ML prepares it
/// for this device before a dictation needs it. The OS drops that prepared
/// copy after an OS update and after long disuse, and preparing it again can
/// take minutes. Nothing stays in memory afterwards.
@MainActor
public enum LocalModelWarmup {
    private static var current: (id: UUID, model: LocalSpeechModel, task: Task<Void, Never>)?

    /// Loads the model the on-device settings use, if it is downloaded and not
    /// in use. Returns the load time, or nil when nothing was loaded.
    public static func run(makeSession: LocalSpeechSessionFactory) async -> TimeInterval? {
        if let current {
            await current.task.value
            return nil
        }
        let settings = SettingsStore()
        guard settings.localTranscriptionEnabled || settings.localMeetingTranscriptionEnabled else { return nil }
        let model = settings.localTranscriptionEnabled ? settings.localSpeechModel : .parakeet
        let store = LocalModelStore.store(for: model)
        let id = UUID()
        let session = makeSession(model, FileManager.default.temporaryDirectory, false, LocalSpeechOptions())
        guard let directory = store.acquireSession(id: id, cancel: { await session.stop() }) else { return nil }
        let started = Date()
        let task = Task {
            await session.load(from: directory)
            await session.stop()
        }
        current = (id, model, task)
        await task.value
        store.releaseSession(id: id)
        current = nil
        return Date().timeIntervalSince(started)
    }

    /// A dictation is starting: it takes the model from a warm-up in progress.
    /// The warm-up's load keeps running, and the dictation loads after it
    /// (`finished`), so two Neural Engine compiles never overlap.
    static func yieldToDictation() {
        guard let current else { return }
        LocalModelStore.store(for: current.model).releaseSession(id: current.id)
    }

    /// Polls rather than awaiting the warm-up's task, so a cancelled
    /// dictation stops waiting at once.
    static func finished() async {
        while current != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
