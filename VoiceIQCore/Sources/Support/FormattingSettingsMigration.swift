import CryptoKit
import Foundation

/// One-time settings moves for the writing rules and retired features. The
/// formatting-flag migrations that used to live here were deleted in 0.7.12,
/// when the writing rules became permanent (`SettingsStore.retiredKeys`).
public enum FormattingSettingsMigration {
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
        var kept: [String] = []
        for line in full.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if kept.last?.isEmpty == false { kept.append("") }
            } else if !pastDefaultLines.contains(lineHash(trimmed)) {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lineHash(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `lineHash` of every non-blank, trimmed line of every earlier default
    /// (`DictationRulesSeed.text` from e2fd238 to 09f3141, then `DefaultWritingRules.text`
    /// until its rules moved into `PromptV1.rules`).
    private static let pastDefaultLines: Set<String> = [
        "022ff7fe4e3c190f", "0c35f2dd0533c246", "0cda31e5aad7fdc6", "0e23d88f5cea6a7b",
        "140b96e3be8e5159", "20c7572d8cf59add", "2983f0e5b3cea197", "2a14c0184b456ba2",
        "32fa35ac1007df61", "40a4c35b8781e7e4", "410f4df6aa1362d6", "42b8ee5afe8f5f8b",
        "51baaaf8d0189d13", "58ab57c04be56431", "595ba816f19e9754", "5dee554abc0951b3",
        "6bc922d13dad2071", "6d4efff3faa50d66", "6e2bb16e5a7f3415", "73687f8a983c82a5",
        "74db839f037e5955", "786795efb9cec886", "7f8358811476ff17", "87295acea69c5fca",
        "88bf17416406f787", "89d5c786b2b24a0b", "8daa9391372cc664", "9467d20e73b71f3e",
        "9715d8cae03c1ee1", "9dbd36133d946ead", "a0734cd1804fa966", "a5f62d19e2e9d2c2",
        "a76a361a2a9dbb16", "a8aa38a25c8fec97", "ab07cb14e77ab062", "ae79efe5a3538b9c",
        "b115fa16b8828d70", "ba633a17a2382090", "bb299fdfc81d1ab1", "d4de3aa6b272de2a",
        "d6b8d3c9eefa34e8", "dcaf0513b5d093c3", "e41b2970369d6a50", "e435c23ec39c1d3d",
        "e731fd6ea0a4d491", "e7a5c5dcba92c26d", "e8e7deb6dd0be7b0", "eedee77257e33fde",
        "f5baa6505dc50519",
    ]
}
