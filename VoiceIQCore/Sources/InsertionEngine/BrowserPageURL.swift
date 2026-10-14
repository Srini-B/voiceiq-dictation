#if os(macOS)
import ApplicationServices
import Foundation

/// The page a browser's focused window shows, for the writing model's PLACE
/// line. A Gmail compose box, a GitHub review, and a Google Doc each want a
/// different shape of text, and the window title alone often does not say
/// which site it is. Only http(s) pages count, and only the host and path:
/// the query and fragment can hold tokens and search terms.
public enum BrowserPageURL {
    /// Apps whose windows are read. Anything else is skipped, so no tree
    /// walk runs in an app that has no page.
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.operasoftware.Opera",
        "org.mozilla.firefox", "app.zen-browser.zen",
    ]

    /// Host and path of the focused window's page, or nil when the app is
    /// not a browser, the page is not http(s), or the tree does not say.
    /// The address bar is read first: it is a plain text field in the
    /// window's own tree, present whether or not the browser has built the
    /// page's accessibility tree (Safari builds it lazily on the first
    /// query after a load, and Chrome drops it when no assistive client is
    /// active, measured 2026-10-13). The web area's URL is the fallback.
    /// Each call has a 0.25 s timeout, so a stalled app costs at most a few
    /// seconds on the background thread this runs on.
    public nonisolated static func capture(pid: pid_t, bundleID: String?) -> String? {
        guard let bundleID, browsers.contains(bundleID) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(windowRef as AnyObject, to: AXUIElement.self)
        if let url = urlAttribute(of: window, kAXDocumentAttribute), let form = displayForm(of: url) { return form }
        return pageURL(under: window)
    }

    /// `host/path` for an http(s) URL, no scheme, query, or fragment, capped
    /// so a long path cannot bloat the prompt.
    static func displayForm(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        var path = url.path
        if path == "/" { path = "" }
        return String((host + path).prefix(120))
    }

    /// The address bar's text as a page, or nil. Chrome shows it without a
    /// scheme ("github.com/org/repo"), so one is added; a search typed
    /// into the bar ("cats") has no dotted host and is dropped.
    static func displayForm(ofAddressBar text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let host = url.host,
              host.contains(".") || host == "localhost" else { return nil }
        return displayForm(of: url)
    }

    private nonisolated static func urlAttribute(of element: AXUIElement, _ attribute: String) -> URL? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success, let ref else { return nil }
        if CFGetTypeID(ref) == CFURLGetTypeID() { return ref as? URL }
        if let string = ref as? String { return URL(string: string) }
        return nil
    }

    private nonisolated static func stringAttribute(of element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Whether a text field is the browser's address bar. Safari names it
    /// `WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD`; Chrome and its forks describe
    /// it as "Address and search bar"; Firefox as "Search or enter address".
    private nonisolated static func isAddressBar(_ element: AXUIElement) -> Bool {
        if let identifier = stringAttribute(of: element, kAXIdentifierAttribute),
           identifier.localizedCaseInsensitiveContains("address") { return true }
        if let description = stringAttribute(of: element, kAXDescriptionAttribute),
           description.localizedCaseInsensitiveContains("address") { return true }
        return false
    }

    /// Breadth-first, so the toolbar's address bar and the web area (both
    /// a few levels under the window) are found before the walk reaches
    /// the page's own deep tree. Bounded by depth and by nodes visited.
    private nonisolated static func pageURL(under window: AXUIElement) -> String? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.25)
            let role = stringAttribute(of: element, kAXRoleAttribute)
            if role == "AXTextField", isAddressBar(element),
               let value = stringAttribute(of: element, kAXValueAttribute),
               let form = displayForm(ofAddressBar: value) {
                return form
            }
            if role == "AXWebArea" {
                let url = urlAttribute(of: element, kAXURLAttribute) ?? urlAttribute(of: element, kAXDocumentAttribute)
                if let form = url.flatMap(displayForm(of:)) { return form }
                continue
            }
            guard depth < 12 else { continue }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }
            for child in children { queue.append((child, depth + 1)) }
        }
        return nil
    }
}
#endif
