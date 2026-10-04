import VoiceIQCore
import SwiftUI

/// Settings → Advanced: a key other than Gemini's (OpenAI, or a gateway key
/// shared by both providers) with the same save-and-validate flow.
struct GatewayKeySection: View {
    struct Gateway {
        let name: String
        let secret: KeychainStore.Secret
        let load: () -> String?
        let save: (String) -> Bool
        let delete: () -> Void
        let validate: (GeminiClient) async -> GeminiClient.KeyCheck
        let client: (String) -> GeminiClient
        let keyURL: URL
        let footer: String

        static let openRouter = Gateway(
            name: "OpenRouter",
            secret: .openRouter,
            load: KeychainStore.loadOpenRouterKey,
            save: KeychainStore.saveOpenRouterKey,
            delete: { KeychainStore.deleteOpenRouterKey(notify: true) },
            validate: { await $0.validateOpenRouterKey() },
            client: { key in GeminiClient(apiKey: { nil }, openRouterKey: { key }) },
            keyURL: URL(string: "https://openrouter.ai/settings/keys")!,
            footer: "Optional. Runs Gemini or OpenAI models, and MAI Transcribe 2, through OpenRouter, which has no per-minute tier limits. Stored in your Mac's Keychain and only ever sent to OpenRouter."
        )

        static let vercel = Gateway(
            name: "Vercel AI Gateway",
            secret: .vercel,
            load: KeychainStore.loadVercelKey,
            save: KeychainStore.saveVercelKey,
            delete: { KeychainStore.deleteVercelKey(notify: true) },
            validate: { await $0.validateVercelKey() },
            client: { key in GeminiClient(apiKey: { nil }, vercelKey: { key }) },
            keyURL: URL(string: "https://vercel.com/ai-gateway")!,
            footer: "Optional. Runs Gemini or OpenAI models, and MAI Transcribe 2, through Vercel AI Gateway, billed per call. Stored in your Mac's Keychain and only ever sent to Vercel."
        )

        static let openAI = Gateway(
            name: "OpenAI",
            secret: .openAI,
            load: KeychainStore.loadOpenAIKey,
            save: KeychainStore.saveOpenAIKey,
            delete: { KeychainStore.deleteOpenAIKey(notify: true) },
            validate: { await $0.validateOpenAIKey() },
            client: { key in GeminiClient(apiKey: { nil }, openAIKey: { key }) },
            keyURL: URL(string: "https://platform.openai.com/api-keys")!,
            footer: "Stored in your Mac's Keychain and only ever sent to OpenAI."
        )

        static let elevenLabs = Gateway(
            name: "ElevenLabs",
            secret: .elevenLabs,
            load: KeychainStore.loadElevenLabsKey,
            save: KeychainStore.saveElevenLabsKey,
            delete: { KeychainStore.deleteElevenLabsKey(notify: true) },
            validate: { await $0.validateElevenLabsKey() },
            client: { key in GeminiClient(apiKey: { nil }, elevenLabsKey: { key }) },
            keyURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")!,
            footer: "Optional. Lets ElevenLabs Scribe transcribe your dictation and meetings instead of the provider's speech model; the provider still applies the writing rules. Stored in your Mac's Keychain and only ever sent to ElevenLabs."
        )

        static let sarvam = Gateway(
            name: "Sarvam",
            secret: .sarvam,
            load: KeychainStore.loadSarvamKey,
            save: KeychainStore.saveSarvamKey,
            delete: { KeychainStore.deleteSarvamKey(notify: true) },
            validate: { await $0.validateSarvamKey() },
            client: { key in GeminiClient(apiKey: { nil }, sarvamKey: { key }) },
            keyURL: URL(string: "https://dashboard.sarvam.ai/")!,
            footer: "Optional. Lets Sarvam Saaras V4 transcribe your dictation and meetings (Indian languages and English, no screenshots), and Sarvam 105B apply the writing rules. Priced in rupees. Stored in your Mac's Keychain and only ever sent to Sarvam."
        )
    }

    let gateway: Gateway
    @State private var apiKey = ""
    @State private var keyStatus: AdvancedPane.KeyStatus

    init(_ gateway: Gateway) {
        self.gateway = gateway
        _keyStatus = State(initialValue: gateway.load() == nil ? .missing : .stored)
    }

    private var hasStoredKey: Bool { keyStatus == .stored || keyStatus == .valid || keyStatus == .savedOffline }

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
                Text(gateway.load() != nil
                     ? "That key didn't work — your saved key is unchanged."
                     : "\(gateway.name) rejected that key.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(VoiceIQUI.Colors.error)
            }
            if keyStatus == .saveFailed {
                Text("The key validated but couldn't be saved to your Keychain — try again.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(VoiceIQUI.Colors.error)
            }
            if keyStatus == .savedOffline {
                Text("You look offline — key saved; it'll be checked on your first dictation.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Save & Validate") { saveAndValidate() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasStoredKey {
                    Button("Remove Key…", role: .destructive) { gateway.delete(); apiKey = ""; keyStatus = .missing }
                }
                Spacer()
                Link("Get a key at \(gateway.name)", destination: gateway.keyURL)
                    .font(VoiceIQUI.TypeScale.labelSmall())
            }
        } header: {
            Text("\(gateway.name) API key")
        } footer: {
            Text(gateway.footer)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            guard let key = note.object as? String else { return }
            if key == secret.settingKey, keyStatus == .missing || keyStatus == .stored {
                keyStatus = gateway.load() == nil ? .missing : .stored
            }
        }
    }

