import AppKit
import Combine
import ServiceManagement
import SwiftUI
import VoiceIQCore

/// The one app window — System Settings idiom: icon-tile sidebar, grouped detail.
/// Your data (History, Dictionary) on top; app configuration below.
@MainActor
final class MainWindowController: NSWindowController {
    private var hosting: NSHostingView<MainView>?
    private let model: MainWindowModel
    private var titleObserver: AnyCancellable?

    init(
        store: HistoryStore?,
        meetings: MeetingEngine,
        onRetry: @escaping (DictationRecord) -> Void,
        onDeleteAllHistory: @escaping () -> Void,
        agentRuns: AgentRunStore
    ) {
        model = MainWindowModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = model.selection.title
        window.titlebarAppearsTransparent = true
        window.center()
        super.init(window: window)
        // System Settings idiom: the titlebar names the selected pane (the app
        // name already anchors the sidebar header).
        titleObserver = model.$selection.sink { [weak window] section in
            window?.title = section.title
        }
        window.contentView = NSHostingView(rootView: MainView(
            model: model,
            store: store,
            meetings: meetings,
            onRetry: onRetry,
            onDeleteAllHistory: onDeleteAllHistory,
            agentRuns: agentRuns
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(section: MainSection) {
        model.selection = section
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum MainSection: String, CaseIterable, Identifiable {
    case history, meetings, agent, dictionary, cost
    case dictation, privacy, advanced
    case about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "History"
        case .meetings: return "Meetings"
        case .agent: return "Agent"
        case .dictionary: return "Dictionary"
        case .cost: return "Cost Analysis"
        case .dictation: return "Dictation"
        case .privacy: return "Privacy & Storage"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .meetings: return "person.2.wave.2.fill"
        case .agent: return "sparkles"
        case .dictionary: return "character.book.closed.fill"
        case .cost: return "dollarsign.circle.fill"
        case .dictation: return "waveform"
        case .privacy: return "hand.raised.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tileColor: Color {
        switch self {
        case .history: return VoiceIQUI.Colors.gBlue
        case .meetings: return Color(nsColor: .systemPurple)
        case .agent: return Color(nsColor: .systemYellow)
        case .dictionary: return Color(nsColor: .systemOrange)
        case .cost: return Color(nsColor: .systemMint)
        case .dictation: return Color(nsColor: .systemTeal)
        case .privacy: return Color(nsColor: .systemGreen)
        case .advanced: return Color(nsColor: .systemIndigo)
        case .about: return Color(nsColor: .systemPink)
        }
    }

    static let dataSections: [MainSection] = [.history, .meetings, .agent, .dictionary, .cost]
    static let settingsSections: [MainSection] = [.dictation, .privacy, .advanced, .about]
}

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var selection: MainSection = .history
}

private struct MainView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: MainWindowModel
    let store: HistoryStore?
    let meetings: MeetingEngine
    let onRetry: (DictationRecord) -> Void
    let onDeleteAllHistory: () -> Void
    let agentRuns: AgentRunStore

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            // Divider() stops at the safe-area top, so the line ended below the
            // transparent titlebar. A rectangle can extend into it.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .top)
            detail
        }
        .frame(minWidth: 880, minHeight: 580)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Loose PNGs, not an asset catalog: SwiftUI's Image(name) only
            // searches the catalog, so go through the bundle.
            Image(nsImage: Bundle.main.image(forResource: colorScheme == .dark ? "SidebarLogoDark" : "SidebarLogo") ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(height: 28)
                .accessibilityLabel("VoiceiQ")
                .padding(.horizontal, 14)
                .padding(.top, 20)
                .padding(.bottom, 12)
            ForEach(MainSection.dataSections) { section in
                SidebarRow(section: section, selected: model.selection == section) {
                    model.selection = section
                }
            }
            Text("Settings")
                .font(VoiceIQUI.TypeScale.labelSmall())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 4)
            ForEach(MainSection.settingsSections) { section in
                SidebarRow(section: section, selected: model.selection == section) {
                    model.selection = section
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 210)
        .background {
            Rectangle().fill(.thickMaterial)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.selection {
            case .history:
                if let store {
                    HistoryPane(store: store, usage: UsageMeter.store, onRetry: onRetry)
                } else {
                    ContentUnavailableView("History unavailable", systemImage: "clock.badge.exclamationmark")
                }
            case .meetings:
                MeetingsPane(engine: meetings, store: meetings.store)
            case .agent:
                AgentRunsPane(store: agentRuns)
            case .dictionary:
                DictionaryView()
            case .cost:
                if let usage = UsageMeter.store {
                    CostPane(store: usage)
                } else {
                    ContentUnavailableView("Cost tracking unavailable", systemImage: "dollarsign.circle")
                }
            case .dictation:
                DictationPane().formStyle(.grouped)
            case .privacy:
                PrivacyPane(onDeleteAllHistory: onDeleteAllHistory).formStyle(.grouped)
            case .advanced:
                AdvancedPane().formStyle(.grouped)
            case .about:
                AboutPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea(.container, edges: .top)
        }
    }
}

private struct SidebarRow: View {
    let section: MainSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(section.tileColor))
                Text(section.title)
                    .font(VoiceIQUI.TypeScale.body())
                    .foregroundStyle(selected ? VoiceIQUI.Colors.onPrimary : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: VoiceIQUI.Radius.small)
                    .fill(selected ? VoiceIQUI.Colors.primary
                          : hovering ? Color.primary.opacity(VoiceIQUI.StateLayer.hover)
                          : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Privacy & Storage

struct PrivacyPane: View {
    let onDeleteAllHistory: () -> Void
    private let settings = SettingsStore()
    @State private var route = SettingsStore().activeRoute
    private let source = SettingsStore().transcriptionSource
    private let maiHost = SettingsStore().maiTranscribeEndpoint?.hostName ?? ""

    private var owner: String { route.provider == .gemini ? "Google" : "OpenAI" }

    /// Where each request goes on the active route: the provider itself, or
    /// a gateway (with the gateway's key) that forwards it to the provider.
    /// With ElevenLabs or MAI Transcribe 2 transcribing, dictation audio goes
    /// only there.
    private var audioDestination: String {
        switch source {
        case .elevenLabs: return "Sent to ElevenLabs with your key"
        case .sarvam: return "Sent to Sarvam with your key"
        case .maiTranscribe: return "Sent to \(maiHost) with your key, then to Microsoft"
        case .provider:
            return route.gateway == .direct
                ? "Sent to \(owner) with your key"
                : "Sent to \(route.endpoint.hostName) with your key, then to \(owner)"
        }
    }

    /// Who writes meeting notes: the writing model, not the transcriber.
    private var notesWriter: String {
        settings.writingSource == .sarvam ? "Sarvam" : route.provider.displayName
    }

    private var recipients: String {
        var names = route.gateway == .direct ? [owner] : [route.endpoint.hostName, owner]
        switch source {
        case .provider: break
        case .elevenLabs: names.append("ElevenLabs")
        case .sarvam: names.append("Sarvam")
        case .maiTranscribe: names += [maiHost, "Microsoft"]
        }
        if settings.writingSource == .sarvam { names.append("Sarvam") }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique.count == 1 ? unique[0] : unique.dropLast().joined(separator: ", ") + " and " + unique.last!
    }
    @State private var retentionDays = SettingsStore().audioRetentionDays
    @State private var confirmingDelete = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Start VoiceiQ at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        // The failure-path revert below re-enters onChange with the
                        // inverted value — this guard stops the bounce from calling
                        // into SMAppService a second time.
                        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            Log.ui.error("launch-at-login toggle failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                Picker("Keep audio recordings", selection: $retentionDays) {
                    Text("Never (disables Retry)").tag(-1)
                    Text("24 hours").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Forever").tag(0)
                }
                .onChange(of: retentionDays) { _, days in
                    settings.setAudioRetentionDays(days)
                    // Off the main thread — the purge walks every recording folder
                    // and would hitch the pane with a large history (the 6h timer
                    // path already detaches).
                    Task.detached(priority: .utility) {
                        RetentionPolicy(audioRetentionDays: days).purgeExpiredAudio()
                    }
                }
            } footer: {
                Text("Transcripts stay in History until you delete them.")
            }

            Section {
                LabeledContent("Audio") { Text(audioDestination) }
                LabeledContent("Transcript text") { Text("Only if writing rules are on — otherwise it never leaves") }
                LabeledContent("Meeting audio") { Text("Only if call recording is on; notes are made by \(notesWriter)") }
                LabeledContent("Dictionary terms") { Text("Sent with the audio, so names are spelled right as you speak") }
                LabeledContent("Dictionary") { Text("Synced to your iPhone through your iCloud account") }
                LabeledContent("Screen snapshots") { Text("Only if screen context is on; sent with the audio, never stored") }
                LabeledContent("Ask Anything search") { Text("Only if a TinyFish key is saved; the search query goes to TinyFish") }
                LabeledContent("Everything else") { Text("Never leaves this Mac") }
            } header: {
                Text("What leaves your Mac")
            } footer: {
                Text("No middleman server, no account, no analytics, no keystroke logging. Only \(recipients), plus TinyFish when you add its key, and Frankfurter for the day's rupee rate (a date range at most, never a call).")
            }

            Section {
                Button("Delete All History…", role: .destructive) {
                    confirmingDelete = true
                }
                .confirmationDialog(
                    "Delete all dictation history? Audio and transcripts will be removed from this Mac.",
                    isPresented: $confirmingDelete
                ) {
                    Button("Delete Everything", role: .destructive) { onDeleteAllHistory() }
                }
            }
        }
        // Login-item state lives in macOS, not in our defaults, so it can change
        // with the app running — System Settings › General › Login Items turns it
        // off without telling us. Re-reading on appear covers reopening the window.
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            route = settings.activeRoute
        }
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    private let settings = SettingsStore()
    /// Placeholders derive from the REAL defaults — a hardcoded string went
    /// stale the day the preview model was retired (dogfood).
    private static let defaultConfig = GeminiConfig()
    @State private var apiKey = ""
    @State private var keyStatus: KeyStatus = KeychainStore.loadAPIKey() == nil ? .missing : .stored
    @State private var endpoint = SettingsStore().endpointOverride ?? ""
    @State private var transcribeModel = SettingsStore().transcribeModelOverride ?? ""
    @State private var cleanupModel = SettingsStore().cleanupModelOverride ?? ""

