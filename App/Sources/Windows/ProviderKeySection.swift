import VoiceIQCore
import SwiftUI

/// One API key: paste, validate against its host, save to the Keychain.
struct ProviderKeySection: View {
    let secret: KeychainStore.Secret
    /// "OpenAI".
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

    static let elevenLabs = ProviderKeySection(
        secret: .elevenLabs, vendor: "ElevenLabs", keyPage: URL(string: "https://elevenlabs.io/app/settings/api-keys")!,
        validate: { key in await GeminiClient(apiKey: { nil }, elevenLabsKey: { key }).validateElevenLabsKey() })
}

/// The transcription provider: the model provider, or ElevenLabs, whose
/// Scribe v3 then transcribes dictation and meetings. Needs the ElevenLabs
/// key above; the model provider still writes.
struct ElevenLabsTranscriptionSection: View {
    let provider: ModelProvider
    private let settings = SettingsStore()
    @State private var chosen = SettingsStore().elevenLabsTranscriptionChosen
    @State private var hasKey = KeychainStore.loadKey(.elevenLabs) != nil
    @State private var languages = SettingsStore().spokenLanguages
    @State private var redacts = SettingsStore().redactsMeetingSecrets

    private static func options(_ languages: [ScribeLanguage]) -> [SearchOption<String>] {
        languages.map { SearchOption(value: $0.code, name: $0.name, keywords: $0.code) }
    }

    var body: some View {
        Section {
            Picker("Transcription provider", selection: Binding(get: { chosen && hasKey }, set: {
                chosen = $0
                settings.setElevenLabsTranscription($0)
            })) {
                Text(provider.displayName).tag(false)
                Text("ElevenLabs").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!hasKey)
            if chosen && hasKey {
                SearchablePicker("Spoken language", selection: Binding(get: { languages.first ?? "" }, set: {
                    save(ScribeLanguage.choosing(main: $0, in: languages))
                }), options: [SearchOption(value: "", name: "Automatic")] + Self.options(ScribeLanguage.all))
                .help("The language you speak most. Automatic detection lets Scribe work it out each time.")
                if let main = languages.first {
                    SearchablePicker("Also spoken", summary: ScribeLanguage.names(languages.dropFirst(), none: "None"),
                                     options: Self.options(ScribeLanguage.all.filter { $0.code != main }),
                                     isSelected: { languages.dropFirst().contains($0) },
                                     toggle: { save(ScribeLanguage.toggling($0, in: languages)) })
                    .help("Other languages Scribe may hear, such as English mixed into Tamil.")
                }
                Toggle("Hide card and ID numbers in meetings", isOn: $redacts)
                    .help("Scribe v3 writes card details, ID, account and health-card numbers and passwords as {CREDIT_CARD} and the like in meeting transcripts, so they are never saved or sent for notes. ElevenLabs charges 30% more for it. The live transcript shows each turn once it is redacted, a moment after it is said.")
                    .onChange(of: redacts) { _, value in settings.setRedactsMeetingSecrets(value) }
            }
        } footer: {
            Text(!hasKey
                 ? "Add an ElevenLabs key above to transcribe with Scribe v3."
                 : chosen
                 ? "Scribe v3 transcribes dictation from the recording, after you stop; Real-time transcription is not used with it. With Smart transcription on, Scribe also drops filler words and formats the text before \(provider.displayName) applies your writing rules. Meetings show a live transcript from Scribe v3 Live while they record, and Scribe v3 makes the saved transcript when they stop. Meeting notes still come from \(provider.displayName)."
                 : "\(provider.displayName) transcribes dictation and meetings.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { _ in
            chosen = settings.elevenLabsTranscriptionChosen
            hasKey = KeychainStore.loadKey(.elevenLabs) != nil
        }
    }

    private func save(_ codes: [String]) {
        languages = codes
        settings.setSpokenLanguages(codes)
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
