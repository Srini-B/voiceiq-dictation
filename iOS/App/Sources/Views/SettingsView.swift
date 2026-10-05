import SwiftUI
import VoiceIQBridge
import VoiceIQCore

/// The pages under Settings, in sidebar order.
enum SettingsSection: String, CaseIterable, Identifiable {
    case keys, keyboard, dictation, dictionary, returnApps, privacy, cost, advanced
    var id: String { rawValue }

    static let primary: [SettingsSection] = [.keys, .keyboard, .dictation, .dictionary, .returnApps]
    static let secondary: [SettingsSection] = [.privacy, .cost, .advanced]

    var title: String {
        switch self {
        case .keys: return "Provider & Keys"
        case .keyboard: return "Keyboard & Permissions"
        case .dictation: return "Dictation"
        case .dictionary: return "Dictionary"
        case .returnApps: return "Return to Apps"
        case .privacy: return "Privacy"
        case .cost: return "Cost"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .keys: return "key.fill"
        case .keyboard: return "keyboard.fill"
        case .dictation: return "waveform"
        case .dictionary: return "character.book.closed.fill"
        case .returnApps: return "arrow.uturn.backward"
        case .privacy: return "hand.raised.fill"
        case .cost: return "chart.bar.fill"
        case .advanced: return "slider.horizontal.3"
        }
    }

