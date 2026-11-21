import Foundation

/// Hex's Settings › Keyboard › Languages, fixed for VoiceiQ: English on the QWERTY
/// layout only. With one language the space bar never switches language and
/// autocorrect has no bilingual partner, and only the English model and emoji
/// index are bundled (iOS/Keyboard/Hex/MANIFEST).
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
