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
                Picker("Height", selection: $preferences.height) {
                    ForEach(KeyboardHeight.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Number Row", isOn: $preferences.numberRow)
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
                Toggle("Emoji Suggestions", isOn: $preferences.emojiSuggestions)
                Toggle("Slide to Type", isOn: $preferences.slideToType)
                Toggle("“.” Shortcut", isOn: $preferences.periodShortcut)
            } footer: {
                // Required by the FUTO Model Weights License.
                Text("Slide to Type is powered by FUTO Swipe.")
            }
            Section {
                Picker("Space Bar Slide", selection: $preferences.spaceSlide) {
                    ForEach(KeyboardSpaceSlide.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Delete Slide", selection: $preferences.deleteSlide) {
                    ForEach(KeyboardDeleteSlide.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                NavigationLink {
                    BlockedWordsView(words: $preferences.blockedWords)
                } label: {
                    LabeledContent("Blocked Words", value: preferences.blockedWords.isEmpty ? "None" : "\(preferences.blockedWords.count)")
                }
                Button("Reset Keyboard Learning", role: .destructive) { confirmReset = true }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            KeyboardPreview(preferences: preferences)
                .animation(.easeInOut(duration: 0.2), value: preferences)
        }
        .onChange(of: preferences) { _, value in SharedStore.shared.keyboardPreferences = value }
        .confirmationDialog("Forget the words the keyboard has learned?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Keyboard Learning", role: .destructive) { preferences.learningResetAt = Date() }
        }
        .settingsPage(title: "Typing")
    }
}

/// Words the keyboard never suggests, corrects to or slides to. Holding a
/// suggestion on the keyboard adds one here.
private struct BlockedWordsView: View {
    @Binding var words: [String]
    @State private var draft = ""

    var body: some View {
        Form {
            Section {
                TextField("Add Word", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
            }
            Section {
                ForEach(words, id: \.self) { Text($0) }
                    .onDelete { words.remove(atOffsets: $0) }
            }
        }
        .settingsPage(title: "Blocked Words", keyboard: true)
    }

    /// Stored as the keyboard matches them: lowercase, no apostrophes.
    private func add() {
        let key = draft.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        if !key.isEmpty, !words.contains(key) { words.insert(key, at: 0) }
        draft = ""
    }
}