    @ViewBuilder var page: some View {
        switch self {
        case .keys: KeysView()
        case .keyboard: KeyboardSetupView()
        case .dictation: DictationSettingsView()
        case .dictionary: DictionaryView()
        case .returnApps: ReturnAppsView()
        case .privacy: PrivacyView()
        case .cost: UsageView()
        case .advanced: AdvancedView()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var setup: SetupMonitor
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: SettingsSection?

    var body: some View {
        ListDetailNavigation {
            List(selection: $selection) {
                Section {
                    VStack(spacing: Theme.Spacing.s) {
                        Wordmark(height: 36)
                        Text(versionText)
                            .font(Theme.Fonts.caption())
                            .foregroundStyle(Theme.Colors.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.m)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section { ForEach(SettingsSection.primary) { row($0) } }
                Section { ForEach(SettingsSection.secondary) { row($0) } }
            }
            .listStyle(.insetGrouped)
            .themedBackground()
            .navigationTitle("Settings")
            .onAppear { setup.refresh() }
        } detail: {
            if let selection {
                selection.page
            } else {
                DetailPlaceholder(systemImage: "gearshape", title: "No setting selected")
            }
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "Version \(version) (\(build))"
    }

    /// Beside its page (iPad) the open section's row is tinted; a custom row
    /// background hides the list's own selection, so the tint is drawn here.
    private func row(_ section: SettingsSection) -> some View {
        let open = sizeClass == .regular && selection == section
        return NavigationLink(value: section) {
            HStack(spacing: Theme.Spacing.m) {
                IconTile(systemImage: section.icon)
                Text(section.title).font(Theme.Fonts.body())
                    .foregroundStyle(open ? Theme.Colors.accent : Theme.Colors.ink)
                Spacer(minLength: Theme.Spacing.s)
                chip(for: section)
            }
        }
        .listRowBackground(open ? Theme.Colors.accent.opacity(0.14) : Theme.Colors.surface)
    }

    @ViewBuilder private func chip(for section: SettingsSection) -> some View {
        switch section {
        case .keys where !KeychainStore.hasModelKey:
            StatusChip(text: "Missing", tone: .pending)
        case .keyboard where !setup.status.keyboardReady || !setup.status.micGranted:
            StatusChip(text: "Set up", tone: .pending)
        default:
            EmptyView()
        }
    }
}

struct DictationSettingsView: View {
    @EnvironmentObject private var session: VoiceSession
    private let settings = SettingsStore()
    @State private var translationTarget = SettingsStore().translationTargetLanguage
    @State private var smartTranscription = SettingsStore().smartTranscriptionEnabled
    @State private var cleanupPass = SettingsStore().smartCleanupPassEnabled
    @State private var instructions = SettingsStore().customInstructions
    @State private var noiseHandling = SettingsStore().experimentalNoiseHandling
    @State private var builtInMic = MobileSettings.preferBuiltInMic
    @State private var warmWindow = MobileSettings.warmWindow

    var body: some View {
        Form {
            Section {
                Picker("Keep mic on after dictating", selection: $warmWindow) {
                    ForEach(MobileSettings.WarmWindow.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: warmWindow) { _, value in MobileSettings.warmWindow = value }
            } footer: {
                Text("While the mic is on, the next keyboard tap starts right away. After that, the tap opens VoiceiQ for a moment.")
            }
            Section {
                NavigationLink {
                    LanguageList(selected: $translationTarget)
                } label: {
                    LabeledContent("Translate to", value: translationTarget)
                }
                .onChange(of: translationTarget) { _, value in settings.setTranslationTargetLanguage(value) }
                Toggle("Use \(UIDevice.current.localizedModel) microphone", isOn: $builtInMic)
                    .onChange(of: builtInMic) { _, value in
                        MobileSettings.preferBuiltInMic = value
                        session.setPreferBuiltInMic(value)
                    }
            }
            Section {
                Toggle("Smart transcription", isOn: $smartTranscription)
                    .onChange(of: smartTranscription) { _, value in settings.setSmartTranscription(value) }
                Toggle("Apply writing rules", isOn: $cleanupPass)
                    .onChange(of: cleanupPass) { _, value in settings.setSmartCleanupPass(value) }
                if cleanupPass { NavigationLink("Writing rules") { WritingRulesView(text: $instructions) } }
            }
            Section {
                Toggle("Better hearing in loud rooms", isOn: $noiseHandling)
                    .onChange(of: noiseHandling) { _, value in settings.setExperimentalNoiseHandling(value) }
            }
            if UIDevice.isPad {
                Section {
                    HardwareKeyboardSteps()
                } header: { SettingsSectionHeader("Hardware keyboard") }
            } else {
                Section {
                    Text("Settings › Action Button › Controls › VoiceiQ Dictate. Press it to start dictating in any app and again to stop. It also works from Control Center.")
                        .font(Theme.Fonts.callout())
                        .foregroundStyle(Theme.Colors.ink)
                    Button("Open Action Button settings", action: openActionButtonSettings)
                        .buttonStyle(.compactPrimary)
                } header: { SettingsSectionHeader("Action button") }
            }
        }
        .settingsPage(title: "Dictation")
        // A change made elsewhere (another screen, a migration) must not
        // leave a stale toggle here.
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            switch note.object as? String {
            case "smartTranscription": smartTranscription = settings.smartTranscriptionEnabled
            case "smartCleanupPass": cleanupPass = settings.smartCleanupPassEnabled
            case "customInstructions": instructions = settings.customInstructions
            case "experimentalNoiseHandling": noiseHandling = settings.experimentalNoiseHandling
            case "translationTargetLanguage": translationTarget = settings.translationTargetLanguage
            default: break
            }
        }
    }
}

/// Settings › Action Button. There is no public URL for it; `App-prefs:` is
/// the Settings app's own scheme. When iOS refuses it, VoiceiQ's page in
/// Settings opens instead.
private func openActionButtonSettings() {
    guard let url = URL(string: "App-prefs:ACTION_BUTTON") else { return }
    UIApplication.shared.open(url) { opened in
        if !opened, let fallback = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(fallback)
        }
    }
}

private struct WritingRulesView: View {
    @Binding var text: String

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 320)
                    .font(Theme.Fonts.callout())
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.s)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.field).fill(Theme.Colors.surfaceNested))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
                HStack {
                    Spacer()
                    Button("Restore defaults") {
                        SettingsStore().setCustomInstructions(nil)
                        text = SettingsStore().customInstructions
                    }
                    .buttonStyle(.compactSecondary)
                }
            }
        }
        .settingsPage(title: "Writing Rules", keyboard: true)
        .onDisappear { SettingsStore().setCustomInstructions(text) }
    }
}

