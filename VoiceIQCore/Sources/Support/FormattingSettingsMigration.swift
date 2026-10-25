import CryptoKit
import Foundation

/// Moves the single `smartFormatting` flag onto the two-flag formatting policy
/// introduced with native smart transcription.
///
/// Kept out of `LegacyMigration` on purpose: that file is scoped to the bundle
/// rename and says so. **This must run AFTER it** — `smartFormatting` is in
/// LegacyMigration's key list, so it has to be pulled out of the old defaults
/// domain before this reads it.
public enum FormattingSettingsMigration {
    private static let flag = "didMigrateSmartFormattingKeys"

    public static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flag) else { return }

        let previous = defaults.object(forKey: "smartFormatting") as? Bool
        let trips = (defaults.array(forKey: "gateTrips") as? [Date]) ?? []

        switch previous {
        case nil, .some(true):
            // Never touched it, or explicitly wanted smart output. Either way
            // they wanted formatting — native smart is now how that happens.
            defaults.set(true, forKey: "smartTranscription")
            defaults.set(false, forKey: "smartCleanupPass")
            Log.session.info("formatting migration: \(previous == nil ? "default" : "smart-on", privacy: .public) → native smart")

        case .some(false) where trips.count >= 3:
            // The auto-degrade fingerprint, and the threshold is exact rather
            // than "any trips": the OLD setSmartFormatting only cleared gateTrips
            // when ENABLING, so a user who deliberately chose verbatim keeps
            // whatever trips they had — up to 2, because the 3rd is precisely
            // what triggers auto-degrade. So >=3 means the app turned it off and
            // <=2 means the user did. They were degraded because the cleanup
            // MODEL was unreliable; native smart is a different mechanism
            // entirely and deserves a clean slate.
            defaults.set(true, forKey: "smartTranscription")
            defaults.set(false, forKey: "smartCleanupPass")
            defaults.removeObject(forKey: "gateTrips")
            defaults.set(true, forKey: "shouldAnnounceSmartRestored")
            Log.session.info("formatting migration: auto-degraded user → native smart, trips cleared")

        case .some(false):
            // No trips: a deliberate verbatim user. Never silently turn
            // formatting back on for someone who turned it off.
            defaults.set(false, forKey: "smartTranscription")
            defaults.set(false, forKey: "smartCleanupPass")
            Log.session.info("formatting migration: deliberate verbatim user preserved")
        }

        // Delete rather than leave behind: a downgrade→upgrade would otherwise
        // re-run this against a stale value, and the key would linger as a
        // second source of truth for something it no longer controls.
        defaults.removeObject(forKey: "smartFormatting")
        defaults.set(true, forKey: flag)
    }

    private static let writingRulesFlag = "didEnableWritingRules"

    /// Second one-time step, run AFTER `runIfNeeded`: switch the cleanup pass on
    /// for everyone who has formatting on at all. The pass is now what applies
    /// the user's writing rules (late corrections, grammar-driven sentence
    /// boundaries), so a stored `false` left behind by the first migration
    /// would silently strand them on native smart alone. A deliberate verbatim
    /// user (`smartTranscription == false`) keeps their choice.
    public static func enableWritingRulesIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: writingRulesFlag) else { return }
        defaults.set(true, forKey: writingRulesFlag)

        let verbatim = (defaults.object(forKey: "smartTranscription") as? Bool) == false
        guard !verbatim else {
            Log.session.info("writing rules migration: verbatim user preserved")
            return
        }
        defaults.set(true, forKey: "smartCleanupPass")
        Log.session.info("writing rules migration: cleanup pass enabled")
    }

    private static let undegradeFlag = "didRestoreAutoDegradedWritingRules"

    /// Fourth one-time step: writing rules no longer switch themselves off. The
    /// old auto-degrade turned them off on the third rejected rewrite within
    /// 24 hours and left those three trips in `gateTrips`; a user who turned
    /// them off by hand has fewer. Turn them back on for the first group, then
    /// drop the counter, which nothing reads any more.
    public static func restoreAutoDegradedWritingRulesOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: undegradeFlag) else { return }
        defaults.set(true, forKey: undegradeFlag)
        let trips = (defaults.array(forKey: "gateTrips") as? [Date]) ?? []
        defaults.removeObject(forKey: "gateTrips")
        guard trips.count >= 3, (defaults.object(forKey: "smartCleanupPass") as? Bool) == false else { return }
        defaults.set(true, forKey: "smartCleanupPass")
        Log.session.info("writing rules migration: auto-degraded writing rules turned back on")
    }

    /// Live transcription was removed. Its settings and failure
    /// counters are dropped so nothing stale is left behind.
    public static func removeLiveTranscriptionSettings(defaults: UserDefaults = .standard) {
        let fixed = ["liveTranscription", "didDisableLiveTranscription", "liveModelOverride",
                     "openAILiveModelOverride", "openAILiveDelay", "liveAttempts", "liveSuccesses",
                     "liveConsecutiveFailures", "liveLastFailureAt"]
        let counters = ["neverOpened", "droppedMidSession", "truncated", "noFinal"].map { "liveFallback_\($0)" }
        for key in fixed + counters { defaults.removeObject(forKey: key) }
    }

    private static let splitRulesFlag = "didSplitWritingRules"

    /// Older builds stored the writing rules as one editable text: the
    /// defaults, plus whatever the user added or changed. The defaults are now
    /// built in, so keep only the user's own lines as custom rules. A line of
    /// any earlier default is dropped; every other line stays, including a
    /// default line the user reworded. The edit time moves to the new key so
    /// sync still orders it against other devices.
    public static func splitWritingRulesOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: splitRulesFlag) else { return }
        defaults.set(true, forKey: splitRulesFlag)
        let custom = defaults.string(forKey: "customInstructions").map(customPart) ?? ""
        if !custom.isEmpty {
            defaults.set(custom, forKey: SettingsStore.customWritingRulesKey)
        }
        // A reset to the defaults is an edit too: its time keeps an older
        // copy on another device from bringing the cleared rules back.
        defaults.set(defaults.object(forKey: "customInstructionsUpdatedAt"),
                     forKey: SettingsStore.customWritingRulesUpdatedAtKey)
        defaults.removeObject(forKey: "customInstructions")
        defaults.removeObject(forKey: "customInstructionsUpdatedAt")
        Log.session.info("writing rules migration: kept \(custom.count, privacy: .public) characters of custom rules")
    }

    static func customPart(of full: String) -> String {
        let current = Set(DefaultWritingRules.text.components(separatedBy: .newlines))
        var kept: [String] = []
        for line in full.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if kept.last?.isEmpty == false { kept.append("") }
            } else if !current.contains(trimmed), !pastDefaultLines.contains(lineHash(trimmed)) {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lineHash(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `lineHash` of every non-blank, trimmed line of every earlier default
    /// (`DictationRulesSeed.text` from e2fd238 to 09f3141).
    private static let pastDefaultLines: Set<String> = [
        "022ff7fe4e3c190f", "0c35f2dd0533c246", "0cda31e5aad7fdc6", "0e23d88f5cea6a7b",
        "140b96e3be8e5159", "20c7572d8cf59add", "2983f0e5b3cea197", "2a14c0184b456ba2",
        "32fa35ac1007df61", "40a4c35b8781e7e4", "410f4df6aa1362d6", "42b8ee5afe8f5f8b",
        "58ab57c04be56431", "5dee554abc0951b3", "6bc922d13dad2071", "6d4efff3faa50d66",
        "6e2bb16e5a7f3415", "73687f8a983c82a5", "74db839f037e5955", "786795efb9cec886",
        "7f8358811476ff17", "87295acea69c5fca", "88bf17416406f787", "89d5c786b2b24a0b",
        "8daa9391372cc664", "9467d20e73b71f3e", "9dbd36133d946ead", "a76a361a2a9dbb16",
        "a8aa38a25c8fec97", "ae79efe5a3538b9c", "b115fa16b8828d70", "ba633a17a2382090",
        "bb299fdfc81d1ab1", "d4de3aa6b272de2a", "d6b8d3c9eefa34e8", "dcaf0513b5d093c3",
        "e41b2970369d6a50", "e731fd6ea0a4d491", "e7a5c5dcba92c26d", "e8e7deb6dd0be7b0",
        "eedee77257e33fde", "f5baa6505dc50519",
    ]
}
