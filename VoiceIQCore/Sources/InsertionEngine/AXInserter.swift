#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import VoiceIQBridge

/// Tier 1: direct Accessibility insertion at the cursor — no clipboard involved.
///
/// Verification is mandatory: Electron apps report AX set success without
/// inserting (Electron #36337/#37465). We verify by comparing the element's value
/// before and after — substitution-proof (smart quotes) and lie-proof: if the
/// value didn't change, the insert didn't happen and the ladder falls through.
@MainActor
public enum AXInserter {
    public enum Result {
        case landed
        /// AX couldn't do it here — the paste tier is still appropriate.
        case notPossible
        /// PROVEN focus theft: the focused element belongs to a different app,
        /// or is a different field of the same app than the one dictation
        /// started in. A blind ⌘V would paste the transcript into the thief.
        case focusElsewhere
    }

    /// The target app's focused element when text can be typed into it (its
    /// selected text is settable, the same test the insert below needs), else
    /// nil. Called off the main thread at session start. A Chromium or
    /// Electron app may not have built its accessibility tree yet and answer
    /// nil or a non-text element; that counts as "can't tell", so the insert
    /// compares nothing (Parrot's rule, humanitas-labs/parrot, MIT).
    public nonisolated static func focusedTextField(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }
        return element
    }

    /// Records the target app's focused text field and the text around its
    /// cursor, for the field guard and the writing model.
    public nonisolated static func captureFocusedField(pid: pid_t, into capture: FocusedFieldCapture) {
        let element = focusedTextField(pid: pid)
        capture.set(element, surroundingText: element.flatMap(surroundingText(of:)))
    }

    /// The text around the cursor of the focused field, when it belongs to
    /// `targetPID` and says where its cursor is. Read right before inserting.
    public static func surroundingText(targetPID: pid_t?) -> SurroundingText? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, targetPID == nil || targetPID == pid else { return nil }
        return surroundingText(of: element)
    }

    nonisolated static func surroundingText(of element: AXUIElement) -> SurroundingText? {
        var rangeRef: CFTypeRef?
        guard let value = fieldText(of: element),
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return SurroundingText(value: value, selectionLocation: range.location, selectionLength: range.length)
    }

    public static func insert(_ text: String, targetPID: pid_t?, bundleID: String?, startField: AnyObject? = nil) async -> Result {
        if let bundleID, AppQuirks.forcePaste.contains(bundleID) {
            return .notPossible
        }
        // The Chromium a11y wake now happens at session START (AccessibilityWaker),
        // so it never blocks the user's wait for their words.
        let system = AXUIElementCreateSystemWide()
        // A hung target would park this @MainActor call until the system default
        // messaging timeout (seconds), stalling the pill, the status item and the
        // hotkey intent stream behind it. Bound it — a target that can't answer
        // in 1.5s is demoted to the paste tier instead of freezing the app.
        // Deliberately generous: a premature timeout on the SET below would fall
        // through to ⌘V and DOUBLE-INSERT (audit #9).
        AXUIElementSetMessagingTimeout(system, 1.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .notPossible
        }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        // The system-wide focused element must belong to the app the user was
        // dictating into — not whatever stole focus a frame ago (audit L24).
        if let targetPID {
            var elementPID: pid_t = 0
            if AXUIElementGetPid(element, &elementPID) == .success, elementPID != targetPID {
                Log.insertion.info("AXInserter: focused element belongs to a different app — chip, never blind paste")
                return .focusElsewhere
            }
        }
        // Same app, different text field: the user clicked elsewhere while
        // the words were being written up.
        if let startField, !CFEqual(startField as CFTypeRef, element) {
            Log.insertion.info("AXInserter: focus moved to another field since dictation started — chip, never blind paste")
            return .focusElsewhere
        }

        // Never write into secure fields.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == "AXSecureTextField" {
            return .notPossible
        }

        // Readable value is the precondition for verification; without it we cannot
        // prove the insert landed, so we fall to paste rather than risk a double.
        guard let before = stringValue(of: element) else { return .notPossible }

        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else { return .notPossible }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else {
            return .notPossible
        }

        var after = stringValue(of: element)
        var landed = after != nil && after != before
        if !landed {
            // Some apps (web content, async editors) update the AX value a beat
            // late; re-check before falling to paste — a false negative here
            // would DOUBLE-insert (AX landed + ⌘V lands again; audit #9). Poll
            // rather than sleep the full budget: most apps answer on the first
            // step, and only the slow ones pay the rest.
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 40_000_000)
                after = stringValue(of: element)
                landed = after != nil && after != before
                if landed { break }
            }
        }
        if !landed {
            Log.insertion.info("AXInserter: set reported success but value unchanged after re-check — falling to paste")
        }
        return landed ? .landed : .notPossible
    }

    public static func focusedField(targetPID: pid_t?, bundleID: String?) -> FieldSnapshot? {
        if let bundleID, AppQuirks.forcePaste.contains(bundleID) { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              targetPID == nil || targetPID == pid,
              fieldText(of: element) != nil else { return nil }
        return FieldSnapshot(element: element, pid: pid, bundleID: bundleID)
    }

    nonisolated static func stringValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

    /// The field's text for auto-learn. WhatsApp's message box reports no
    /// value at all when it is empty (kAXErrorNoValue) rather than "", which
    /// read as an unreadable field, so a new message was never tracked. A
    /// field with no value that says it holds zero characters reads as "".
    nonisolated static func fieldText(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        if result == .success { return valueRef as? String }
        var countRef: CFTypeRef?
        guard result == .noValue,
              AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              (countRef as? Int) == 0 else { return nil }
        return ""
    }

    /// Chromium builds its a11y tree lazily; AXManualAccessibility asks for it
    /// without the VoiceOver-reserved side effects. First set can take a moment on
    /// big apps — the ladder's fallback covers the not-ready case.
}
#endif
