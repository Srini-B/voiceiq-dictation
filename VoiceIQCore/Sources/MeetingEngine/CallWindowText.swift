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

    /// `browser`: only the window whose tab is the meeting is read. Every
    /// window was read before; on 2026-11-23 a GitHub tab's names reached a
    /// Meet call's notes.
    static func lines(pid: pid_t, browser: Bool = false) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard var windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        if browser {
            windows = windows.filter(isMeeting)
            // A joined room wins over the browser's other call-site pages, which include chats (Codex on #146).
            let rooms = windows.filter(isJoinedRoom)
            if !rooms.isEmpty { windows = rooms }
        }
        let deadline = Date().addingTimeInterval(timeBudget)
        var budget = elementBudget
        var out: [String] = [], seen = Set<String>()
        var stack = windows.map { ($0, 0) }
        while let (element, depth) = stack.popLast(), budget > 0, Date() < deadline {
            budget -= 1
            let role = value(element, kAXRoleAttribute) as? String ?? ""
            if skippedRoles.contains(role) {
                // The participants button carries the call's head count
                // ("People", badge "3"), the one button label kept.
                if role == "AXButton", let line = buttonText(element), ScreenSpeakerNames.participantCount(in: [line]) != nil,
                   seen.insert(line).inserted { out.append(line) }
                continue
            }
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

    /// Titles of the app's windows whose front tab is a call: `joined`, a
    /// joined call room (`CallApps.isCallRoom`); `pages`, any call site's
    /// page, which includes a Teams or WhatsApp chat (Codex on #146). A
    /// browser's window title is the page's own ("Owner – Audio playing"), so
    /// its address (AXDocument) says which.
    static func callWindowTitles(pid: pid_t) -> (joined: [String], pages: [String]) {
        guard AXIsProcessTrusted() else { return ([], []) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var joined: [String] = [], pages: [String] = []
        for window in value(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] where isMeeting(window) {
            guard let title = value(window, kAXTitleAttribute) as? String else { continue }
            pages.append(title)
            if isJoinedRoom(window) { joined.append(title) }
        }
        return (joined, pages)
    }

    /// A button's label with the text inside it, such as "People 3".
    private static func buttonText(_ element: AXUIElement) -> String? {
        var parts: [String] = []
        for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = value(element, key) as? String, !text.isEmpty, !parts.contains(text) { parts.append(text) }
        }
        for child in (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(4) {
            if let text = value(child, kAXValueAttribute) as? String ?? value(child, kAXTitleAttribute) as? String, !text.isEmpty,
               !parts.contains(text) {
                parts.append(text)
            }
        }
        let line = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty || line.count > 80 ? nil : line
    }

    /// The window's front tab is a joined call room, by its address, or by its
    /// title only when it has none (`CallApps.isCallRoom`).
    private static func isJoinedRoom(_ window: AXUIElement) -> Bool {
        if let address = value(window, kAXDocumentAttribute) as? String { return CallApps.isCallRoom(addresses: [address]) }
        return (value(window, kAXTitleAttribute) as? String).map { CallApps.isCallRoom(titles: [$0]) } ?? false
    }

    /// The window's front tab is a call page, by its title or address.
    private static func isMeeting(_ window: AXUIElement) -> Bool {
        let strings = [kAXTitleAttribute as String, kAXDocumentAttribute as String].compactMap { value(window, $0) as? String }
        return CallApps.meetingPages.contains { page in strings.contains { $0.localizedCaseInsensitiveContains(page) } }
    }

    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
}
#endif
