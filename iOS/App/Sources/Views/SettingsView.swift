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
        case .keys: return "API Key"
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

    @MainActor @ViewBuilder var page: some View {
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
        case .keys where !DictationRoute.isAvailable:
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
    @State private var customRules = SettingsStore().customWritingRules
    @State private var calendar = SettingsStore().calendarForMeetings && CalendarMeetings.isAuthorized
    private var calendarDenied: Bool { !calendar && CalendarMeetings.isDenied }
    @State private var microphone = MobileSettings.microphoneChoice
    @State private var voiceIsolation = SettingsStore().voiceIsolation
    @State private var language = SettingsStore().dictationLanguage
    @State private var warmWindow = MobileSettings.warmWindow
    @State private var showsSessionActivity = MobileSettings.showsSessionActivity
    @ObservedObject private var cellularDownloads = CellularModelDownloads.shared

    var body: some View {
        Form {
            Section {
                SearchablePicker("Keep mic on after dictating", selection: $warmWindow,
                                 options: MobileSettings.WarmWindow.allCases.map { SearchOption(value: $0, name: $0.label) })
                .onChange(of: warmWindow) { _, value in
                    MobileSettings.warmWindow = value
                    session.warmWindowChanged()
                }
            } footer: {
                Text("While the mic is on, the next keyboard tap starts right away. After that, the tap opens VoiceiQ for a moment.")
            }
            Section {
                Toggle(UIDevice.isPad ? "Show on the Lock Screen" : "Show in the Dynamic Island", isOn: $showsSessionActivity)
                    .onChange(of: showsSessionActivity) { _, value in
                        MobileSettings.showsSessionActivity = value
                        session.refreshActivity()
                    }
            } footer: {
                Text("Stop or cancel a dictation while the keyboard is closed. The text waits for the VoiceiQ keyboard: it is typed when you return to the field as you left it, and Paste last puts it anywhere else.")
            }
            Section {
                Picker("Microphone", selection: $microphone) {
                    ForEach(MobileSettings.MicrophoneChoice.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: microphone) { _, value in MobileSettings.microphoneChoice = value }
                Toggle("Voice isolation", isOn: $voiceIsolation)
                    .onChange(of: voiceIsolation) { _, value in settings.setVoiceIsolation(value) }
            } footer: {
                Text("Automatic uses a wired headset's mic, or the car's in CarPlay, and otherwise your \(UIDevice.current.localizedModel)'s, so AirPods keep playing in full quality. \(UIDevice.current.localizedModel) always uses its own mic. Bluetooth also uses AirPods and car kits, which switch to call-quality sound while you dictate. Voice isolation turns down background noise while you dictate; it can switch Bluetooth headphones to call-quality sound too.")
            }
            Section {
                Picker("Language", selection: $language) {
                    ForEach(DictationLanguage.all) { Text($0.name).tag($0) }
                }
                .onChange(of: language) { _, value in settings.setDictationLanguage(value) }
            } footer: {
                Text("English is the default. STT-3.7 languages are transcribed as you speak; languages marked Universal-2 are transcribed after you stop and take a few seconds longer.")
            }
            SpeechSourceSection(device: UIDevice.current.localizedModel) { SettingsSectionHeader($0) }
            Section {
                Toggle("Use calendar for notes", isOn: $calendar)
                    .onChange(of: calendar) { _, enabled in
                        Task { calendar = await CalendarMeetings.connect(enabled) }
                    }
            } footer: {
                Text(calendarDenied
                     ? "Calendar access is off. Turn it on in Settings → Privacy & Security → Calendars → VoiceiQ."
                     : "Notes take the title of the calendar event you're in and the spelling of its invitees' names, and your next meeting shows at the top of Notes. Only events' titles, times, invitees and call links are used.")
            }
            Section {
                NavigationLink("Custom rules") { CustomRulesView(text: $customRules) }
            } footer: {
                Text("AssemblyAI transcribes each dictation as you speak, then a writing model on AssemblyAI writes it by the built-in writing rules and yours: it fixes grammar, applies spoken corrections and lays the text out. If the writing step can't run, the transcript goes in tidied. Spelling follows your \(UIDevice.current.localizedModel)'s region.")
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
        // A model download started on cellular data asks once, then runs on any network.
        .alert("Download on cellular data?", isPresented: Binding(
            get: { cellularDownloads.pending != nil },
            set: { if !$0 { cellularDownloads.pending = nil } }
        ), presenting: cellularDownloads.pending) { store in
            Button("Download") { cellularDownloads.confirm(store) }
            Button("Cancel", role: .cancel) {}
        } message: { store in
            Text("\(store.displayName) is a \(ByteCountFormatter.string(fromByteCount: store.downloadBytes, countStyle: .file)) download, and you're on cellular data.")
        }
        // A change made elsewhere (another screen, a migration) must not
        // leave a stale toggle here.
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            switch note.object as? String {
            case SettingsStore.customWritingRulesKey: customRules = settings.customWritingRules
            default: break
            }
        }
    }
}

/// Settings › Action Button. There is no public URL for it; `App-prefs:` is
/// the Settings app's own scheme. When iOS refuses it, VoiceiQ's page in
/// Settings opens instead.
@MainActor private func openActionButtonSettings() {
    guard let url = URL(string: "App-prefs:ACTION_BUTTON") else { return }
    UIApplication.shared.open(url) { opened in
        if !opened, let fallback = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(fallback)
        }
    }
}

private struct CustomRulesView: View {
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
            }
        }
        .settingsPage(title: "Custom Rules", keyboard: true)
        .onDisappear { SettingsStore().setCustomWritingRules(text) }
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
    @State private var transcriptRetentionDays = SettingsStore().transcriptRetentionDays

    var body: some View {
        Form {
            Section {
                SearchablePicker("Keep audio recordings", selection: $retentionDays, options: [
                    SearchOption(value: -1, name: "Never"), SearchOption(value: 1, name: "24 hours"),
                    SearchOption(value: 7, name: "7 days"), SearchOption(value: 30, name: "30 days"),
                    SearchOption(value: 0, name: "Forever"),
                ])
                .onChange(of: retentionDays) { _, days in
                    SettingsStore().setAudioRetentionDays(days)
                    Task.detached(priority: .utility) { RetentionPolicy().purge() }
                }
                SearchablePicker("Keep dictations", selection: $transcriptRetentionDays, options: [
                    SearchOption(value: -1, name: "Never"), SearchOption(value: 1, name: "24 hours"),
                    SearchOption(value: 7, name: "7 days"), SearchOption(value: 30, name: "30 days"),
                    SearchOption(value: 365, name: "1 year"), SearchOption(value: 0, name: "Forever"),
                ])
                .onChange(of: transcriptRetentionDays) { _, days in
                    SettingsStore().setTranscriptRetentionDays(days)
                    Task.detached(priority: .utility) { RetentionPolicy().purge() }
                }
            }
            Section {
                LocalAudioPrivacyRow(provider: "AssemblyAI", cloudDescription: "AssemblyAI, with your key")
                LabeledContent("Notes audio", value: "AssemblyAI, for the transcript and notes")
                LabeledContent("Dictionary terms", value: "With each dictation and notes")
                LabeledContent("Dictionary", value: "Your iCloud, to sync")
                LabeledContent("History", value: "Your iCloud, to sync final text")
                LabeledContent("Notes", value: "Your iCloud, to sync; not the audio")
                LabeledContent("What you type", value: "Never")
            } header: { SettingsSectionHeader("What leaves your \(UIDevice.current.localizedModel)") }
            GranolaImportSection { SettingsSectionHeader("Import meetings") }
        }
        .settingsPage(title: "Privacy")
    }
}

