import SwiftUI
import VoiceIQCore

/// Settings › Provider & Keys.
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
        .navigationTitle("Provider & Keys")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The provider (Gemini or OpenAI) and its key, the transcription provider
/// (shown once an ElevenLabs, OpenRouter or Vercel key makes a second option),
/// the optional ElevenLabs and TinyFish keys, and the gateways under a collapsed Experimental section, as
/// on the Mac. Gateway keys serve both providers and MAI Transcribe 2, so
/// they are entered once.
struct ModelKeysForm: View {
    @State private var provider = SettingsStore().preferredProvider
    @State private var gateway = SettingsStore().activeRoute.gateway
    @State private var available = KeychainStore.gatewaysWithKeys(for: SettingsStore().preferredProvider)
    @State private var transcriptionSource = SettingsStore().preferredTranscriptionSource
    @State private var hasElevenLabsKey = KeychainStore.loadElevenLabsKey() != nil
    @State private var hasSarvamKey = KeychainStore.loadSarvamKey() != nil
    @State private var hasGatewayKey = SettingsStore().maiTranscribeEndpoint != nil
    @State private var sarvamLanguage = SettingsStore().sarvamLanguage
    @State private var writingSource = SettingsStore().preferredWritingSource
    /// Collapsed on every visit, like the Mac's Experimental group.
    @State private var experimentalExpanded = false

    private var providerSlot: KeySlot { provider == .gemini ? .gemini : .openAI }

