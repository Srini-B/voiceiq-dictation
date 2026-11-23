import Foundation

/// Where a Chromium browser has the VoiceiQ Meetings extension, read from
/// each profile's own record of its extensions. The files VoiceiQ copies
/// out say nothing about this: removing the extension in Chrome leaves them.
public struct BrowserExtensionInstall: Equatable, Sendable {
    /// The browser's folder under Application Support, such as "Google/Chrome".
    public var browser: String
    /// The profile's folder, such as "Profile 4".
    public var profile: String
    /// The name the browser shows for the profile, when it has one.
    public var profileName: String?
    /// Off in the browser's Extensions page, or turned off by the browser.
    public var enabled: Bool
}

public enum BrowserExtensionInstalls {
    /// Chromium browsers keep their profiles under these folders in
    /// Application Support; each also reads native messaging hosts from there.
    public static let browserFolders = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Google/Chrome for Testing", "Google/ChromeForTesting",
        "Chromium", "Microsoft Edge", "BraveSoftware/Brave-Browser", "Arc/User Data", "Vivaldi",
    ]

    /// Every profile of every browser that lists extension `id`. Chrome
    /// writes an unpacked extension to the profile's Secure Preferences and
    /// other installs to Preferences. Removing it drops the entry from the
    /// one and can leave it empty in the other (MEASURED 2026-11-23, Chrome
    /// 157: `{}` stayed in Preferences), so an entry counts only with the
    /// install's `location`. Profiles are the folders holding either file:
    /// "Default", "Profile 4" and so on.
    public static func find(id: String, support: URL, browsers: [String] = browserFolders) -> [BrowserExtensionInstall] {
        let fm = FileManager.default
        var out: [BrowserExtensionInstall] = []
        for browser in browsers {
            let root = support.appendingPathComponent(browser, isDirectory: true)
            guard let profiles = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            let names = profileNames(localState: root.appendingPathComponent("Local State"))
            for profile in profiles.sorted() {
                let folder = root.appendingPathComponent(profile, isDirectory: true)
                let entries = ["Secure Preferences", "Preferences"].compactMap { file -> [String: Any]? in
                    let settings = json(folder.appendingPathComponent(file))?["extensions"] as? [String: Any]
                    let entry = (settings?["settings"] as? [String: Any])?[id] as? [String: Any]
                    return entry?["location"] != nil ? entry : nil
                }
                guard !entries.isEmpty else { continue }
                out.append(BrowserExtensionInstall(browser: browser, profile: profile, profileName: names[profile],
                                                   enabled: entries.allSatisfy(isEnabled)))
            }
        }
        return out
    }

    /// Chrome lists why an extension is off in `disable_reasons`: a list in
    /// current versions, a bit mask in older ones. Older versions also wrote
    /// `state`, 0 for off.
    static func isEnabled(_ entry: [String: Any]) -> Bool {
        if let reasons = entry["disable_reasons"] as? [Any], !reasons.isEmpty { return false }
        if let mask = entry["disable_reasons"] as? Int, mask != 0 { return false }
        if let state = entry["state"] as? Int, state == 0 { return false }
        return true
    }

    private static func profileNames(localState: URL) -> [String: String] {
        let cache = (json(localState)?["profile"] as? [String: Any])?["info_cache"] as? [String: Any] ?? [:]
        return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