private struct LanguageList: View {
    @Binding var selected: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(GeminiLanguages.supported.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        }) { language in
            Button {
                selected = language.name
                dismiss()
            } label: {
                HStack {
                    Text(language.name).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    if language.name == selected {
                        Image(systemName: "checkmark").foregroundStyle(Theme.Colors.accent)
                    }
                }
            }
            .listRowBackground(Theme.Colors.surface)
        }
        .searchable(text: $search)
        .settingsPage(title: "Translate To", keyboard: true)
    }
}

struct ReturnAppsView: View {
    @EnvironmentObject private var hostReturn: HostReturn

    var body: some View {
        List {
            if hostReturn.records.isEmpty {
                Text("Apps you dictate in appear here")
                    .font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.muted)
                    .listRowBackground(Theme.Colors.surface)
            }
            ForEach(hostReturn.records) { record in
                NavigationLink { ReturnAppDetail(record: record) } label: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(AppNames.displayName(for: record.bundleID)).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink)
                        Text(statusText(record)).font(Theme.Fonts.caption())
                            .foregroundStyle(record.lastReturn == .noScheme || record.lastReturn == .openFailed ? Theme.Colors.recording : Theme.Colors.muted)
                    }
                }
                .listRowBackground(Theme.Colors.surface)
            }
        }
        .settingsPage(title: "Return to Apps")
    }

    private func statusText(_ record: HostReturn.Record) -> String {
        if hostReturn.returnURL(for: record.bundleID) != nil, record.lastReturn != .openFailed { return "Returns automatically" }
        return (record.lastReturn ?? .noScheme).label
    }
}

private struct ReturnAppDetail: View {
    @EnvironmentObject private var hostReturn: HostReturn
    let record: HostReturn.Record
    @State private var custom = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Bundle ID") {
                    Text(record.bundleID).font(Theme.Fonts.code).textSelection(.enabled)
                }
                LabeledContent("Dictations", value: record.uses.formatted())
                if let url = KnownAppSchemes.returnURL(forHostId: record.bundleID) {
                    LabeledContent("Built-in link", value: url.absoluteString)
                }
            }
            Section {
                TextField("app-scheme://", text: $custom)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(saveOverride)
                HStack { Spacer(); Button("Save", action: saveOverride).buttonStyle(.compactPrimary) }
            } header: { SettingsSectionHeader("Custom return link") }
            Section {
                HStack {
                    Spacer()
                    Button("Forget") {
                        hostReturn.forget(record.bundleID)
                    }
                    .buttonStyle(.compactDestructive)
                    Spacer()
                }
            }
        }
        .settingsPage(title: AppNames.displayName(for: record.bundleID), keyboard: true)
        .onAppear { custom = hostReturn.overrides[record.bundleID] ?? "" }
    }

    private func saveOverride() { hostReturn.setOverride(custom, for: record.bundleID) }
}

struct PrivacyView: View {
    @State private var retentionDays = SettingsStore().audioRetentionDays
    @State private var provider = SettingsStore().preferredProvider

    private var destination: String { "\(provider.directName), with your key" }

    var body: some View {
        Form {
            Section {
                Picker("Keep audio recordings", selection: $retentionDays) {
                    Text("Never").tag(-1); Text("24 hours").tag(1); Text("7 days").tag(7)
                    Text("30 days").tag(30); Text("Forever").tag(0)
                }
                .onChange(of: retentionDays) { _, days in
                    SettingsStore().setAudioRetentionDays(days)
                    Task.detached(priority: .utility) { RetentionPolicy().purgeExpiredAudio() }
                }
            }
            Section {
                LabeledContent("Audio", value: destination)
                LabeledContent("Transcript text", value: "For writing rules, Ask and Translate")
                LabeledContent("Meeting notes", value: provider.displayName)
                LabeledContent("Dictionary terms", value: "Sent with the audio")
                LabeledContent("Dictionary", value: "Your iCloud, to sync")
                LabeledContent("Ask search queries", value: "TinyFish, if its key is saved")
                LabeledContent("What you type", value: "Never")
            } header: { SettingsSectionHeader("What leaves your \(UIDevice.current.localizedModel)") }
        }
        .settingsPage(title: "Privacy")
        .onAppear {
            provider = SettingsStore().preferredProvider
        }
    }
}

