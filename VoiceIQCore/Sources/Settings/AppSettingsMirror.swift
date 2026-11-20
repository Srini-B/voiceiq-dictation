#if os(iOS)
import Foundation
import VoiceIQBridge

/// The app's settings, readable in the iPhone keyboard.
///
/// `SettingsStore`, `DictionaryStore` and the writing rules keep their values
/// in the app's standard defaults, which the keyboard cannot read. The app
/// publishes that domain to the App Group (writer: app), and the keyboard
/// installs it as its registration domain before each dictation, so the same
/// `SettingsStore` code reads the app's values unchanged.
public enum AppSettingsMirror {
    private static let key = "bridge.appSettings"
    private static var group: UserDefaults? { UserDefaults(suiteName: SharedStore.appGroupID) }

    /// App: copies its settings to the App Group when they changed.
    public static func publish() {
        guard let id = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: id),
              let data = try? PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0),
              group?.data(forKey: key) != data else { return }
        group?.set(data, forKey: key)
    }

    /// Keyboard: makes the app's settings the values `UserDefaults.standard`
    /// returns. False when the app has not published them yet.
    @discardableResult
    public static func apply() -> Bool {
        guard let data = group?.data(forKey: key),
              let domain = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        let defaults = UserDefaults.standard
        // A value the keyboard's own domain holds for an app key would hide
        // the app's.
        if let id = Bundle.main.bundleIdentifier, let own = defaults.persistentDomain(forName: id) {
            for key in domain.keys where own[key] != nil { defaults.removeObject(forKey: key) }
        }
        defaults.setVolatileDomain(domain, forName: UserDefaults.registrationDomain)
        return true
    }
}
#endif
