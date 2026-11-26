#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// Whether the key events VoiceiQ posts (⌘V, Return, typed text) can land.
///
/// macOS 27.3 split the old Accessibility grant. Accessibility still lets
/// VoiceiQ watch the dictation key and read and set fields, but posting key
/// events needs System & App Protection Override. Without it
/// `AXIsProcessTrusted()` still reads true and `CGEvent.post` drops every
/// event without an error. Below 27.3 the Accessibility grant covers posting.
///
/// `CGPreflightPostEventAccess()` keeps the answer it had at launch, so a
/// grant made while VoiceiQ runs counts only after a restart.
///
/// Adapted from Hex, MIT licence, Copyright (c) 2026 Christopher Langton
/// (github.com/anomalyco/hex `341046f8`, `0744db0d`).
public enum KeystrokeAccess {
    /// What the pill says when a paste was refused for want of the grant.
    public static let refusedNotice =
        "Copied — allow VoiceiQ in System Settings → Privacy & Security → System & App Protection Override"

    /// The Privacy & Security pane the grant lives in. Its anchor keeps the
    /// old name on every version.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// The name of the Privacy & Security list VoiceiQ has to be on to type.
    static func listName(on version: OperatingSystemVersion) -> String {
        if isSplit(on: version) { return "System & App Protection Override" }
        return version.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    static func isSplit(on version: OperatingSystemVersion) -> Bool {
        (version.majorVersion, version.minorVersion) >= (27, 3)
    }

    static func mayPost(on version: OperatingSystemVersion, postEventAccess: Bool) -> Bool {
        !isSplit(on: version) || postEventAccess
    }

    private static var running: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    public static var listName: String { listName(on: running) }

    /// True on 27.3 and later, where posting needs its own grant.
    public static var isSplit: Bool { isSplit(on: running) }

    public static var mayPost: Bool {
        mayPost(on: running, postEventAccess: CGPreflightPostEventAccess())
    }

    /// Everything dictation needs to place text: Accessibility for the key
    /// and the fields, and on 27.3+ the grant to post key events.
    public static var isReady: Bool { AXIsProcessTrusted() && mayPost }

    /// On 27.3+, asks macOS for the posting grant, which lists VoiceiQ under
    /// System & App Protection Override and posts its Privacy & Security
    /// notification. Its answer can read false until VoiceiQ restarts, so it
    /// is only logged.
    public static func requestPostAccess() {
        guard isSplit else { return }
        let granted = CGRequestPostEventAccess()
        Log.permissions.info("asked to post key events (System & App Protection Override): \(granted, privacy: .public)")
    }
}
#endif