/// Session log and the selected provider's models, as in the Mac's
/// Advanced pane. The provider and keys are under Provider & Keys.
struct AdvancedView: View {
    private let settings = SettingsStore()
    private let provider = SettingsStore().preferredProvider
    @State private var endpoint = SettingsStore().endpointOverride ?? ""
    @State private var transcribeModel = SettingsStore().transcribeModelOverride ?? ""
    @State private var cleanupModel = SettingsStore().cleanupModelOverride ?? ""
    @State private var openAITranscribe = SettingsStore().openAITranscribeModelOverride ?? ""
    @State private var openAIWriting = SettingsStore().openAIWritingModelOverride ?? ""
    private let geminiDefaults = GeminiConfig()
    private let openAIDefaults = OpenAIConfig()

    /// The same test the client uses, so the warning matches what happens.
    private var endpointInvalid: Bool {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && SettingsStore.usableEndpointURL(trimmed) == nil
    }

    var body: some View {
        Form {
            Section {
                NavigationLink("Session log") { SessionLogView() }
            }
            if provider == .gemini {
                Section {
                    field("Endpoint", text: $endpoint, prompt: geminiDefaults.endpoint.absoluteString) { settings.setEndpointOverride($0) }
                    if endpointInvalid {
                        Text("Not a valid http(s) URL — the default endpoint is being used.")
                            .font(Theme.Fonts.footnote())
                            .foregroundStyle(Theme.Colors.recording)
                    }
                    field("Transcription", text: $transcribeModel, prompt: geminiDefaults.transcribeModel) { settings.setTranscribeModelOverride($0) }
                    field("Formatting", text: $cleanupModel, prompt: geminiDefaults.cleanupModel) { settings.setCleanupModelOverride($0) }
                } header: { SettingsSectionHeader("Gemini models") }
            } else {
                Section {
                    field("Transcription", text: $openAITranscribe, prompt: openAIDefaults.transcribeModel) { settings.setOpenAITranscribeModelOverride($0) }
                    field("Formatting", text: $openAIWriting, prompt: openAIDefaults.writingModel) { settings.setOpenAIWritingModelOverride($0) }
                } header: { SettingsSectionHeader("OpenAI models") }
            }
        }
        .settingsPage(title: "Advanced", keyboard: true)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, save: @escaping (String?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(label).font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
            TextField("", text: text, prompt: Text(prompt))
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(Theme.Fonts.code)
                .padding(Theme.Spacing.m)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.field).fill(Theme.Colors.surfaceNested))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
                .onChange(of: text.wrappedValue) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(trimmed.isEmpty ? nil : trimmed)
                }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

struct SettingsSectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { GroupLabel(text: text) }
}

extension View {
    func settingsPage(title: String, keyboard: Bool = false) -> some View {
        self
            .listStyle(.insetGrouped)
            .themedBackground()
            .listRowBackground(Theme.Colors.surface)
            .font(Theme.Fonts.body())
            .tint(Theme.Colors.accent)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(SettingsKeyboardModifier(enabled: keyboard))
    }
}

private struct SettingsKeyboardModifier: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.keyboardDismissable() } else { content }
    }
}


/// The keeper and background-start events from `SessionDiagnostics`.
private struct SessionLogView: View {
    @State private var text = SessionLogView.combined()

    /// The app's events, then the keyboard's.
    static func combined() -> String {
        let app = SessionDiagnostics.read()
        let keyboard = SharedStore.shared.keyboardLog.joined(separator: "\n")
        guard !keyboard.isEmpty else { return app }
        return app + (app.isEmpty ? "" : "\n\n") + "Keyboard\n" + keyboard
    }

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No events yet." : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.page)
        }
        .themedBackground()
        .navigationTitle("Session log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Copy") { UIPasteboard.general.string = text }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear") {
                    SessionDiagnostics.clear()
                    SharedStore.shared.clearKeyboardLog()
                    text = ""
                }
            }
        }
        .onAppear { text = SessionLogView.combined() }
    }
}
