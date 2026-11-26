import Foundation

/// Fixes Hex's language selection to English QWERTY for VoiceiQ's keyboard.
struct LanguageSettings {
    var keyboardLanguages: [KeyboardLanguage] { [.english] }
    var currentKeyboardLanguage: KeyboardLanguage? {
        get { .english }
        nonmutating set {}
    }
    var effectiveDictationLanguage: String? { "en" }
    var dictationLanguage: String? { nil }
    var dictationFollowsKeyboard: Bool { false }

    func letterLayout(for language: KeyboardLanguage) -> KeyboardLetterLayout { .qwerty }
}
