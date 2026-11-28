import Foundation

/// iCloud sync of meetings, dictations, the Dictionary, writing rules and
/// meeting folders, for test runs on a signed build: with the
/// `DebugDisableCloudSync` default set
/// (`defaults write io.blue.voiceiq DebugDisableCloudSync -bool true`), none of
/// them starts. MEASURED 2026-11-28: a gate run launched the signed app with
/// a redesign worker's seed data in the data folder, and the probe meetings
/// of that day went to the owner's iCloud too.
public enum CloudSync {
    public static let disabledKey = "DebugDisableCloudSync"

    /// Read once, at launch; changing the default takes a restart.
    nonisolated(unsafe) public internal(set) static var isDisabledForTests: Bool = {
        let off = UserDefaults.standard.bool(forKey: disabledKey)
        if off { Log.session.notice("iCloud sync off: \(disabledKey, privacy: .public) is set, nothing syncs") }
        return off
    }()
}
