#if os(macOS)
import ApplicationServices
import Foundation

/// The text a call app shows in its windows, read through the Accessibility
/// API: name tags on video tiles, the participants list, the user's own
/// "(me)" row. Exact spellings, and it works when the window is covered,
/// where a snapshot only sees what is on top.
enum CallWindowText {
    /// Each read is a synchronous call into the call app, so the walk is
    /// bounded: a call app stalls while it answers.
    static let elementBudget = 2_500
    static let maxDepth = 40
    static let timeBudget: TimeInterval = 0.8

    /// Labels of controls and menus are UI, not people.
    private static let skippedRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuBar", "AXMenu",
        "AXMenuItem", "AXToolbar", "AXTextField", "AXTextArea", "AXScrollBar", "AXSlider", "AXLink",
    ]
    /// MEASURED 2026-10-23, Zoom 7.2.2: a video tile is an `AXTabGroup`
    /// described "Cyron Test, Computer audio unmuted"; the participants list
    /// holds `AXStaticText` "Cyron Test (me)" for the user's own row.
    private static let textRoles: Set<String> = ["AXStaticText", "AXImage", "AXGroup", "AXCell", "AXRow", "AXHeading", "AXTabGroup"]

    static func lines(pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        let deadline = Date().addingTimeInterval(timeBudget)
        var budget = elementBudget
        var out: [String] = [], seen = Set<String>()
        var stack = windows.map { ($0, 0) }
        while let (element, depth) = stack.popLast(), budget > 0, Date() < deadline {
            budget -= 1
            let role = value(element, kAXRoleAttribute) as? String ?? ""
            if skippedRoles.contains(role) { continue }
            if textRoles.contains(role) {
                for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    guard let text = value(element, key) as? String else { continue }
                    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty, line.count <= 80, seen.insert(line).inserted { out.append(line) }
                }
            }
            guard depth < maxDepth, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            stack += children.reversed().map { ($0, depth + 1) }
        }
        return out
    }

    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
}
#endif
