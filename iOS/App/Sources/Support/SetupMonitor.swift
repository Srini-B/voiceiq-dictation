import ActivityKit
import AVFoundation
import Combine
import Foundation
import VoiceIQBridge
import VoiceIQCore

struct SetupStatus: Equatable {
    /// An AssemblyAI key, or the on-device model the settings pick, downloaded.
    var hasKey: Bool
    var micGranted: Bool
    var micDenied: Bool
    var keyboardAdded: Bool
    /// Confirmed only once the keyboard has run with Full Access: iOS offers
    /// the containing app no way to read the setting itself.
    var fullAccess: Bool
    var liveActivitiesEnabled: Bool

    var keyboardReady: Bool { keyboardAdded && fullAccess }
    var isComplete: Bool { hasKey && micGranted && keyboardReady }

    @MainActor static func current() -> SetupStatus {
        SharedStore.shared.reloadFromDisk()
        // Removing the keyboard voids the Full Access proof: added back, it
        // has to run once with Full Access again before it counts as ready.
        if !MobileSettings.keyboardAdded, SharedStore.shared.keyboardSeenAt != nil {
            SharedStore.shared.keyboardSeenAt = nil
        }
        let record = AVAudioApplication.shared.recordPermission
        return SetupStatus(
            hasKey: DictationRoute.isAvailable,
            micGranted: record == .granted,
            micDenied: record == .denied,
            keyboardAdded: MobileSettings.keyboardAdded,
            fullAccess: MobileSettings.keyboardHasFullAccess,
            liveActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled
        )
    }
}

/// One source of truth for setup progress. Refreshes when the app returns to
/// the foreground, when the keyboard reports that it ran with Full Access, when
/// a key is saved, and when Live Activities are switched on or off.
@MainActor
final class SetupMonitor: ObservableObject {
    @Published private(set) var status = SetupStatus.current()

    private var keyboardObserver: UUID?
    private var settingsObserver: NSObjectProtocol?
    private var enablementTask: Task<Void, Never>?

    init() {
        keyboardObserver = DarwinNotifier.observe(.keyboard) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .gtSettingDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        enablementTask = Task { [weak self] in
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                await MainActor.run { self?.refresh() }
            }
        }
    }

    func refresh() {
        let fresh = SetupStatus.current()
        if fresh != status { status = fresh }
    }

    func requestMicrophone() {
        Task {
            _ = await AVAudioApplication.requestRecordPermission()
            refresh()
        }
    }
}