/// Session log and the writing model, as in the Mac's Advanced pane. The
/// key is under API Key.
struct AdvancedView: View {
    private let settings = SettingsStore()
    @State private var writingModel = SettingsStore().writingModelOverride ?? ""
    @State private var debugLog = DebugLog.isEnabled

    var body: some View {
        Form {
            Section {
                NavigationLink("Session log") { SessionLogView() }
            }
            Section {
                Toggle("Write a debug log", isOn: $debugLog)
                    .onChange(of: debugLog) { _, on in DebugLog.setEnabled(on) }
                NavigationLink("Debug log") { DebugLogView() }
            } footer: {
                Text("While this is on, VoiceiQ and its keyboard write down everything they do: dictation, transcription, meetings, settings changes, sync, network requests and errors. Share the file with a bug report. API keys and tokens are removed, and transcripts are never written. VoiceiQ keeps the last \(DebugLog.keepDays) days, up to \(DebugLog.maxTotalBytes / 1_000_000) MB, and deletes older entries on its own.")
            }
            Section {
                field("Writing model", text: $writingModel, prompt: AssemblyAIConfig.defaultWritingModel) { settings.setWritingModelOverride($0) }
            } header: { SettingsSectionHeader("AssemblyAI") } footer: {
                Text("The writing model on AssemblyAI's LLM Gateway writes each dictation's transcript by the writing rules, and writes notes and answers questions about them. Leave blank for the default.")
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