    enum KeyStatus { case missing, stored, validating, valid, invalid, saveFailed, savedOffline }

    private var hasStoredKey: Bool { keyStatus == .stored || keyStatus == .valid || keyStatus == .savedOffline }

    private var endpointLooksBroken: Bool {
        // Same predicate the effective config uses — the warning and reality
        // can never drift apart (SettingsStore.usableEndpointURL).
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && SettingsStore.usableEndpointURL(trimmed) == nil
    }
    @State private var legacyEndpoint = SettingsStore().usesLegacyTranscribeEndpoint
    @State private var provider = SettingsStore().preferredProvider

    var body: some View {
        Form {
            ProviderSection(provider: $provider)

            if provider == .gemini {
                geminiKeySection
            } else {
                GatewayKeySection(.openAI)
            }

            TranscriptionSourceSection(provider: provider)

            TinyFishKeySection()

            if provider == .gemini {
                geminiModelSections
            } else {
                OpenAIModelsSection()
            }

            ExperimentalGatewaysSection(provider: provider)
        }
        // Key saved elsewhere (onboarding, dev-file migration) while this pane is
        // open: refresh the badge — but never clobber in-flight feedback.
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == "apiKey", keyStatus == .missing || keyStatus == .stored {
                keyStatus = KeychainStore.loadAPIKey() == nil ? .missing : .stored
            }
        }
    }

    private var geminiKeySection: some View {
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
                if keyStatus == .invalid, KeychainStore.loadAPIKey() != nil {
                    Text("That key didn't work — your saved key is unchanged.")
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
                        Button("Remove Key…", role: .destructive) { removeKey() }
                    }
                    Spacer()
                    Link("Get a key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(VoiceIQUI.TypeScale.labelSmall())
                }
            } header: {
                Text("Gemini API key")
            } footer: {
                Text("Stored in your Mac's Keychain and only ever sent to Google.")
            }
    }

    @ViewBuilder
    private var geminiModelSections: some View {
            Section {
                LabeledContent("Endpoint") {
                    TextField("", text: $endpoint, prompt: Text(Self.defaultConfig.endpoint.absoluteString))
                        .labelsHidden()
                        .font(VoiceIQUI.TypeScale.code)
                        .multilineTextAlignment(.trailing)
                }
                .onChange(of: endpoint) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    settings.setEndpointOverride(trimmed.isEmpty ? nil : trimmed)
                }
                if endpointLooksBroken {
                    Text("Not a valid http(s) URL — the default endpoint is being used.")
                        .font(VoiceIQUI.TypeScale.labelSmall())
                        .foregroundStyle(VoiceIQUI.Colors.error)
                }
                LabeledContent("Transcription model") {
                    TextField("", text: $transcribeModel, prompt: Text(Self.defaultConfig.transcribeModel))
                        .labelsHidden()
                        .font(VoiceIQUI.TypeScale.code)
                        .multilineTextAlignment(.trailing)
                }
                .onChange(of: transcribeModel) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    settings.setTranscribeModelOverride(trimmed.isEmpty ? nil : trimmed)
                }
                LabeledContent("Formatting model") {
                    TextField("", text: $cleanupModel, prompt: Text(Self.defaultConfig.cleanupModel))
                        .labelsHidden()
                        .font(VoiceIQUI.TypeScale.code)
                        .multilineTextAlignment(.trailing)
                }
                .onChange(of: cleanupModel) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    settings.setCleanupModelOverride(trimmed.isEmpty ? nil : trimmed)
                }
            } header: {
                Text("Gemini models")
            } footer: {
                Text("Preview models get renamed — override here if a model 404s. Leave blank for defaults — every edit saves as you type.")
            }

            Section {
                Toggle("Use the previous transcription endpoint", isOn: $legacyEndpoint)
                    .onChange(of: legacyEndpoint) { _, enabled in
                        settings.setLegacyTranscribeEndpoint(enabled)
                    }
            } footer: {
                Text("VoiceiQ transcribes through Gemini's newer interactions endpoint, which is what makes Smart transcription possible. If it starts misbehaving, this switches back to the older one — transcription still works, but it will be word-for-word and Smart transcription will have no effect.")
            }
    }

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
            let client = GeminiClient(apiKey: { key })
            let check = await client.validateKey(endpoint: settings.geminiConfig.endpoint)
            // Same rule as onboarding: a key the server REJECTED never gets
            // saved, but a check we simply could not perform must not wall the
            // user out. The distinction now comes from the response itself
            // instead of a reachability probe that false-negatives.
            switch check {
            case .valid, .unreachable:
                if KeychainStore.saveAPIKey(key) {
                    apiKey = ""
                    keyStatus = check == .valid ? .valid : .savedOffline
                } else {
                    // A green check over a lost key is the worst possible lie.
                    keyStatus = .saveFailed
                }
            case .rejected:
                keyStatus = .invalid
            }
        }
    }

    private func removeKey() {
        KeychainStore.deleteAPIKey(notify: true)
        apiKey = ""
        keyStatus = .missing
    }
}

// MARK: - About

struct AboutPane: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "Version \(short) (\(Bundle.main.buildNumber))"
    }

    var body: some View {
        VStack(spacing: VoiceIQUI.Spacing.m) {
            Spacer()
            if let icon = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 4) {
                // The wordmark spelling, not the bundle display name.
                Text("VoiceiQ")
                    .font(VoiceIQUI.TypeScale.display())
                    .foregroundStyle(VoiceIQUI.Colors.onSurface)
                Text(version)
                    .font(VoiceIQUI.TypeScale.body())
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
            }
            UpdateControls()
                .padding(.top, VoiceIQUI.Spacing.m)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UpdateControls: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        VStack(spacing: VoiceIQUI.Spacing.m) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
            }
            .toggleStyle(.checkbox)
            .font(VoiceIQUI.TypeScale.body())
        }
    }
}
