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
                // Required by the FUTO Model Weights License, and GPL-3.0
                // section 5(d) for the swipe library.
                Text("Slide to Type is powered by FUTO Swipe. © FUTO Holdings, Inc. GPL-3.0, with no warranty. [License](https://www.gnu.org/licenses/gpl-3.0.html) · [Source](https://github.com/Srini-B/voiceiq-dictation)")
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
        .onChange(of: preferences) { _, value in
            // The keyboard blocks words too, so this page's copy of the list
            // may be old; Blocked Words saves its own edits.
            var saved = value
            saved.blockedWords = SharedStore.shared.keyboardPreferences.blockedWords
            SharedStore.shared.keyboardPreferences = saved
        }
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
                    .onDelete { offsets in
                        let removed = offsets.map { words[$0] }
                        edit { $0.removeAll(where: removed.contains) }
                    }
            }
        }
        .onAppear { edit { _ in } }
        .settingsPage(title: "Blocked Words", keyboard: true)
    }

    /// Edits the stored list, not this page's copy, which misses words the
    /// keyboard blocked while it was open.
    private func edit(_ change: (inout [String]) -> Void) {
        var stored = SharedStore.shared.keyboardPreferences
        change(&stored.blockedWords)
        SharedStore.shared.keyboardPreferences = stored
        words = stored.blockedWords
    }

    /// Stored as the keyboard matches them: lowercase, no apostrophes.
    private func add() {
        let key = draft.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        if !key.isEmpty { edit { if !$0.contains(key) { $0.insert(key, at: 0) } } }
        draft = ""
    }
}
