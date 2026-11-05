import UIKit
import VoiceIQBridge
import VoiceIQCore

/// Sends the user back to the app they were typing in after the one-time
/// bounce, and keeps a record of every app the keyboard was used in, so gaps in
/// the return table are visible and fixable from Settings.
@MainActor
final class HostReturn: ObservableObject {
    enum Outcome: String, Codable {
        /// Brought the app back, by bundle ID or its return URL.
        case returned
        /// Had a URL, but iOS would not open it.
        case openFailed
        /// No URL known for this app. A gap in the table.
        case noScheme
        /// The app is known to have no way back (Safari, Spotlight).
        case noWayBack
        /// Dictated without leaving the app. No return needed.
        case inPlace

        var label: String {
            switch self {
            case .returned: return "Returns automatically"
            case .openFailed: return "Return failed"
            case .noScheme: return "No return link"
            case .noWayBack: return "Swipe back"
            case .inPlace: return "Used in place"
            }
        }
    }

    struct Record: Codable, Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        var uses: Int
        var lastUsed: Date
        /// The outcome of the last bounce. `inPlace` never overwrites it.
        var lastReturn: Outcome?
    }

    @Published private(set) var records: [Record] = []
    @Published private(set) var overrides: [String: String] = [:]

    private static let recordsKey = "hostReturn.records"
    private static let overridesKey = "hostReturn.overrides"
    /// How long to wait for the recording to start before leaving the app.
    /// Leaving earlier than the engine start risks iOS refusing the mic.
    static let recordingWaitCeiling: TimeInterval = 0.6

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.recordsKey),
           let decoded = try? JSONDecoder().decode([Record].self, from: data) {
            records = decoded
        }
        overrides = defaults.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
    }

    static let ownBundleID = Bundle.main.bundleIdentifier ?? "io.blue.voiceiq.ios"

    func returnURL(for host: String) -> URL? {
        KnownAppSchemes.returnURL(forHostId: host, overrides: overrides)
    }

    /// Hosts that are not apps the user can be sent back to: system UI and
    /// extensions. They keep the swipe-back screen.
    static let notLaunchable: Set<String> = [
        ownBundleID,
        "com.apple.springboard",
        "com.apple.Spotlight",
        "com.apple.SafariViewService",
        "com.apple.ShortcutsUI",
        "com.apple.mobilesms.compose",
        "com.apple.AppleMediaServicesUI.ComposeReviewExtension",
    ]
    /// How long to wait for iOS to switch apps after a launch before
    /// treating it as failed and trying the URL.
    static let launchCheckDelay: TimeInterval = 1.0

    /// Sends the user back to `host` once `isRecording` says the mic is live
    /// (or the ceiling passes). Tries, in order: bringing the app to the front
    /// by bundle ID (resumes it where it was, works for any app), then its
    /// return URL. Calls `completion(false)` when the user has to swipe back.
    func returnToHost(_ host: String?, isRecording: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard let host, host != Self.ownBundleID else {
            completion(host == Self.ownBundleID)
            return
        }
        AppNames.lookUpIfNeeded(host)
        let url = returnURL(for: host)
        let launchable = !Self.notLaunchable.contains(host)
        guard launchable || url != nil else {
            note(host: host, outcome: KnownAppSchemes.knownNoSchemeHosts.contains(host) ? .noWayBack : .noScheme)
            completion(false)
            return
        }
        let deadline = Date().addingTimeInterval(Self.recordingWaitCeiling)
        func attempt() {
            guard isRecording() || Date() >= deadline else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { attempt() }
                return
            }
            guard launchable else {
                openURL(url, host: host, completion: completion)
                return
            }
            launch(host) { [weak self] launched in
                if launched {
                    self?.note(host: host, outcome: .returned)
                    completion(true)
                } else {
                    self?.openURL(url, host: host, completion: completion)
                }
            }
        }
        attempt()
    }

    /// Brings the host to the front and confirms that VoiceiQ actually left
    /// the foreground; the private call can report success and do nothing.
    private func launch(_ host: String, completion: @escaping (Bool) -> Void) {
        guard AppLauncher.open(bundleID: host) else {
            SessionDiagnostics.note("return to \(host): launch refused")
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchCheckDelay) {
            let left = UIApplication.shared.applicationState != .active
            SessionDiagnostics.note("return to \(host): \(left ? "launched" : "launch did not leave the app")")
            completion(left)
        }
    }

    private func openURL(_ url: URL?, host: String, completion: @escaping (Bool) -> Void) {
        guard let url else {
            note(host: host, outcome: KnownAppSchemes.knownNoSchemeHosts.contains(host) ? .noWayBack : .noScheme)
            completion(false)
            return
        }
        // A universal link must open the app or fail: in Safari it would
        // count as a return while leaving the user's draft behind.
        let web = url.scheme == "https" || url.scheme == "http"
        UIApplication.shared.open(url, options: web ? [.universalLinksOnly: true] : [:]) { [weak self] opened in
            self?.note(host: host, outcome: opened ? .returned : .openFailed)
            SessionDiagnostics.note("return to \(host): url \(opened ? "opened" : "failed")")
            completion(opened)
        }
    }

    func note(host: String, outcome: Outcome) {
        guard host != Self.ownBundleID else { return }
        if let index = records.firstIndex(where: { $0.bundleID == host }) {
            records[index].uses += 1
            records[index].lastUsed = Date()
            if outcome != .inPlace { records[index].lastReturn = outcome }
        } else {
            records.append(Record(bundleID: host, uses: 1, lastUsed: Date(), lastReturn: outcome == .inPlace ? nil : outcome))
        }
        records.sort { $0.lastUsed > $1.lastUsed }
        save()
    }

    /// A user-supplied return URL for an app the table does not know.
    func setOverride(_ raw: String?, for host: String) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        overrides[host] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(overrides, forKey: Self.overridesKey)
    }

    func forget(_ host: String) {
        records.removeAll { $0.bundleID == host }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.recordsKey)
        }
    }
}
