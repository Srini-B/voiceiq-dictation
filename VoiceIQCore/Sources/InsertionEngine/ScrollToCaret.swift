#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Foundation

/// Brings the caret into view after text went in by Accessibility. A
/// selected-text write doesn't scroll the field the way typing does, so in a
/// single-line field that is already full the new text, and the caret after
/// it, stay hidden past the right edge.
@MainActor
enum ScrollToCaret {
    /// Does nothing while the caret is in view. Otherwise sets the same caret
    /// again, and if the field still doesn't scroll, presses Left then Right:
    /// the caret ends where it was, and the field scrolls to it as it does
    /// for any arrow key. Only with a collapsed caret after some text, in
    /// the field the dictation started in.
    static func ensureVisible(_ element: AXUIElement, context: DictationContext) async {
        guard let first = state(of: element), !first.visible else { return }
        var range = CFRange(location: first.reading.caret, length: 0)
        if let value = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
        try? await Task.sleep(for: .milliseconds(60))
        guard let second = state(of: element), second.reading == first.reading else { return }
        if second.visible {
            Log.insertion.info("caret brought into view by setting it again")
            return
        }
        guard first.reading.caret > 0, KeystrokeAccess.mayPost,
              FieldDraft.focusedTarget(context: context).map({ CFEqual($0, element) }) == true else { return }
        press(kVK_LeftArrow)
        press(kVK_RightArrow)
        try? await Task.sleep(for: .milliseconds(80))
        let after = state(of: element)
        Log.insertion.info("caret nudged into view with Left, Right: \(after?.visible == true ? "visible" : "still hidden", privacy: .public), caret kept \(after?.reading == first.reading, privacy: .public)")
    }

    /// The field's text and collapsed caret, and whether the caret is
    /// inside the part of the field on screen. Nil over a selection, or
    /// when the field doesn't say where its caret is.
    private static func state(of element: AXUIElement) -> (reading: PasteCheck.Reading, visible: Bool)? {
        guard let reading = PasteCheck.reading(of: element), reading.selectionLength == 0,
              let caret = FieldDraft.caretRect(in: element, at: reading.caret, of: reading.value),
              let visible = FieldDraft.visibleFrame(of: element) else { return nil }
        return (reading, visible.insetBy(dx: -1, dy: -1).contains(CGPoint(x: caret.minX, y: caret.midY)))
    }

    private static func press(_ key: Int) {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false) else { return }
        for event in [down, up] {
            // As a real arrow key reports itself.
            event.flags = [.maskNumericPad, .maskSecondaryFn]
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventTag.magic)
            event.post(tap: .cghidEventTap)
        }
    }
}
#endif
