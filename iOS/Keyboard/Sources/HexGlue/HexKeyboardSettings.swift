import Foundation
import VoiceIQBridge

/// Settings › Typing in the VoiceiQ app, written where Hex's keyboard reads its
/// own switches (`FullKeyboardSettings`, the same App Group).
@MainActor
enum HexKeyboardSettings {
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
        // Hex learned does.
        if let reset = preferences.learningResetAt?.timeIntervalSince1970 {
            let journal = TypingJournalSettings(defaults: defaults)
            if reset > journal.erasedAt {
                journal.erasedAt = reset
                defaults?.removeObject(forKey: LearnedWordsStore.defaultsKey)
            }
        }
    }
}
