import VoiceIQCore
import SwiftUI

struct OpenAIKeySection: View {
    @State private var apiKey = ""
    @State private var keyStatus: AdvancedPane.KeyStatus = KeychainStore.loadOpenAIKey() == nil ? .missing : .stored

    private var hasStoredKey: Bool {
        keyStatus == .stored || keyStatus == .valid || keyStatus == .savedOffline
    }

    var body: some View {
        Section {
            HStack {
                LabeledContent("API key") {
                    SecureField("", text: $apiKey, prompt: Text(hasStoredKey ? "••••••••  (stored in Keychain)" : "Paste your key"))
                        .labelsHidden()
                        .font(VoiceIQUI.TypeScale.code)
                        .multilineTextAlignment(.trailing)
                }
                keyStatusBadge
            }
            if keyStatus == .invalid {
                Text(KeychainStore.loadOpenAIKey() != nil
                     ? "That key didn't work. Your saved key is unchanged."
                     : "OpenAI rejected that key.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(VoiceIQUI.Colors.error)
            }
            if keyStatus == .saveFailed {
                Text("The key validated but couldn't be saved to your Keychain. Try again.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(VoiceIQUI.Colors.error)
            }
            if keyStatus == .savedOffline {
                Text("You look offline. The key was saved and will be checked on your first dictation.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Save & Validate") { saveAndValidate() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasStoredKey {
                    Button("Remove Key…", role: .destructive) {
                        KeychainStore.deleteOpenAIKey(notify: true)
                        apiKey = ""
                        keyStatus = .missing
                    }
                }
                Spacer()
                Link("Get a key at OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(VoiceIQUI.TypeScale.labelSmall())
            }
        } header: {
            Text("OpenAI API key")
        } footer: {
            Text("Stored in your Mac's Keychain and only ever sent to OpenAI.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == "openAIKey", keyStatus == .missing || keyStatus == .stored {
                keyStatus = KeychainStore.loadOpenAIKey() == nil ? .missing : .stored
            }
        }
    }

    @ViewBuilder
    private var keyStatusBadge: some View {
        switch keyStatus {
        case .missing: Image(systemName: "key.slash").foregroundStyle(.secondary)
        case .stored, .savedOffline: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .validating: ProgressView().controlSize(.small)
        case .valid: Image(systemName: "checkmark.circle").foregroundStyle(VoiceIQUI.Colors.success)
        case .invalid, .saveFailed: Image(systemName: "xmark.circle.fill").foregroundStyle(VoiceIQUI.Colors.error)
        }
    }

    private func saveAndValidate() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyStatus = .validating
        Task {
            let client = GeminiClient(apiKey: { nil }, openAIKey: { key })
            let check = await client.validateOpenAIKey()
            switch check {
            case .valid, .unreachable:
                if KeychainStore.saveOpenAIKey(key) {
                    apiKey = ""
                    keyStatus = check == .valid ? .valid : .savedOffline
                } else {
                    keyStatus = .saveFailed
                }
            case .rejected:
                keyStatus = .invalid
            }
        }
    }
}

struct OpenAIModelsSection: View {
    private static let defaults = OpenAIConfig()
    private let settings = SettingsStore()
    @State private var transcribeModel = SettingsStore().openAITranscribeModelOverride ?? ""
    @State private var writingModel = SettingsStore().openAIWritingModelOverride ?? ""

    var body: some View {
        Section {
            modelField("Transcription model", text: $transcribeModel, placeholder: Self.defaults.transcribeModel,
                       save: settings.setOpenAITranscribeModelOverride)
            modelField("Formatting model", text: $writingModel, placeholder: Self.defaults.writingModel,
                       save: settings.setOpenAIWritingModelOverride)
        } header: {
            Text("OpenAI models")
        }
    }

    private func modelField(_ label: String, text: Binding<String>, placeholder: String,
                            save: @escaping (String?) -> Void) -> some View {
        LabeledContent(label) {
            TextField("", text: text, prompt: Text(placeholder))
                .labelsHidden()
                .font(VoiceIQUI.TypeScale.code)
                .multilineTextAlignment(.trailing)
        }
        .onChange(of: text.wrappedValue) { _, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            save(trimmed.isEmpty ? nil : trimmed)
        }
    }
}

struct ProviderSection: View {
    @Binding var provider: ModelProvider
    private let settings = SettingsStore()

    var body: some View {
        Section {
            Picker("Provider", selection: $provider) {
                ForEach(ModelProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: provider) { _, value in settings.setPreferredProvider(value) }
        }
    }
}
