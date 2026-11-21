import Foundation
import VoiceIQBridge

/// Settings › Typing in the VoiceiQ app, written where Hex's keyboard reads its
/// own switches (`FullKeyboardSettings`, the same App Group).
@MainActor
enum HexKeyboardSettings {
    /// The last Reset Keyboard Learning request applied.
    static let appliedResetKey = "voiceiq.learningResetApplied"

    static func apply(_ preferences: KeyboardPreferences, defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        let settings = FullKeyboardSettings(defaults: defaults)
        settings.autocorrect = preferences.autocorrect
        settings.autoCapitalization = preferences.autocapitalize
        settings.swipeTyping = preferences.slideToType
        // The emoji key opens VoiceiQ's emoji panel; Hex's strip offers the
        // emoji for a word just typed.
        settings.emoji = true
        settings.hexKeyOnLeft = false
        // Reset Keyboard Learning: the words Hex kept, as Hex's own Delete what
        // Hex learned does. Each reset is applied once; it is stamped with the
        // time it is applied, so words a keyboard loaded after the user asked
        // (and before this ran) are dropped from memory too.
        if let reset = preferences.learningResetAt?.timeIntervalSince1970,
           reset > defaults?.double(forKey: appliedResetKey) ?? 0 {
            defaults?.set(reset, forKey: appliedResetKey)
            TypingJournalSettings(defaults: defaults).erasedAt = Date().timeIntervalSince1970
            defaults?.removeObject(forKey: LearnedWordsStore.defaultsKey)
        }
    }
}
