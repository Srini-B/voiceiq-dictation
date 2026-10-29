import VoiceIQCore
import SwiftUI

/// One API key: paste, validate against its host, save to the Keychain.
struct ProviderKeySection: View {
    let secret: KeychainStore.Secret
    /// "OpenAI", "Anthropic", "DeepInfra".
    let vendor: String
    let keyPage: URL
    let validate: @Sendable (String) async -> GeminiClient.KeyCheck

    @State private var apiKey = ""
    @State private var keyStatus: AdvancedPane.KeyStatus = .missing

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
                Text(KeychainStore.loadKey(secret) != nil
                     ? "That key didn't work. Your saved key is unchanged."
                     : "\(vendor) rejected that key.")
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
                        KeychainStore.deleteKey(secret, notify: true)
                        apiKey = ""
                        keyStatus = .missing
                    }
                }
                Spacer()
                Link("Get a key at \(vendor)", destination: keyPage)
                    .font(VoiceIQUI.TypeScale.labelSmall())
            }
        } header: {
            Text("\(vendor) API key")
        } footer: {
            Text("Stored in your Mac's Keychain and only ever sent to \(vendor).")
        }
        .onAppear { keyStatus = KeychainStore.loadKey(secret) == nil ? .missing : .stored }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == secret.settingKey, keyStatus == .missing || keyStatus == .stored {
                keyStatus = KeychainStore.loadKey(secret) == nil ? .missing : .stored
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
            let check = await validate(key)
            switch check {
            case .valid, .unreachable:
                if KeychainStore.saveKey(secret, key) {
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

extension ProviderKeySection {
    static let openAI = ProviderKeySection(
        secret: .openAI, vendor: "OpenAI", keyPage: URL(string: "https://platform.openai.com/api-keys")!,
        validate: { key in await GeminiClient(apiKey: { nil }, openAIKey: { key }).validateOpenAIKey() })
    static let anthropic = ProviderKeySection(
        secret: .anthropic, vendor: "Anthropic", keyPage: URL(string: "https://console.anthropic.com/settings/keys")!,
        validate: { key in await GeminiClient.validateAnthropicKey(key) })
    static let deepInfra = ProviderKeySection(
        secret: .deepInfra, vendor: "DeepInfra", keyPage: URL(string: "https://deepinfra.com/dash/api_keys")!,
        validate: { key in await GeminiClient.validateDeepInfraKey(key) })
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
