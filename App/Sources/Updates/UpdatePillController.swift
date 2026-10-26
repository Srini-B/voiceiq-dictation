import AppKit
import Combine
import VoiceIQCore

/// Installs a downloaded update on its own as soon as nothing is recording, so
/// an update never lands in the middle of a dictation or meeting, and says on
/// the pill that the relaunch was an update.
@MainActor
final class UpdatePillController {
    /// Set by DictationController: a dictation, meeting, or answer is using the app.
    var sessionIsActive: () -> Bool = { false }
    /// Set by DictationController: a short notice on the pill.
    var notice: (String) -> Void = { _ in }

    private static let checkInterval: TimeInterval = 30
    private static let lastLaunchedVersionKey = "lastLaunchedVersion"

    private var updateObservation: AnyCancellable?
    private var timer: Timer?

    func bind() {
        updateObservation = AppUpdater.shared.$availableUpdate.sink { [weak self] update in
            self?.availableUpdateChanged(update)
        }
    }

    private func availableUpdateChanged(_ update: AppUpdater.AvailableUpdate?) {
        guard case .downloaded = update else {
            timer?.invalidate()
            timer = nil
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
                Task { @MainActor [weak self] in self?.installIfFree() }
            }
        }
        // The publisher fires before it stores the new value, so read it on the next turn.
        Task { @MainActor [weak self] in self?.installIfFree() }
    }

    private func installIfFree() {
        guard case .downloaded = AppUpdater.shared.availableUpdate, !sessionIsActive() else { return }
        AppUpdater.shared.installDownloadedUpdate()
    }

    /// The relaunch after an update is otherwise silent. Call once the pill is
    /// on screen.
    func announceIfJustUpdated() {
        let defaults = UserDefaults.standard
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let previous = defaults.string(forKey: Self.lastLaunchedVersionKey)
        defaults.set(current, forKey: Self.lastLaunchedVersionKey)
        guard let previous, previous != current else { return }
        // The coordinator's first state arrives a beat after launch and repaints
        // the pill, so a notice shown straight away would vanish unseen.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.notice("Updated to VoiceiQ \(current)")
        }
    }
}
