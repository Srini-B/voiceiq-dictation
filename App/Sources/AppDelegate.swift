import AppKit
import Combine
import VoiceIQCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var dictationController: DictationController?
    private var availableUpdateObservation: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Single instance, always: two copies means two event taps, two pills,
        // and a race over the History DB. The newer instance defers.
        let bundleID = Bundle.main.bundleIdentifier ?? "io.blue.voiceiq"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            Log.session.warning("another VoiceiQ instance is already running — quitting this one")
            NSApp.terminate(nil)
            return
        }
        // The launch-triggering GURL Apple event arrives BETWEEN will- and
        // didFinishLaunching — registering in did- silently dropped any
        // voiceiq:// URL that cold-launched the app (production pass 2).
        registerURLHandler()
        // Before ANYTHING reads the Keychain, defaults, or History: carry over
        // everything from the app's pre-rename identity.
        LegacyMigration.runIfNeeded()
        // AFTER LegacyMigration: smartFormatting is in its key list and has to be
        // pulled out of the old defaults domain before this reads it.
        FormattingSettingsMigration.runIfNeeded()
        FormattingSettingsMigration.enableWritingRulesIfNeeded()
        FormattingSettingsMigration.removeLiveTranscriptionSettings()
        FormattingSettingsMigration.restoreAutoDegradedWritingRulesOnce()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // An accessory app does not reliably adopt CFBundleIconFile for the
        // standard About panel — it showed the generic placeholder. Load it
        // from the bundle explicitly.
        if let iconURL = Bundle.main.url(forResource: "VoiceIQ", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
            Log.ui.info("app icon set from \(iconURL.lastPathComponent, privacy: .public) size \(icon.size.width, format: .fixed(precision: 0))")
        } else {
            Log.ui.error("app icon NOT set — url: \(Bundle.main.url(forResource: "VoiceIQ", withExtension: "icns")?.path ?? "nil", privacy: .public)")
        }
        FontLoader.registerBundledFonts()
        // Before sync starts, so the cleanup goes up with the first merge.
        EditLearner.pruneOrdinaryAutoLearnedOnce()
        // Dictionary shared with the iPhone through iCloud; always on.
        DictionarySync.shared.start()
        let controller = DictationController()
        statusItemController = StatusItemController(
            onOpenHistory: { [weak controller] in controller?.openHistory() },
            onPasteLast: { [weak controller] in controller?.pasteLastTranscript() },
            onOpenSettings: { [weak controller] in controller?.openSettings() },
            onStartHandsFree: { [weak controller] in controller?.startHandsFree() },
            onOpenAbout: { [weak controller] in controller?.openSettings(section: "about") },
            onCheckForUpdates: { AppUpdater.shared.checkForUpdates() }
        )
        AppUpdater.shared.start()
        availableUpdateObservation = AppUpdater.shared.$availableUpdate.sink { [weak self] update in
            self?.statusItemController?.setAvailableUpdate(update)
        }
        controller.onStatusChange = { [weak self] status in
            self?.statusItemController?.setStatusLine(status)
        }
        controller.onStatusItemState = { [weak self] state in
            self?.statusItemController?.setState(state)
        }
        controller.start()
        dictationController = controller
        // Replay any voiceiq:// URL that cold-launched the app.
        for url in pendingLaunchURLs { dispatch(url) }
        pendingLaunchURLs.removeAll()
        Log.session.info("VoiceiQ launched (build \(Bundle.main.buildNumber, privacy: .public))")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Cmd-Q mid-recording: finalize so the CAF is complete and the words are
    /// recoverable at next launch — never silently strand a live session.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            dictationController?.prepareForTermination()
        }
        return .terminateNow
    }

    /// voiceiq:// URL scheme — Raycast/Shortcuts automation + headless UI checks.
    /// voiceiq://settings[/general|dictation|privacy|advanced] | history | dictionary
    ///   | onboarding | start-hands-free | stop
    /// NOTE: registered via NSAppleEventManager in didFinishLaunching — the
    /// NSApplicationDelegate application(_:open:) path is NOT delivered under the
    /// SwiftUI App lifecycle.
    func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// URLs that arrived before the controller existed (cold launch via URL) —
    /// replayed at the end of didFinishLaunching.
    private var pendingLaunchURLs: [URL] = []

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        guard dictationController != nil else {
            pendingLaunchURLs.append(url)
            return
        }
        dispatch(url)
    }

    private func dispatch(_ url: URL) {
        guard url.scheme?.lowercased() == "voiceiq" else {
            Log.session.warning("ignored URL with unsupported scheme: \(url.absoluteString, privacy: .public)")
            return
        }
        let command = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let section = url.pathComponents.count > 1 ? url.pathComponents[1] : nil
        Log.session.info("URL command: \(command, privacy: .public)")
        Task { @MainActor [weak self] in
            switch command {
            case "settings":
                self?.dictationController?.openSettings(section: section)
            case "history": self?.dictationController?.openHistory()
            case "dictionary": self?.dictationController?.openDictionary()
            case "onboarding":
                self?.dictationController?.presentOnboardingManually()
                if let section, let index = Int(section) {
                    // A freshly created window hasn't subscribed yet — give the
                    // flow view one beat before the jump (automation hook).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        NotificationCenter.default.post(name: .onboardingJumpToScreen, object: index)
                    }
                }
            case "start-hands-free": self?.dictationController?.startHandsFree()
            case "stop": self?.dictationController?.coordinator.handle(.finalize)
            #if DEBUG
            // voiceiq://agent — the agent shortcut; voiceiq://agent/<command> —
            // opens the agent panel and runs the command as if it were spoken,
            // so the loop can be exercised without a microphone. Debug only.
            case "agent":
                let command = url.pathComponents.dropFirst().joined(separator: "/")
                self?.dictationController?.debugAgent(command: command.isEmpty ? nil : command)
            // voiceiq://set/<key>/<true|false> — flips a boolean setting through
            // the REAL SettingsStore setter (and its change notification), so the
            // live-update path can be exercised headlessly. Debug builds only.
            case "set":
                let parts = url.pathComponents
                if parts.count >= 3, let value = Bool(parts[2]) {
                    Self.applyDebugSetting(key: parts[1], value: value)
                }
            #endif
            default: Log.session.warning("unknown URL: \(url.absoluteString, privacy: .public)")
            }
        }
    }

    #if DEBUG
    private static func applyDebugSetting(key: String, value: Bool) {
        let settings = SettingsStore()
        switch key {
        case "showIdleIndicator": settings.setShowIdleIndicator(value)
        case "soundsEnabled": settings.setSoundsEnabled(value)
        case "experimentalNoiseHandling": settings.setExperimentalNoiseHandling(value)
        case "smartTranscription": settings.setSmartTranscription(value)
        case "smartCleanupPass": settings.setSmartCleanupPass(value)
        default: Log.session.warning("debug set: unknown key \(key, privacy: .public)")
        }
    }
    #endif

}

extension Bundle {
    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}
