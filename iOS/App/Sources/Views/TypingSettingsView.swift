import SwiftUI
import VoiceIQBridge

/// The keyboard's typing settings, written to the App Group for the keyboard.
struct TypingSettingsView: View {
    @State private var preferences = SharedStore.shared.keyboardPreferences
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker("Layout", selection: $preferences.layout) {
                    ForEach(KeyboardLetterLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(KeyboardTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if preferences.theme.hasKeyTone {
                    Picker("Keys", selection: $preferences.keyTone) {
                        ForEach(KeyboardKeyTone.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            Section {
                Toggle("Predictions", isOn: $preferences.predictions)
                Toggle("Auto-Correction", isOn: $preferences.autocorrect)
                Toggle("Auto-Capitalization", isOn: $preferences.autocapitalize)
                Toggle("Slide to Type", isOn: $preferences.slideToType)
                Toggle("“.” Shortcut", isOn: $preferences.periodShortcut)
            }
            Section {
                Toggle("Key Sound", isOn: $preferences.keySound)
                Toggle("Haptic Feedback", isOn: $preferences.haptics)
            }
            Section {
                Button("Reset Keyboard Learning", role: .destructive) { confirmReset = true }
            }
        }
        .onChange(of: preferences) { _, value in SharedStore.shared.keyboardPreferences = value }
        .confirmationDialog("Forget the words the keyboard has learned?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Keyboard Learning", role: .destructive) { preferences.learningResetAt = Date() }
        }
        .settingsPage(title: "Typing")
    }
}