    private var secret: KeychainStore.Secret { gateway.secret }

    @ViewBuilder
    private var keyStatusBadge: some View {
        switch keyStatus {
        case .missing:
            Image(systemName: "key.slash").foregroundStyle(.secondary)
        case .stored, .savedOffline:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .validating:
            ProgressView().controlSize(.small)
        case .valid:
            Image(systemName: "checkmark.circle").foregroundStyle(VoiceIQUI.Colors.success)
        case .invalid, .saveFailed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(VoiceIQUI.Colors.error)
        }
    }

    private func saveAndValidate() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyStatus = .validating
        Task {
            let check = await gateway.validate(gateway.client(key))
            switch check {
            case .valid, .unreachable:
                if gateway.save(key) {
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

/// Settings → Advanced: the OpenAI model for each role. Blank fields use the
/// defaults shown as placeholders; every edit saves as you type.
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

/// Settings → Advanced: who transcribes and who writes, plus the ElevenLabs
/// and Sarvam keys. ElevenLabs and Sarvam are offered once their keys are
/// stored, MAI Transcribe 2 once an OpenRouter or Vercel key is. With none,
/// the pickers are hidden and the provider transcribes and writes.
struct TranscriptionSourceSection: View {
    let provider: ModelProvider
    private let settings = SettingsStore()
    @State private var source = SettingsStore().preferredTranscriptionSource
    @State private var writing = SettingsStore().preferredWritingSource
    @State private var hasElevenLabsKey = KeychainStore.loadElevenLabsKey() != nil
    @State private var hasSarvamKey = KeychainStore.loadSarvamKey() != nil
    @State private var hasGatewayKey = SettingsStore().maiTranscribeEndpoint != nil
    @State private var maiStyle = SettingsStore().maiTranscribeStyle
    @State private var sarvamLanguage = SettingsStore().sarvamLanguage

    private var options: [TranscriptionSource] {
        TranscriptionSource.allCases.filter { source in
            switch source {
            case .provider: return true
            case .elevenLabs: return hasElevenLabsKey
            case .maiTranscribe: return hasGatewayKey
            case .sarvam: return hasSarvamKey
            }
        }
    }

    var body: some View {
        Group {
            if options.count > 1 {
                Section {
                    Picker("Transcription provider", selection: $source) {
                        ForEach(options) { Text($0.displayName(for: provider)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: source) { _, value in
                        if value != settings.transcriptionSource { settings.setPreferredTranscriptionSource(value) }
                    }
                    if source == .maiTranscribe {
                        Picker("Transcript style", selection: $maiStyle) {
                            ForEach(MAITranscribeStyle.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: maiStyle) { _, value in
                            if value != settings.maiTranscribeStyle { settings.setMAITranscribeStyle(value) }
                        }
                    }
                    if source == .sarvam {
                        Picker("Language", selection: $sarvamLanguage) {
                            ForEach(SarvamLanguage.menuOrder) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: sarvamLanguage) { _, value in
                            if value != settings.sarvamLanguage { settings.setSarvamLanguage(value) }
                        }
                    }
                }
            }
            if hasSarvamKey {
                Section {
                    Picker("Writing model", selection: $writing) {
                        ForEach(WritingSource.allCases) { Text($0.displayName(for: provider)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: writing) { _, value in
                        if value != settings.writingSource { settings.setPreferredWritingSource(value) }
                    }
                }
            }
            GatewayKeySection(.elevenLabs)
            GatewayKeySection(.sarvam)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { _ in refresh() }
    }

    private func refresh() {
        hasElevenLabsKey = KeychainStore.loadElevenLabsKey() != nil
        hasSarvamKey = KeychainStore.loadSarvamKey() != nil
        hasGatewayKey = settings.maiTranscribeEndpoint != nil
        source = settings.transcriptionSource
        writing = settings.writingSource
        maiStyle = settings.maiTranscribeStyle
        sarvamLanguage = settings.sarvamLanguage
    }
}

/// Settings → Advanced: whose models run, Gemini or OpenAI.
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

/// Settings → Advanced → Experimental: the gateways. Collapsed on every
/// visit. Holds the gateway picker (only when more than one route has a key)
/// and the OpenRouter and Vercel keys, which serve both providers.
struct ExperimentalGatewaysSection: View {
    let provider: ModelProvider
    private let settings = SettingsStore()
    @State private var expanded = false
    @State private var gateway = SettingsStore().activeRoute.gateway
    @State private var available = KeychainStore.gatewaysWithKeys(for: SettingsStore().preferredProvider)

    var body: some View {
        Group {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: VoiceIQUI.Spacing.s) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Experimental")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Experimental")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
        if expanded {
            if available.count > 1 {
                Section {
                    Picker("Gateway", selection: $gateway) {
                        ForEach(ModelGateway.allCases.filter(available.contains)) { gateway in
                            Text(gateway.displayName(for: provider)).tag(gateway)
                        }
                    }
                    .onChange(of: gateway) { _, value in
                        if value != settings.activeRoute.gateway { settings.setPreferredGateway(value) }
                    }
                }
            }
            GatewayKeySection(.openRouter)
            GatewayKeySection(.vercel)
            AgentProviderSection()
        }
        }
        .onChange(of: provider) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { _ in refresh() }
    }

    private func refresh() {
        available = KeychainStore.gatewaysWithKeys(for: provider)
        gateway = settings.activeRoute.gateway
    }
}
