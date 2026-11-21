import SwiftUI
import VoiceIQBridge

/// The keyboard's typing settings, written to the App Group for the keyboard.
struct TypingSettingsView: View {
    @State private var preferences = SharedStore.shared.keyboardPreferences
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Auto-Correction", isOn: $preferences.autocorrect)
                Toggle("Auto-Capitalization", isOn: $preferences.autocapitalize)
                Toggle("Slide to Type", isOn: $preferences.slideToType)
            } footer: {
                Text("Keys, suggestions, autocorrect and Slide to Type come from [Hex](https://github.com/anomalyco/hex) (MIT). Its typing model is built from the [Google Books Ngram](https://storage.googleapis.com/books/ngrams/books/datasetsv3.html) data (CC BY 3.0).")
            }
            Section {
                Button("Reset Keyboard Learning", role: .destructive) { confirmReset = true }
            }
        }
        .onChange(of: preferences) { _, value in
            SharedStore.shared.keyboardPreferences = value
        }
        .confirmationDialog("Forget the words the keyboard has learned?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Keyboard Learning", role: .destructive) { preferences.learningResetAt = Date() }
        }
        .settingsPage(title: "Typing")
    }
}
