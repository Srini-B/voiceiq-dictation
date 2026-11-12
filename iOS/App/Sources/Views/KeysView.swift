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

/// The selected model provider, the transcription choice once an ElevenLabs
/// key is stored, and the optional ElevenLabs and web search keys.
struct ModelKeysForm: View {
    @State private var provider = SettingsStore().preferredProvider
    @State private var elevenLabs = SettingsStore().elevenLabsTranscriptionChosen
    @State private var hasElevenLabsKey = KeychainStore.loadKey(.elevenLabs) != nil
    @State private var languages = SettingsStore().spokenLanguages
    @State private var choosingOthers = false
    @State private var redacts = SettingsStore().redactsMeetingSecrets

    private var providerSlots: [KeySlot] {
        switch provider {
        case .gemini: return [.gemini]
        case .openAI: return [.openAI]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Theme.Colors.accent)
                    .font(.system(size: 17))
                Text("Pick **Gemini** or **OpenAI** and add its key. The other keys are optional; an ElevenLabs key lets Scribe v3 transcribe.")
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
                ForEach(providerSlots, id: \.self) { slot in
                    KeyCard(slot: slot, onChange: reload)
                }
            }

            if hasElevenLabsKey {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    GroupLabel(text: "Transcription")
                    Picker("Transcription", selection: $elevenLabs) {
                        Text(provider.displayName).tag(false)
                        Text("ElevenLabs").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: elevenLabs) { _, value in SettingsStore().setElevenLabsTranscription(value) }
                    Text(elevenLabs
                         ? "Scribe v3 transcribes dictation from the recording, after you stop; Real-time transcription is not used with it. Notes show a live transcript from Scribe v3 Live while they record, and Scribe v3 makes the saved transcript when they stop. \(provider.displayName) still applies the writing rules and writes the notes."
                         : "\(provider.displayName) transcribes dictation and meetings.")
                        .font(Theme.Fonts.footnote())
                        .foregroundStyle(Theme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if elevenLabs {
                        GroupLabel(text: "Spoken languages")
                        VStack(spacing: 0) {
                            HStack {
                                Text("Main language").font(Theme.Fonts.subheadline()).foregroundStyle(Theme.Colors.ink)
                                Spacer()
                                Picker("Main language", selection: Binding(get: { languages.first ?? "" }, set: {
                                    saveLanguages(ScribeLanguage.choosing(main: $0, in: languages))
                                })) {
                                    Text("Automatic detection").tag("")
                                    ForEach(ScribeLanguage.all) { Text($0.name).tag($0.code) }
                                }
                                .pickerStyle(.menu)
                                .tint(Theme.Colors.accent)
                            }
                            if !languages.isEmpty {
                                Divider()
                                Button { choosingOthers = true } label: {
                                    HStack {
                                        Text("Also spoken").font(Theme.Fonts.subheadline()).foregroundStyle(Theme.Colors.ink)
                                        Spacer()
                                        Text(ScribeLanguage.names(languages.dropFirst(), none: "None"))
                                            .font(Theme.Fonts.subheadline()).foregroundStyle(Theme.Colors.muted).lineLimit(1)
                                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.Colors.muted)
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.m)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill(Theme.Colors.accent.opacity(0.06)))
                        .sheet(isPresented: $choosingOthers) {
                            OtherLanguagesSheet(languages: languages) { saveLanguages($0) }
                        }
                        Text("Automatic detection works out the language each time. Pick your main language, and any others you mix in, when Scribe gets it wrong.")
                            .font(Theme.Fonts.footnote())
                            .foregroundStyle(Theme.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Hide card and ID numbers in notes", isOn: $redacts)
                            .font(Theme.Fonts.subheadline())
                            .tint(Theme.Colors.accent)
                            .onChange(of: redacts) { _, value in SettingsStore().setRedactsMeetingSecrets(value) }
                        Text("Card details, ID, account and health-card numbers and passwords are written as {CREDIT_CARD} and the like, so they are never saved or sent for notes. ElevenLabs charges 30% more for it.")
                            .font(Theme.Fonts.footnote())
                            .foregroundStyle(Theme.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                GroupLabel(text: "Optional")
                KeyCard(slot: .elevenLabs, onChange: reload)
                KeyCard(slot: .tinyFish, onChange: reload)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { _ in
            reload()
        }
    }

    private func saveLanguages(_ codes: [String]) {
        languages = codes
        SettingsStore().setSpokenLanguages(codes)
    }

    private func reload() {
        let settings = SettingsStore()
        provider = settings.preferredProvider
        hasElevenLabsKey = KeychainStore.loadKey(.elevenLabs) != nil
        elevenLabs = settings.elevenLabsTranscriptionChosen
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
                BrandTile(image: slot.mark, size: 32)
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
    case gemini, openAI, elevenLabs, tinyFish

    var title: String {
        switch self {
        case .gemini: return "Gemini"
        case .openAI: return "OpenAI"
        case .elevenLabs: return "ElevenLabs"
        case .tinyFish: return "TinyFish"
        }
    }

    /// The service's favicon in the asset catalog.
    var mark: String {
        switch self {
        case .gemini: return "ProviderGemini"
        case .openAI: return "ProviderOpenAI"
        case .elevenLabs: return "ProviderElevenLabs"
        case .tinyFish: return "ProviderTinyFish"
        }
    }

    var purpose: String {
        switch self {
        case .gemini:
            return "Google's Gemini API, with a free tier. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to Google."
        case .openAI:
            return "OpenAI's API. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to OpenAI."
        case .elevenLabs:
            return "Lets ElevenLabs Scribe v3 transcribe dictation and meetings in place of the provider. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to ElevenLabs."
        case .tinyFish:
            return "Lets Ask Anything look up current information on the web. Stored in your \(UIDevice.current.localizedModel)'s Keychain and only ever sent to TinyFish."
        }
    }

    var keyURL: URL {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .tinyFish: return URL(string: "https://agent.tinyfish.ai/api-keys")!
        }
    }

    func load() -> String? {
        switch self {
        case .gemini: return KeychainStore.loadAPIKey()
        case .openAI: return KeychainStore.loadOpenAIKey()
        case .elevenLabs: return KeychainStore.loadKey(.elevenLabs)
        case .tinyFish: return KeychainStore.loadTinyFishKey()
        }
    }

    func save(_ key: String) -> Bool {
        switch self {
        case .gemini: return KeychainStore.saveAPIKey(key)
        case .openAI: return KeychainStore.saveOpenAIKey(key)
        case .elevenLabs: return KeychainStore.saveKey(.elevenLabs, key)
        case .tinyFish: return KeychainStore.saveTinyFishKey(key)
        }
    }

    func delete() {
        switch self {
        case .gemini: _ = KeychainStore.deleteAPIKey(notify: true)
        case .openAI: _ = KeychainStore.deleteOpenAIKey(notify: true)
        case .elevenLabs: _ = KeychainStore.deleteKey(.elevenLabs, notify: true)
        case .tinyFish: _ = KeychainStore.deleteTinyFishKey(notify: true)
        }
    }

    enum Validation { case accepted(offline: Bool), rejected(String) }

    func validate(_ key: String) async -> Validation {
        let check: GeminiClient.KeyCheck
        switch self {
        case .gemini:
            check = await GeminiClient(apiKey: { key }).validateKey(endpoint: SettingsStore().geminiConfig.endpoint)
        case .openAI:
            check = await GeminiClient(apiKey: { nil }, openAIKey: { key }).validateOpenAIKey()
        case .elevenLabs:
            check = await GeminiClient(apiKey: { nil }, elevenLabsKey: { key }).validateElevenLabsKey()
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

/// Other languages Scribe may hear besides the main one, ticked in a list.
private struct OtherLanguagesSheet: View {
    @State var languages: [String]
    let save: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(ScribeLanguage.all.filter { $0.code != languages.first }) { language in
                Button {
                    languages = ScribeLanguage.toggling(language.code, in: languages)
                    save(languages)
                } label: {
                    HStack {
                        Text(language.name).foregroundStyle(Theme.Colors.ink)
                        Spacer()
                        if languages.dropFirst().contains(language.code) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.Colors.accent)
                        }
                    }
                }
            }
            .navigationTitle("Also spoken")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
