import Foundation
import Security

/// One-shot migration from the app's pre-rename identity ("Google Transcribe",
/// bundle id com.google.transcribe). This file is the ONLY place the legacy
/// identifiers may appear — everything a user accumulated (API key, settings,
/// dictionary, History) must survive the rename invisibly.
///
/// macOS permissions (mic, Accessibility) are keyed by bundle id and CANNOT be
/// migrated — onboarding re-collects them on first launch as VoiceiQ.
public enum LegacyMigration {
    private static let legacyBundleID = "com.google.transcribe"
    private static let legacyKeychainService = "com.google.transcribe"
    private static let legacyAppSupportFolder = "Google Transcribe"
    private static let migratedFlag = "didMigrateFromGoogleTranscribe"

    public static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlag) else { return }

        migrateAppSupportFolder()
        migrateDefaultsDomain()
        migrateKeychainKey()

        defaults.set(true, forKey: migratedFlag)
        Log.session.info("LegacyMigration: completed (folder, defaults, keychain)")
    }

    /// recordings/ + history.sqlite move wholesale; FileLayout resolves the NEW
    /// folder name, so this must run before anything touches the store.
    private static func migrateAppSupportFolder() {
        let fm = FileManager.default
        // A test copy's folder never takes the real app's old one.
        guard FileLayout.testDataFolder == nil, let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = base.appendingPathComponent(legacyAppSupportFolder, isDirectory: true)
        let new = FileLayout.appSupportRoot
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
            Log.session.info("LegacyMigration: moved Application Support folder")
        } catch {
            Log.session.error("LegacyMigration: folder move failed: \(error)")
        }
    }

    /// Settings + dictionary lived in the old bundle id's defaults domain.
    private static func migrateDefaultsDomain() {
        let keys = [
            "smartFormatting", "showIdleIndicator", "soundsEnabled",
            "hotkeyKey",
            "audioRetentionDays", "gateTrips", "dictionaryEntries", "hasCompletedOnboarding",
            "experimentalNoiseHandling", "smartTranscription", "smartCleanupPass",
            "shouldAnnounceSmartRestored",
        ]
        guard let old = UserDefaults(suiteName: legacyBundleID) else { return }
        let defaults = UserDefaults.standard
        var moved = 0
        for key in keys {
            if defaults.object(forKey: key) == nil, let value = old.object(forKey: key) {
                defaults.set(value, forKey: key)
                moved += 1
            }
        }
        // No traces: drop the old domain entirely.
        defaults.removePersistentDomain(forName: legacyBundleID)
        if moved > 0 {
            Log.session.info("LegacyMigration: moved \(moved) defaults key(s)")
        }
    }

    /// The old app's key was a Gemini key, which AssemblyAI can't use, so
    /// it is deleted rather than re-homed.
    private static func migrateKeychainKey() {
        deleteLegacyKey()
    }

    private static func deleteLegacyKey() {
        for dataProtection in [true, false] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyKeychainService,
                kSecAttrAccount as String: "gemini-api-key",
            ]
            if dataProtection {
                query[kSecUseDataProtectionKeychain as String] = true
            }
            SecItemDelete(query as CFDictionary)
        }
    }
}
