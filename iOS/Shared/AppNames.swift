import Foundation
import VoiceIQCore

/// Readable names for the bundle IDs the keyboard reports. iOS gives an app
/// no way to read another app's name, so common ones are listed and the rest
/// are looked up once on the App Store and cached.
enum AppNames {
    private static let known: [String: String] = [
        "com.apple.mobilenotes": "Notes",
        "com.apple.MobileSMS": "Messages",
        "com.apple.mobilemail": "Mail",
        "com.apple.mobilesafari": "Safari",
        "com.apple.SafariViewService": "Safari",
        "com.apple.reminders": "Reminders",
        "com.apple.Spotlight": "Spotlight",
        "com.apple.Pages": "Pages",
        "com.apple.journal": "Journal",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.tinyspeck.chatlyio": "Slack",
        "com.google.Gmail": "Gmail",
        "com.google.chrome.ios": "Chrome",
        "com.openai.chat": "ChatGPT",
        "com.anthropic.claude": "Claude",
        "com.google.gemini": "Gemini",
        "com.facebook.Messenger": "Messenger",
        "com.burbn.instagram": "Instagram",
        "com.atebits.Tweetie2": "X",
        "com.hammerandchisel.discord": "Discord",
        "org.whispersystems.signal": "Signal",
        "com.telegram.telegram-ios": "Telegram",
        "ph.telegra.Telegraph": "Telegram",
        "notion.id": "Notion",
        "com.linear.ios": "Linear",
        "com.microsoft.Office.Outlook": "Outlook",
        "com.microsoft.skype.teams": "Teams",
        "md.obsidian": "Obsidian",
    ]

    /// Last segments that say nothing about the app ("com.acme.notes.ios").
    private static let genericSegments: Set<String> = [
        "ios", "iphone", "ipad", "app", "apps", "mobile", "client", "prod", "production", "release",
    ]
    private static let lookupKey = "appNames.lookedUp"
    @MainActor private static var lookupsInFlight: Set<String> = []

    static func displayName(for bundleID: String) -> String {
        if let name = known[bundleID] { return name }
        // Our own Try field: the last segment would read "Ios".
        if bundleID == Bundle.main.bundleIdentifier { return "VoiceiQ" }
        if let name = lookedUp[bundleID] { return name }
        return guess(from: bundleID)
    }

    /// The name for a History row: from the bundle ID when there is one, so
    /// names looked up later replace the guess saved with the record.
    static func name(for record: DictationRecord) -> String? {
        record.targetAppBundleID.map(displayName(for:)) ?? record.targetAppName
    }

    /// The last meaningful segment, capitalized: `com.acme.Notes.ios` → "Notes".
    static func guess(from bundleID: String) -> String {
        let segments = bundleID.split(separator: ".").map(String.init)
        let meaningful = segments.dropFirst().last { !genericSegments.contains($0.lowercased()) }
        let name = meaningful ?? segments.last ?? bundleID
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Looks the app up on the App Store (iTunes Search API) once and caches
    /// its name. Only the bundle ID is sent. Apple and system apps are skipped.
    @MainActor
    static func lookUpIfNeeded(_ bundleID: String) {
        guard known[bundleID] == nil, lookedUp[bundleID] == nil,
              bundleID != Bundle.main.bundleIdentifier, !bundleID.hasPrefix("com.apple."),
              !lookupsInFlight.contains(bundleID) else { return }
        lookupsInFlight.insert(bundleID)
        Task {
            let region = Locale.current.region?.identifier.lowercased() ?? "us"
            var name = await storeName(bundleID, country: region)
            if name == nil, region != "us" { name = await storeName(bundleID, country: "us") }
            lookupsInFlight.remove(bundleID)
            guard let name else { return }
            var names = lookedUp
            names[bundleID] = name
            UserDefaults.standard.set(names, forKey: lookupKey)
        }
    }

    private static var lookedUp: [String: String] {
        UserDefaults.standard.dictionary(forKey: lookupKey) as? [String: String] ?? [:]
    }

    private struct LookupResponse: Decodable {
        struct Result: Decodable { let trackName: String }
        let results: [Result]
    }

    private static func storeName(_ bundleID: String, country: String) async -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "software"),
        ]
        guard let url = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(LookupResponse.self, from: data),
              let name = response.results.first?.trackName else { return nil }
        return shortName(name)
    }

    /// Store titles often carry a tagline: "Todoist: To-Do List & Planner" → "Todoist".
    static func shortName(_ title: String) -> String {
        for separator in [":", " - ", " – ", " — ", " | "] {
            if let range = title.range(of: separator) {
                let head = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                if !head.isEmpty { return head }
            }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }
}
