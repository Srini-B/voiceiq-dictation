import SwiftUI
import VoiceIQBridge

/// The keyboard's typing switches, in Keyboard & Permissions. The keyboard (Hex's,
/// `iOS/Keyboard/Hex/FullKeyboard/FullKeyboardSettings.swift`) reads them from the App
/// Group each time it appears, so the keys here are Hex's own.
struct TypingSettingsCard: View {
    private static let defaults = UserDefaults(suiteName: SharedStore.appGroupID)

    @AppStorage("settings.keyboardAutocorrect", store: defaults) private var autocorrect = true
    @AppStorage("settings.keyboardAutoCapitalization", store: defaults) private var autoCapitalization = true
    @AppStorage("experiments.swipeTyping", store: defaults) private var slideToType = true
    @AppStorage("settings.keyboardHaptics", store: defaults) private var haptics = true
    @AppStorage("settings.keyboardNumberRow", store: defaults) private var numberRow = false
    @AppStorage("experiments.typingJournal", store: defaults) private var learns = true
    @State private var confirmErase = false
    @State private var erased = false

    var body: some View {
        Card {
            Toggle("Auto-correction", isOn: $autocorrect)
            Toggle("Auto-capitalization", isOn: $autoCapitalization)
            Toggle("Slide to type", isOn: $slideToType)
            Toggle("Key haptics", isOn: $haptics)
            Toggle("Number row", isOn: $numberRow)
            Divider().overlay(Theme.Colors.hairline)
            Toggle("Learn how I type", isOn: $learns)
            Text("The keyboard learns the words you keep and the fixes you undo, so it corrects you less. It also learns where you tap each key, even with this off. What it learns stays on this \(UIDevice.current.localizedModel) and is never sent anywhere.")
                .font(Theme.Fonts.footnote())
                .foregroundStyle(Theme.Colors.muted)
            Button(erased ? "Erased" : "Erase what it learned", role: .destructive) { confirmErase = true }
                .buttonStyle(.compactSecondary)
                .disabled(erased)
        }
        .font(Theme.Fonts.body())
        .tint(Theme.Colors.accent)
        .confirmationDialog("Erase what the keyboard learned?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) {
                Self.eraseLearning()
                erased = true
            }
        }
    }

    /// What Hex's `TypingJournal.delete` erases: the journal file, its switched-off
    /// fixes and the learned words, plus Adaptive touch's tap averages. `typingJournal.erasedAt` tells a keyboard that is
    /// still running to drop what it holds in memory.
    private static func eraseLearning() {
        guard let defaults else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: "typingJournal.erasedAt")
        defaults.removeObject(forKey: "typingJournal.disabledDictationFixes")
        for key in defaults.dictionaryRepresentation().keys
        where key == "keyboard.learnedWords" || key.hasPrefix("keyboard.learnedWords.") {
            defaults.removeObject(forKey: key)
        }
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) {
            try? FileManager.default.removeItem(at: group.appendingPathComponent("typing-journal.json"))
        }
        resetTouchLearning()
    }

    /// What Hex's `AdaptiveTouchSettings.requestReset` writes: every keyboard holding
    /// older tap averages, in memory or on disk, drops them the next time it reads them.
    private static func resetTouchLearning() {
        guard let defaults else { return }
        let now = Date().timeIntervalSince1970
        defaults.set(max(now, defaults.double(forKey: "adaptiveTouch.resetAt") + 0.001), forKey: "adaptiveTouch.resetAt")
        defaults.removeObject(forKey: "adaptiveTouch.summary.taps")
        defaults.removeObject(forKey: "adaptiveTouch.summary.active")
    }
}
