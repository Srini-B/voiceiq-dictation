import AppIntents
import SwiftUI
import UIKit
import VoiceIQBridge
import VoiceIQCore

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()
    private var transfersDone: (() -> Void)?

    /// The keyboard's background transcription finished while no keyboard
    /// ran (docs/IOS.md, "Dictation in the keyboard").
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == KeyboardTransfers.identifier else { return completionHandler() }
        transfersDone = completionHandler
        model.handleKeyboardTransfers { [weak self] in
            self?.transfersDone?()
            self?.transfersDone = nil
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // The recording is finalized to disk; the next launch transcribes it.
        model.prepareForTermination()
    }
}

@main
struct VoiceIQMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Theme.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.session)
                .environmentObject(delegate.model.hostReturn)
                .environmentObject(delegate.model.setup)
                .tint(Theme.Colors.accent)
                .onOpenURL { delegate.model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: delegate.model.appBecameActive()
            case .background: delegate.model.appEnteredBackground()
            default: break
            }
        }
    }
}

/// "Dictate with VoiceiQ" in Spotlight, Siri and the Shortcuts app with no
/// setup. With an iPad keyboard case attached no on-screen keyboard shows, so
/// this (or the Control Center control) is how a dictation starts: ⌘Space,
/// or a Full Keyboard Access command the user binds to it.
@available(iOS 18.0, *)
struct VoiceIQShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start \(.applicationName) dictation",
            ],
            shortTitle: "Dictate",
            systemImageName: "mic.fill"
        )
    }
}
