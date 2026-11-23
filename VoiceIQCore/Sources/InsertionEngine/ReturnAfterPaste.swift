#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import os

/// Press Return after a dictation lands, to send a chat message or run a
/// command. Off by default; it can be limited to chosen apps. Esc pressed after
/// the recording ended skips the Return and keeps the text. The timings are
/// Hex's (anomalyco/hex, `src/dictation/yolo_mode.rs`, MIT): Return no sooner
/// than 500 ms after the key ended the recording, and 100 ms after the text
/// went in.
public enum ReturnAfterPaste {
    static let escapeWindow: TimeInterval = 0.5
    static let settle: TimeInterval = 0.1

    private static let lastEscape = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// From the event tap, for every Esc key-down.
    static func noteEscape() {
        lastEscape.withLock { $0 = Date() }
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
    }

    /// An empty app list means every app.
    public static func applies(to bundleID: String?, apps: [String]) -> Bool {
        apps.isEmpty || bundleID.map(apps.contains) == true
    }

    static func isWanted(for context: DictationContext) -> Bool {
        let settings = SettingsStore()
        return settings.pressReturnAfterPaste && applies(to: context.targetAppBundleID, apps: settings.pressReturnApps)
    }

    @MainActor
    /// `target` is the field focused before the insert began. Return must
    /// reach the field the text went into: switching to another field or
    /// window of the same app during the insert or the wait would send
    /// something else.
    static func pressIfWanted(context: DictationContext, target: AXUIElement?) async {
        guard isWanted(for: context) else { return }
        let ended = context.recordingEndedAt ?? Date()
        let wait = max(ended.addingTimeInterval(escapeWindow).timeIntervalSinceNow, settle)
        try? await Task.sleep(for: .seconds(wait))
        if let escape = lastEscape.withLock({ $0 }), escape >= ended {
            Log.insertion.info("Esc after the recording ended — no Return")
            return
        }
        guard let pid = context.targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let target, let now = focusedElement(), CFEqual(target, now) else {
            Log.insertion.info("focus moved before Return — no Return")
            return
        }
        // An Esc can land on the tap's thread while focus was being read.
        if let escape = lastEscape.withLock({ $0 }), escape >= ended {
            Log.insertion.info("Esc after the recording ended — no Return")
            return
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventTag.magic)
        }
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 10_000_000)
        up.post(tap: .cghidEventTap)
        Log.insertion.info("pressed Return after the paste")
    }
}
#endif
