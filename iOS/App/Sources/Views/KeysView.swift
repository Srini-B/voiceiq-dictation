import SwiftUI
import VoiceIQCore

/// Settings › API Key.
struct KeysView: View {
    var body: some View {
        ScrollView {
            ModelKeysForm()
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, Theme.Spacing.l)
                .readableWidth()
        }
        .keyboardDismissable()
        .themedBackground()
        .navigationTitle("API Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The AssemblyAI key, the only one VoiceiQ uses.
struct ModelKeysForm: View {
    var body: some View {
        KeyCard()
    }
}

/// The saved-or-not AssemblyAI key, with its purpose, a field and its actions.
private struct KeyCard: View {
    @State private var text = ""
    @State private var stored = false
    @State private var replacing = false
    @State private var checking = false
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        Card {
            HStack(spacing: Theme.Spacing.m) {
                BrandTile(systemImage: "waveform", size: 32)
                Text("AssemblyAI").font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
                Spacer(minLength: 0)
                if stored {
                    StatusChip(text: "Saved", tone: .done)
                } else {
                    Link(destination: URL(string: "https://www.assemblyai.com/dashboard/api-keys")!) {
                        Label("Get a key", systemImage: "arrow.up.right")
                            .labelStyle(TrailingIconLabelStyle())
                            .font(Theme.Fonts.label())
                            .foregroundStyle(Theme.Colors.accent)
                    }
                }
            }
            Text("AssemblyAI, with $50 of free credit at sign-up; the writing step needs a small balance, since the free credit doesn't cover the LLM Gateway. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to AssemblyAI.")
                .font(Theme.Fonts.footnote())
                .foregroundStyle(Theme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)

            if stored && !replacing {
                HStack(spacing: Theme.Spacing.s) {
                    Text("••••••••••••")
                        .font(Theme.Fonts.code)
                        .foregroundStyle(Theme.Colors.muted)
                    Spacer(minLength: 0)
                    Button("Replace") { replacing = true; focused = true }.buttonStyle(.compactSecondary)
                    Button("Remove", action: remove).buttonStyle(.compactDestructive)
                }
                .padding(.leading, Theme.Spacing.m)
                .padding(.trailing, 6)
                .frame(minHeight: 48)
                .background(fieldBackground)
            } else {
                HStack(spacing: Theme.Spacing.s) {
                    SecureField("", text: $text, prompt: Text("Paste key").font(Theme.Fonts.callout()))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.Fonts.code)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { Task { await save() } }
                    if checking {
                        ProgressView().padding(.horizontal, Theme.Spacing.m)
                    } else {
                        Button("Save") { Task { await save() } }
                            .buttonStyle(.compactPrimary)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.leading, Theme.Spacing.m)
                .padding(.trailing, 6)
                .frame(minHeight: 48)
                .background(fieldBackground)
            }

            if let message {
                Text(message)
                    .font(Theme.Fonts.footnote())
                    .foregroundStyle(message.hasPrefix("Saved") ? Theme.Colors.muted : Theme.Colors.recording)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { stored = KeychainStore.loadAPIKey() != nil }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            .fill(Theme.Colors.surfaceNested)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .strokeBorder(focused ? Theme.Colors.accent : Theme.Colors.hairline, lineWidth: focused ? 1.5 : 0.5))
    }

    private func remove() {
        _ = KeychainStore.deleteAPIKey(notify: true)
        stored = false
        replacing = false
        message = nil
    }

    private func save() async {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !checking else { return }
        checking = true
        defer { checking = false }
        let check = await AssemblyAIClient(apiKey: { key }).validateKey()
        switch check {
        case .rejected(let detail):
            message = detail ?? "AssemblyAI rejected that key."
            return
        case .valid, .unreachable:
            guard KeychainStore.saveAPIKey(key) else {
                message = "Couldn't save to the Keychain. Try again."
                return
            }
            text = ""
            stored = true
            replacing = false
            focused = false
            message = check == .unreachable ? "Saved. It will be checked on your first dictation." : nil
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
