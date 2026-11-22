#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import os

/// Chromium/Electron apps build their accessibility tree lazily; setting
/// `AXManualAccessibility` asks for it. That set is a SYNCHRONOUS cross-process
/// call serialized on the TARGET app's main thread, and the renderer then builds
/// its tree asynchronously — both facts say the same thing: wake at session
/// START, while the user is still speaking, never after the transcript exists
/// and the user is waiting to see their words.
public enum AccessibilityWaker {
    private static let woken = OSAllocatedUnfairLock<Set<pid_t>>(initialState: [])

    /// Fire-and-forget; returns in microseconds. Safe from the main actor.
    public static func wakeIfNeeded(bundleID: String?, pid: pid_t?) {
        guard let pid else { return }
        let isFirst = woken.withLock { $0.insert(pid).inserted }
        guard isFirst else { return } // AX mode is sticky for the app's lifetime
        Task.detached(priority: .utility) {
            let listed = bundleID.map(AppQuirks.needsManualAccessibility.contains) ?? false
            guard listed || isElectron(NSRunningApplication(processIdentifier: pid)?.bundleURL) else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.5)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    /// Any Electron app, not only the listed ones, ships the framework inside
    /// its bundle (FluidVoice's rule, altic-dev/FluidVoice).
    static func isElectron(_ bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }
}
#endif
