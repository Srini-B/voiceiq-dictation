import Foundation

/// URLs the keyboard uses to open the app.
public enum BridgeURL {
    public static let scheme = "voiceiq"

    /// Opened when the app has no live session: the app acts on command `id`
    /// (already in `SharedStore`), then sends the user back to `host`.
    public static func start(commandID: UUID, host: String?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "keyboard"
        components.path = "/start"
        var items = [URLQueryItem(name: "cmd", value: commandID.uuidString)]
        if let host, !host.isEmpty { items.append(URLQueryItem(name: "host", value: host)) }
        components.queryItems = items
        return components.url!
    }

    /// Brings the app forward with nothing to do, so a suspended dictation
    /// resumes. `parse` ignores it.
    public static let app = URL(string: "voiceiq://keyboard/open")!

    /// Opens the app's keyboard setup screen (Full Access missing).
    public static let setup = URL(string: "voiceiq://keyboard/setup")!

    public enum Route: Equatable {
        case start(commandID: UUID, host: String?)
        case setup
    }

    public static func parse(_ url: URL) -> Route? {
        guard url.scheme == scheme, url.host == "keyboard",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        switch url.path {
        case "/start":
            guard let raw = items.first(where: { $0.name == "cmd" })?.value,
                  let id = UUID(uuidString: raw) else { return nil }
            return .start(commandID: id, host: items.first(where: { $0.name == "host" })?.value)
        case "/setup":
            return .setup
        default:
            return nil
        }
    }
}
