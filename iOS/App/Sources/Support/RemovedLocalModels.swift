import Foundation
import VoiceIQCore

enum RemovedLocalModels {
    static func cleanUp() {
        for key in ["localTranscriptionEnabled", "localSpeechModel"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let models = FileLayout.appSupportRoot.appendingPathComponent("Models", isDirectory: true)
        // No inference or downloader runs on iOS now. Retry on every launch
        // if protected files were unavailable during the previous attempt.
        Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: models.path) else { return }
            do {
                try FileManager.default.removeItem(at: models)
            } catch {
                Log.session.error("Could not remove retired local models: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