    private var transcriptionOptions: [TranscriptionSource] {
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
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Theme.Colors.accent)
                    .font(.system(size: 17))
                Text("Pick **Gemini** or **OpenAI** and add that provider's key. The ElevenLabs and TinyFish keys are optional.")
                    .font(Theme.Fonts.subheadline())
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.accent.opacity(0.08)))

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                GroupLabel(text: "Provider")
                Picker("Provider", selection: $provider) {
                    ForEach(ModelProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: provider) { _, value in
                    SettingsStore().setPreferredProvider(value)
                    reload()
                }
                KeyCard(slot: providerSlot, onChange: reload)
                    .id(providerSlot)
            }

            if transcriptionOptions.count > 1 {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    GroupLabel(text: "Transcription provider")
                    Picker("Transcription provider", selection: $transcriptionSource) {
                        ForEach(transcriptionOptions) { Text($0.displayName(for: provider)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: transcriptionSource) { _, value in
                        if value != SettingsStore().transcriptionSource { SettingsStore().setPreferredTranscriptionSource(value) }
                    }
                    if transcriptionSource == .sarvam {
                        Picker("Language", selection: $sarvamLanguage) {
                            ForEach(SarvamLanguage.menuOrder) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: sarvamLanguage) { _, value in
                            if value != SettingsStore().sarvamLanguage { SettingsStore().setSarvamLanguage(value) }
                        }
                    }
                }
            }

            if hasSarvamKey {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    GroupLabel(text: "Writing model")
                    Picker("Writing model", selection: $writingSource) {
                        ForEach(WritingSource.allCases) { Text($0.displayName(for: provider)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: writingSource) { _, value in
                        if value != SettingsStore().writingSource { SettingsStore().setPreferredWritingSource(value) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                GroupLabel(text: "Optional")
                KeyCard(slot: .elevenLabs, onChange: reload)
                KeyCard(slot: .sarvam, onChange: reload)
                KeyCard(slot: .tinyFish, onChange: reload)
            }

            experimental
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { _ in
            reload()
        }
    }

    @ViewBuilder private var experimental: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { experimentalExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    GroupLabel(text: "Experimental")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.muted)
                        .rotationEffect(.degrees(experimentalExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Experimental")
            .accessibilityValue(experimentalExpanded ? "Expanded" : "Collapsed")

            if experimentalExpanded {
                if available.count > 1 {
                    Card {
                        Text("Gateway").font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
                        Picker("Gateway", selection: $gateway) {
                            ForEach(ModelGateway.allCases.filter(available.contains)) { option in
                                Text(option.shortName(for: provider)).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: gateway) { _, value in
                            if value != SettingsStore().activeRoute.gateway { SettingsStore().setPreferredGateway(value) }
                        }
                    }
                }
                KeyCard(slot: .openRouter, onChange: reload)
                KeyCard(slot: .vercel, onChange: reload)
            }
        }
    }

    private func reload() {
        let settings = SettingsStore()
        provider = settings.preferredProvider
        available = KeychainStore.gatewaysWithKeys(for: provider)
        gateway = settings.activeRoute.gateway
        hasElevenLabsKey = KeychainStore.loadElevenLabsKey() != nil
        hasSarvamKey = KeychainStore.loadSarvamKey() != nil
        hasGatewayKey = settings.maiTranscribeEndpoint != nil
        transcriptionSource = settings.transcriptionSource
        sarvamLanguage = settings.sarvamLanguage
        writingSource = settings.writingSource
    }
}

private extension ModelGateway {
    func shortName(for provider: ModelProvider) -> String {
        switch self {
        case .direct: return provider.displayName
        case .openRouter: return "OpenRouter"
        case .vercel: return "Vercel"
        }
    }
}

/// One saved-or-not key, with its purpose, a field and its actions.
private struct KeyCard: View {
    let slot: KeySlot
    let onChange: () -> Void

    @State private var text = ""
    @State private var stored = false
    @State private var replacing = false
    @State private var checking = false
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        Card {
            HStack(spacing: Theme.Spacing.m) {
                IconTile(systemImage: slot.symbol, size: 32)
                Text(slot.title).font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
                Spacer(minLength: 0)
                if stored {
                    StatusChip(text: "Saved", tone: .done)
                } else {
                    Link(destination: slot.keyURL) {
                        Label("Get a key", systemImage: "arrow.up.right")
                            .labelStyle(TrailingIconLabelStyle())
                            .font(Theme.Fonts.label())
                            .foregroundStyle(Theme.Colors.accent)
                    }
                }
            }
            Text(slot.purpose)
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
        .onAppear { stored = slot.load() != nil }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            .fill(Theme.Colors.surfaceNested)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .strokeBorder(focused ? Theme.Colors.accent : Theme.Colors.hairline, lineWidth: focused ? 1.5 : 0.5))
    }

    private func remove() {
        slot.delete()
        stored = false
        replacing = false
        message = nil
        onChange()
    }

    private func save() async {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !checking else { return }
        checking = true
        defer { checking = false }
        switch await slot.validate(key) {
        case .rejected(let detail):
            message = detail
            return
        case .accepted(let offline):
            guard slot.save(key) else {
                message = "Couldn't save to the Keychain. Try again."
                return
            }
            text = ""
            stored = true
            replacing = false
            focused = false
            message = offline ? "Saved. It will be checked on your first dictation." : nil
            onChange()
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

/// A place a key can be stored, with what it is for.
enum KeySlot: Hashable, CaseIterable {
    case gemini, openAI, openRouter, vercel, tinyFish, elevenLabs, sarvam

    var title: String {
        switch self {
        case .gemini: return "Gemini"
        case .openRouter: return "OpenRouter"
        case .vercel: return "Vercel AI Gateway"
        case .openAI: return "OpenAI"
        case .tinyFish: return "TinyFish"
        case .elevenLabs: return "ElevenLabs"
        case .sarvam: return "Sarvam"
        }
    }

    var symbol: String {
        switch self {
        case .gemini: return "sparkles"
        case .openRouter: return "arrow.triangle.branch"
        case .vercel: return "triangle.fill"
        case .openAI: return "circle.hexagongrid"
        case .tinyFish: return "globe"
        case .elevenLabs: return "waveform"
        case .sarvam: return "indianrupeesign.circle"
        }
    }

    var purpose: String {
        switch self {
        case .gemini:
            return "Google's Gemini API, with a free tier. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to Google."
        case .openRouter:
            return "Runs Gemini or OpenAI models through OpenRouter, which has no per-minute tier limits. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to OpenRouter."
        case .vercel:
            return "Runs Gemini or OpenAI models through Vercel AI Gateway, billed per call. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to Vercel."
        case .openAI:
            return "OpenAI's API. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to OpenAI."
        case .tinyFish:
            return "Lets Ask Anything look up current information on the web. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to TinyFish."
        case .elevenLabs:
            return "Lets ElevenLabs Scribe transcribe your dictation and meetings instead of the provider's speech model; the provider still applies the writing rules. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to ElevenLabs."
        case .sarvam:
            return "Lets Sarvam Saaras V4 transcribe your dictation and meetings (Indian languages and English), and Sarvam 105B apply the writing rules. Priced in rupees. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to Sarvam."
        }
    }

    var keyURL: URL {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")!
        case .vercel: return URL(string: "https://vercel.com/ai-gateway")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        case .tinyFish: return URL(string: "https://agent.tinyfish.ai/api-keys")!
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .sarvam: return URL(string: "https://dashboard.sarvam.ai/")!
        }
    }

    func load() -> String? {
        switch self {
        case .gemini: return KeychainStore.loadAPIKey()
        case .openRouter: return KeychainStore.loadOpenRouterKey()
        case .vercel: return KeychainStore.loadVercelKey()
        case .openAI: return KeychainStore.loadOpenAIKey()
        case .tinyFish: return KeychainStore.loadTinyFishKey()
        case .elevenLabs: return KeychainStore.loadElevenLabsKey()
        case .sarvam: return KeychainStore.loadSarvamKey()
        }
    }

    func save(_ key: String) -> Bool {
        switch self {
        case .gemini: return KeychainStore.saveAPIKey(key)
        case .openRouter: return KeychainStore.saveOpenRouterKey(key)
        case .vercel: return KeychainStore.saveVercelKey(key)
        case .openAI: return KeychainStore.saveOpenAIKey(key)
        case .tinyFish: return KeychainStore.saveTinyFishKey(key)
        case .elevenLabs: return KeychainStore.saveElevenLabsKey(key)
        case .sarvam: return KeychainStore.saveSarvamKey(key)
        }
    }

    func delete() {
        switch self {
        case .gemini: _ = KeychainStore.deleteAPIKey(notify: true)
        case .openRouter: _ = KeychainStore.deleteOpenRouterKey(notify: true)
        case .vercel: _ = KeychainStore.deleteVercelKey(notify: true)
        case .openAI: _ = KeychainStore.deleteOpenAIKey(notify: true)
        case .tinyFish: _ = KeychainStore.deleteTinyFishKey(notify: true)
        case .elevenLabs: _ = KeychainStore.deleteElevenLabsKey(notify: true)
        case .sarvam: _ = KeychainStore.deleteSarvamKey(notify: true)
        }
    }

    enum Validation { case accepted(offline: Bool), rejected(String) }

    func validate(_ key: String) async -> Validation {
        let check: GeminiClient.KeyCheck
        switch self {
        case .gemini:
            check = await GeminiClient(apiKey: { key }).validateKey(endpoint: SettingsStore().geminiConfig.endpoint)
        case .openRouter:
            check = await GeminiClient(apiKey: { nil }, openRouterKey: { key }).validateOpenRouterKey()
        case .vercel:
            check = await GeminiClient(apiKey: { nil }, vercelKey: { key }).validateVercelKey()
        case .openAI:
            check = await GeminiClient(apiKey: { nil }, openAIKey: { key }).validateOpenAIKey()
        case .elevenLabs:
            check = await GeminiClient(apiKey: { nil }, elevenLabsKey: { key }).validateElevenLabsKey()
        case .sarvam:
            check = await GeminiClient(apiKey: { nil }, sarvamKey: { key }).validateSarvamKey()
        case .tinyFish:
            switch await TinyFishClient(apiKey: { key }).validateKey() {
            case .valid: return .accepted(offline: false)
            case .unreachable: return .accepted(offline: true)
            case .rejected: return .rejected("TinyFish rejected that key, or the account has no Search access.")
            }
        }
        switch check {
        case .valid: return .accepted(offline: false)
        case .unreachable: return .accepted(offline: true)
        case .rejected(let detail): return .rejected(detail ?? "\(title) rejected that key.")
        }
    }
}
