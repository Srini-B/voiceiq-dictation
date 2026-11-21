import Foundation
import os

/// Process-wide "a Settings row is recording a shortcut" flag.
///
/// Both event taps read it on every key event and pass the event through
/// while it is set, so pressing the dictation key or Option-M to record it
/// reaches the Settings window's local monitor instead of starting a session.
/// One owner at a time: beginning a capture posts
/// `voiceIQShortcutCaptureDidBegin` so any other row still listening stops.
public enum ShortcutCapture {
    private static let owner = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    public static var isActive: Bool {
        owner.withLock { $0 != nil }
    }

    public static func begin(owner id: UUID) {
        owner.withLock { $0 = id }
        NotificationCenter.default.post(name: .voiceIQShortcutCaptureDidBegin, object: id)
    }

    /// Clears the flag only if `id` still owns it, so a row that lost the
    /// capture to another row cannot end that row's capture on disappear.
    public static func end(owner id: UUID) {
        owner.withLock { if $0 == id { $0 = nil } }
    }
}

public extension Notification.Name {
    static let voiceIQShortcutCaptureDidBegin = Notification.Name("io.blue.voiceiq.shortcutCaptureDidBegin")
}
