import AppKit
import Combine
import Sparkle
import VoiceIQCore

/// Sparkle's updater and the app's view of it. The feed, signing key and
/// defaults live in Info.plist (project.yml); see docs/UPDATES.md.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// An update Sparkle found on its own schedule that the user has not dealt
    /// with yet. The status menu offers it, because a menu bar app's update
    /// alert opens behind whatever the user is working in.
    enum AvailableUpdate: Equatable {
        /// Checking for updates shows Sparkle's alert for it.
        case found(version: String)
        /// Downloaded and verified; `installDownloadedUpdate()` applies it and
        /// relaunches, and quitting applies it too.
        case downloaded(version: String)
    }

    @Published private(set) var availableUpdate: AvailableUpdate?
    private var installDownloaded: (() -> Void)?

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    private var observations: Set<AnyCancellable> = []

    private var updater: SPUUpdater { controller.updater }

    func start() {
        controller.startUpdater()
        // The update alert's own checkbox changes these too.
        let changes: [AnyPublisher<Void, Never>] = [
            updater.publisher(for: \.canCheckForUpdates).map { _ in }.eraseToAnyPublisher(),
            updater.publisher(for: \.automaticallyChecksForUpdates).map { _ in }.eraseToAnyPublisher(),
            updater.publisher(for: \.automaticallyDownloadsUpdates).map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    /// A downloaded update installs at once; otherwise this also brings back
    /// an update alert that opened behind other windows.
    func checkForUpdates() {
        if case .downloaded = availableUpdate {
            installDownloadedUpdate()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Quits, replaces the app and relaunches it. Does nothing without a
    /// downloaded update.
    func installDownloadedUpdate() {
        guard let installDownloaded else { return }
        Log.session.info("installing downloaded update and relaunching")
        installDownloaded()
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            Log.session.info("update \(version, privacy: .public) downloaded; installs on quit")
            installDownloaded = immediateInstallHandler
            availableUpdate = .downloaded(version: version)
        }
        // The app takes over when to install: UpdatePillController applies it
        // once nothing is recording. Quitting still installs it.
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.session.error("update check failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { availableUpdate = .found(version: version) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { availableUpdate = nil }
    }
}
