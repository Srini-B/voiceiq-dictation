import BackgroundTasks
import Foundation
import os
import VoiceIQCore
import VoiceIQInference

/// Keeps Core ML's prepared copy of the on-device model fresh, so the first
/// dictation after an iOS update or a long break does not wait minutes for it:
/// - a background processing task, which iOS runs when the phone is idle
///   (usually overnight), plugged in or not;
/// - right away when the app opens on an iOS version the model was not warmed
///   on, because an update always drops the prepared copy, whenever it ran.
/// Each warm-up loads the model and releases it (`LocalModelWarmup`).
@MainActor
enum ModelWarmer {
    static let taskID = "io.blue.voiceiq.ios.warm-model"
    private static let warmedOSKey = "modelWarmedOSVersion"

    /// Before launch finishes, as BGTaskScheduler requires.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { task in
            MainActor.assumeIsolated { handle(task) }
        }
    }

    /// Replaces any pending request.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            SessionDiagnostics.note("model warm-up not scheduled: \(error.localizedDescription)")
        }
    }

    static func warmIfSystemUpdated() {
        guard UserDefaults.standard.string(forKey: warmedOSKey) != osVersion else { return }
        Task { await warm(reason: "iOS version not warmed yet") }
    }

    private static func handle(_ task: BGTask) {
        schedule()
        let completed = OSAllocatedUnfairLock(initialState: false)
        let complete: @Sendable (Bool) -> Void = { success in
            if completed.withLock({ let first = !$0; $0 = true; return first }) {
                task.setTaskCompleted(success: success)
            }
        }
        // Core ML cannot stop a load; on expiry iOS only stops waiting.
        task.expirationHandler = { complete(false) }
        Task {
            await warm(reason: "background task")
            complete(true)
        }
    }

    private static func warm(reason: String) async {
        let before = PreparedModelCache.description
        guard let outcome = await LocalModelWarmup.run(makeSession: LocalSpeechInference.makeSession) else { return }
        let detail = String(format: "(%@, %@, before: %@, after: %@)", reason, SessionDiagnostics.processAge,
                            before, PreparedModelCache.description)
        guard outcome.loaded else {
            SessionDiagnostics.note(String(format: "model warm-up failed after %.1fs %@", outcome.seconds, detail))
            return
        }
        UserDefaults.standard.set(osVersion, forKey: warmedOSKey)
        SessionDiagnostics.note(String(format: "model warmed in %.1fs %@", outcome.seconds, detail))
    }

    private static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}
