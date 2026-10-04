import AppKit
import ApplicationServices
import AVFoundation
import Combine
import VoiceIQCore

/// App-side glue: EventTapEngine → DictationCoordinator → pill HUD + earcons +
/// status item. All HUD timing lives here (experience spec is canonical).
@MainActor
final class DictationController {
    let coordinator: DictationCoordinator
    /// Idle-time capture-graph prewarming — the key press pays only start().
    private let warmEngines = WarmEnginePool()
    private let engine = EventTapEngine(trigger: .default)
    private let globalShortcutEngine = GlobalShortcutEngine()
    private let hud = PillHUDController()
    private let earcons = EarconPlayer()
    private let outputMute = AudioOutputMute()
    private let transcriptionService: GeminiTranscriptionService
    private let historyStore: HistoryStore?
    private let learner = EditLearner()
    private let meetings: MeetingEngine
    private lazy var meetingHUD = MeetingHUDController(meetings: meetings, hud: hud)
    private let updatePill = UpdatePillController()
    private var recoveryScanner: RecoveryScanner?
    private var retryQueue: RetryQueue?
    private var mainWindow: MainWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var pendingAnswer: String?
    private lazy var agent = AgentController(panel: hud.model.agent)
    private let agentRuns = AgentRunStore()
    /// A coordinator session in `.agent` mode is recording or transcribing
    /// the next command.
    private var agentListening = false
    private var activationObservers: [NSObjectProtocol] = []
    /// The app in front before VoiceiQ was activated.
    private var previousFrontmostApp: NSRunningApplication?
    private var cancellables: Set<AnyCancellable> = []

    private var previousState: DictationState = .idle
    private var sessionStartedAt: Date?
    private var elapsedTimer: Timer?
    private var slowTimer: Timer?
    private var dismissTask: Task<Void, Never>?
    private var shortcutMode: DictationMode?

    var onStatusChange: ((String) -> Void)?
    var onStatusItemState: ((StatusItemController.VisualState) -> Void)?

    init() {
        KeychainStore.migrateDevKeyFileIfPresent()
        let client = GeminiClient(
            apiKey: { KeychainStore.loadAPIKey() },
            openRouterKey: { KeychainStore.loadOpenRouterKey() },
            vercelKey: { KeychainStore.loadVercelKey() },
            openAIKey: { KeychainStore.loadOpenAIKey() },
            elevenLabsKey: { KeychainStore.loadElevenLabsKey() },
            sarvamKey: { KeychainStore.loadSarvamKey() },
            openAIConfig: { SettingsStore().openAIConfig },
            writingSource: { SettingsStore().writingSource },
            route: { SettingsStore().activeRoute }
        )
        let service = GeminiTranscriptionService(client: client)
        transcriptionService = service
        historyStore = try? HistoryStore.standard()
        UsageMeter.store = try? UsageStore.standard()
        // Today's rupee rate for the rows to come, and the rate of their day
        // for rows that have none.
        if let usage = UsageMeter.store {
            Task.detached(priority: .utility) { await FXRates.refresh(); await usage.backfillFX() }
        }
        meetings = MeetingEngine(
            client: client,
            config: { SettingsStore().geminiConfig },
            summaryModel: SettingsStore().geminiConfig.cleanupModel,
            providers: { SettingsStore().meetingRoutes },
            transcriptionRoute: { SettingsStore().meetingTranscriptionRoute }
        )
        coordinator = DictationCoordinator(
            audioFactory: { [warmEngines] in warmEngines.take() },
            transcription: service,
            insertion: LearningInserter(learner: learner),
            contextProvider: {
                let app = NSWorkspace.shared.frontmostApplication
                // Wake Electron/Chromium a11y NOW, while the user is still
                // speaking — doing it after the transcript exists put a
                // cross-process stall between their words and seeing them.
                AccessibilityWaker.wakeIfNeeded(
                    bundleID: app?.bundleIdentifier, pid: app?.processIdentifier
                )
                let field = FocusedFieldCapture()
                if let pid = app?.processIdentifier {
                    Task.detached(priority: .userInitiated) { field.set(AXInserter.focusedTextField(pid: pid)) }
                }
                return DictationContext(
                    targetAppBundleID: app?.bundleIdentifier,
                    targetAppName: app?.localizedName,
                    targetPID: app?.processIdentifier,
                    focusedField: field
                )
            }
        )
    }

    private var needsOnboarding: Bool {
        // Completing the wizard is remembered. A permission that goes missing
        // later (macOS reset it, or a rebuilt unsigned binary lost its TCC
        // grant) is reported through the menu bar, not by re-running the
        // wizard on every launch.
        guard !SettingsStore().hasCompletedOnboarding else { return false }
        return !KeychainStore.hasModelKey
            || !AXIsProcessTrusted()
            || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
    }

    func start() {
        applyHotkeySettings()
        registerGlobalShortcuts()
        // Intents flow through one AsyncStream consumed sequentially — independent
        // Task hops have no ordering guarantee under load (audit L35).
        let (intentStream, continuation) = AsyncStream.makeStream(of: HotkeyIntent.self)
        engine.onIntent = { intent in
            continuation.yield(intent)
        }
        // Return often sends and clears the field (chat, email), so an edit
        // made just before it is read now rather than after the settle wait.
        engine.onReturnKeyDown = { [learner] in
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            learner.captureBeforeReturn(frontmostPID: pid)
        }
        Task { @MainActor [weak self] in
            for await intent in intentStream {
                guard let self else { break }
                // The dictation key also ends an Ask Anything or Translate
                // session, so the user has one key that always means "stop".
                if intent == .begin, self.shortcutMode != nil {
                    Log.hotkey.info("dictation key ends mode session")
                    self.coordinator.handle(.finalize)
                    self.shortcutMode = nil
                    self.engine.resetGrammar()
                    continue
                }
                let accepted = self.coordinator.handle(intent)
                if !accepted, intent == .begin {
                    // Refused begin: the grammar armed a phantom session, so
                    // snap it back or the next press would read as a stop. When
                    // the refusal is a session the pill started (dot click, menu
                    // item), the press is that session's stop.
                    self.engine.resetGrammar()
                    if case .recording = self.coordinator.state {
                        self.coordinator.handle(.finalize)
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(forName: .pillStopTapped, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.handle(.finalize)
            }
        }
        NotificationCenter.default.addObserver(forName: .pillDotTapped, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.startHandsFree()
            }
        }
        NotificationCenter.default.addObserver(forName: .pillAnswerDismissed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.setPill(self.restingPill(for: self.coordinator.state))
            }
        }
        NotificationCenter.default.addObserver(forName: .agentStopRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopAgent() }
        }
        NotificationCenter.default.addObserver(forName: .agentListenTapped, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.agentShortcutPressed() }
        }
        // Settings must take effect the moment they're flipped — not on the next
        // unrelated pill transition (dogfood: resting-dot toggle "didn't work").
        NotificationCenter.default.addObserver(forName: .gtSettingDidChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                self?.applySettingChange(key: note.object as? String)
            }
        }
        learner.onLearned = { [weak self] entries in
            let terms = entries.map(\.term).joined(separator: ", ")
            self?.showBackgroundNotice("Learned \(terms) — see Dictionary", for: 4.0, sound: nil)
        }
        meetings.onNotice = { [weak self] message in
            self?.showBackgroundNotice(message, for: 4.0, sound: nil)
        }
        meetings.onNotesReady = { [weak self] in
            guard let self else { return }
            // Notes finish in the background, so they can land while another
            // offer or answer is on the pill; the check must not replace it.
            switch self.hud.model.state {
            case .meetingPrompt, .answer, .updateReady: return
            default: break
            }
            switch self.coordinator.state {
            case .idle, .done, .cancelled, .failed: self.showSuccessBadge(words: nil)
            default: break
            }
        }
        meetingHUD.setPill = { [weak self] state in self?.setPill(state) }
        meetingHUD.dictationIsActive = { [weak self] in
            guard let self else { return false }
            switch self.coordinator.state {
            case .idle, .done, .cancelled, .failed: return false
            default: return true
            }
        }
        meetingHUD.restingPill = { [weak self] in
            self.map { $0.restingPill(for: $0.coordinator.state) } ?? .idleDot
        }
        meetingHUD.notice = { [weak self] message in
            self?.showBackgroundNotice(message, for: 4.0, sound: nil)
        }
        meetingHUD.bind()
        meetings.autoDetect = SettingsStore().meetingDetectionEnabled

        updatePill.setPill = { [weak self] state in self?.setPill(state) }
        updatePill.currentPill = { [weak self] in self?.hud.model.state ?? .hidden }
        updatePill.restingPill = { [weak self] in
            self.map { $0.restingPill(for: $0.coordinator.state) } ?? .idleDot
        }
        updatePill.sessionIsActive = { [weak self] in self?.isInUse ?? false }
        updatePill.notice = { [weak self] message in
            self?.showBackgroundNotice(message, for: 4.0, sound: nil)
        }
        updatePill.bind()

        // A prewarmed graph is bound to the device it was built for — rebuild it
        // the moment the input moves, so the first dictation on new AirPods is
        // as fast as the last one on the old mic.
        AudioInputDevices.startMonitoringDefaultChanges()
        AudioInputDevices.startMonitoringDeviceChanges()
        rememberCurrentInputDevices()
        applyPreferredInputDevice()
        NotificationCenter.default.addObserver(forName: .voiceIQDefaultInputChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                Log.audio.info("default input changed — refreshing the warm capture graph")
                self?.warmEngines.refresh()
            }
        }
        NotificationCenter.default.addObserver(forName: .voiceIQInputDevicesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleInputDevicesChanged() }
        }

        coordinator.onAnswerReady = { [weak self] answer in
            guard let self else { return }
            if self.agentListening {
                self.agent.submit(command: answer)
            } else {
                self.pendingAnswer = answer
            }
        }
        agent.overlay = hud
        agent.onSessionChange = { [agentRuns] session in
            guard session.commandCount > 0 else { return }
            do { try agentRuns.save(session) } catch {
                Log.history.error("agent run save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        activationObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                Task { @MainActor in self?.previousFrontmostApp = app }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handBackActivation() }
            },
        ]

        bind()
        startHistoryServices()

        // F15: finalize gracefully when the Mac sleeps mid-recording (audit L1).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .recording = self.coordinator.state {
                    Log.session.info("system sleeping — finalizing active dictation")
                    self.coordinator.handle(.finalize)
                }
            }
        }

        // Retention shouldn't depend on relaunches (audit L11): purge every 6h.
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task.detached(priority: .utility) {
                RetentionPolicy().purgeExpiredAudio()
            }
        }

        if needsOnboarding {
            presentOnboarding()
            reportSetupIncomplete() // the menu must be truthful even mid-wizard
        } else {
            activateEngine()
        }

        if FnUsageAdvisor.karabinerIsPresent() {
            Log.hotkey.warning("Karabiner-Elements detected — fn capture may conflict")
        }
    }

    /// True once engine.start() has succeeded — status-line rewrites must never
    /// paint "Ready" over an unstarted engine's attention message.
    private var engineActive = false

    private func activateEngine() {
        if engine.start() {
            _ = globalShortcutEngine.start()
            engineActive = true
            if !KeychainStore.hasModelKey {
                // New-user path: dictation can't work yet — say exactly where to go.
                onStatusChange?("Add your API key in Settings → Advanced")
                onStatusItemState?(.attention)
            } else {
                onStatusChange?("Ready — press \(SettingsStore().dictationTrigger.displayName) to dictate")
                // Clear a lingering attention icon (auth failure, missing key).
                onStatusItemState?(.idle)
                warmEngines.prewarmNext()
            }
            // The model starts as .idleDot and the idle → hidden mapping
            // arrives through bind() on a later main-queue hop. Paint the
            // resting state first or the dot flashes for a frame at launch.
            setPill(restingPill(for: coordinator.state))
            hud.show()
            // Only now does a pill exist to paint into. Called here rather than in
            // start() because the onboarding path never reaches activateEngine()
            // until permissions are granted — and the migrating cohort is exactly
            // the cohort that gets re-prompted.
            announceSmartRestoredIfNeeded()
            updatePill.announceIfJustUpdated()
            // Idle time, not insert time: Sauce's one-time keyboard-layout
            // lookup otherwise lands between transcript-ready and ⌘V.
            Task { @MainActor in PasteInserter.warmKeyboardLayout() }
        } else {
            onStatusChange?("Grant Accessibility to enable the dictation key")
            onStatusItemState?(.attention)
        }
    }

    private func presentOnboarding() {
        guard onboardingWindow == nil else {
            onboardingWindow?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = OnboardingWindowController(
            onFinished: { [weak self] in
                guard let self else { return }
                SettingsStore().setHasCompletedOnboarding(true)
                self.onboardingWindow?.close()
            },
            onClosed: { [weak self] in
                guard let self else { return }
                self.onboardingWindow = nil
                // Unconditional: activateEngine handles every sub-state honestly
                // (no key → attention + Settings pointer; no AX → attention +
                // grant message). The old guard left the app INERT with the menu
                // stuck on "Starting up…" (production pass 2).
                self.activateEngine()
                if self.needsOnboarding {
                    self.reportSetupIncomplete()
                }
            },
            // Try-It's reveal card reads the freshest record to show what the
            // cleanup pass did to the user's own words.
            latestRecord: { [historyStore] in historyStore?.records(limit: 1).first }
        )
        onboardingWindow = window
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Names the first missing prerequisite — never leaves the construction
    /// placeholder ("Starting up…") in the menu bar.
    private func reportSetupIncomplete() {
        if !AXIsProcessTrusted() {
            onStatusChange?("Grant Accessibility to enable the dictation key")
        } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            onStatusChange?("Allow microphone access in System Settings to dictate")
        } else {
            onStatusChange?("Add your API key in Settings → Advanced")
        }
        onStatusItemState?(.attention)
    }

    func applyHotkeySettings() {
        let settings = SettingsStore()
        engine.setTrigger(settings.dictationTrigger)
    }

    private func applySettingChange(key: String?) {
        switch key {
        case "showIdleIndicator":
            // Re-apply only when resting — setPill maps idleDot ⇄ hidden by the
            // setting; never touch an active session's pill.
            if hud.model.state == .idleDot || hud.model.state == .hidden {
                setPill(.idleDot)
            }
        case "dictationTrigger":
            applyHotkeySettings()
            // The menu-bar status line names the key — keep it truthful, but
            // never overwrite an attention message ("Grant Accessibility…").
            if engineActive, KeychainStore.hasModelKey {
                onStatusChange?("Ready — press \(SettingsStore().dictationTrigger.displayName) to dictate")
            }
        case "meetingDetection":
            meetings.autoDetect = SettingsStore().meetingDetectionEnabled
        case "preferredInputDeviceUID":
            applyPreferredInputDevice()
        case "accessibility":
            // Granted mid-onboarding: wake the engine so the Try-It screen works.
            if !engineActive {
                activateEngine()
            }
        case "apiKey", "openRouterKey", "vercelKey", "openAIKey", "modelProvider":
            if KeychainStore.hasModelKey {
                // Covers the "I'll add it later" onboarding path, where the
                // engine was never started: a key arriving in Settings must
                // bring the whole app to life, not just flip a badge.
                // engine.start() is reentrant; hud.show() is idempotent.
                activateEngine()
            } else {
                onStatusChange?("Add your API key in Settings → Advanced")
                onStatusItemState?(.attention)
            }
        default:
            break
        }
    }

    // MARK: - History, recovery, retry queue

    /// With "Copy recovered dictations" on, puts the recovered text on the
    /// clipboard. True only when it is there, so the pill never claims a copy
    /// that did not happen; the History row is written either way.
    private static func copyRecovered(_ texts: [String]) -> Bool {
        guard SettingsStore().copyRecoveredToClipboard,
              let text = RecoveryNotice.clipboardText(texts) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            Log.history.error("Recovered dictation could not be copied to the clipboard")
            return false
        }
        return true
    }

    private func startHistoryServices() {
        guard let historyStore else {
            Log.history.error("HistoryStore unavailable — history features disabled")
            return
        }
        coordinator.onSessionDiscard = { id in
            historyStore.delete(id: id.uuidString, removeFolder: false)
        }
        coordinator.onSessionUpdate = { meta, folder in
            historyStore.upsert(meta: meta, folder: folder)
            // "Never keep audio": purge the moment a transcript exists (audit #2).
            if SettingsStore().audioRetentionDays < 0, meta.rawTranscript != nil || meta.status == .silent {
                for audio in [FileLayout.audioCAF(in: folder), FileLayout.audioFLAC(in: folder)] {
                    try? FileManager.default.removeItem(at: audio)
                }
            }
        }

        let scanner = RecoveryScanner(store: historyStore, transcription: transcriptionService)
        scanner.onRecovered = { [weak self] text in
            let copied = Self.copyRecovered([text])
            self?.showBackgroundNotice(RecoveryNotice.message(for: .relaunch, copied: copied), for: 4.0, sound: .success)
        }
        recoveryScanner = scanner

        let queue = RetryQueue(store: historyStore, transcription: transcriptionService)
        queue.onDrained = { [weak self] texts in
            let copied = Self.copyRecovered(texts)
            let message = RecoveryNotice.message(for: .queue(count: texts.count), copied: copied)
            self?.showBackgroundNotice(message, for: 4.0, sound: .success)
        }
        queue.onDrainBlocked = { [weak self] error in
            let message: String
            if case .auth = error {
                message = "Queued dictations are waiting — fix your API key in Settings → Advanced"
            } else if SettingsStore().transcriptionSource == .elevenLabs {
                message = "ElevenLabs credits are used up — queued dictations will retry once you add credits"
            } else {
                message = "Daily quota reached — queued dictations will retry later"
            }
            self?.showBackgroundNotice(message, for: 5.0, sound: nil)
        }
        retryQueue = queue

        // Both walk EVERY recording folder and read every meta.json. On the main
        // actor that grows without bound as history grows — and the hotkey is
        // already armed, so a key press would queue behind it.
        Task {
            await scanner.scanAndRecover()
            queue.start()
            Task.detached(priority: .utility) {
                RetentionPolicy().purgeExpiredAudio()
            }
        }
    }

    func openHistory() {
        openMainWindow(section: .history)
    }

    func openSettings(section: String? = nil) {
        openMainWindow(section: section.flatMap(MainSection.init(rawValue:)) ?? .dictation)
    }

    func openDictionary() {
        openMainWindow(section: .dictionary)
    }

    /// voiceiq://onboarding — re-run setup on demand (also drives headless UI checks).
    func presentOnboardingManually() {
        presentOnboarding()
    }

    private func openMainWindow(section: MainSection) {
        if mainWindow == nil {
            mainWindow = MainWindowController(
                store: historyStore,
                meetings: meetings,
                onRetry: { [weak self] record in
                    Task { @MainActor [weak self] in
                        guard let self, let queue = self.retryQueue else { return }
                        // Seconds pass before the new text arrives; say it started.
                        self.showNotice("Transcribing again…", for: 30.0, sound: nil)
                        switch await queue.retrySingle(record) {
                        case .stillOffline:
                            self.showNotice("Still offline — will retry automatically when you're back", for: 4.0, sound: nil)
                        case .rateLimited(let retryIn):
                            self.showNotice("\(SettingsStore().activeRoute.provider.displayName) is rate limited — retrying in \(Int(retryIn.rounded()))s", for: 4.0, sound: nil)
                        case .busy:
                            self.showNotice("Already retrying your queued dictations…", for: 2.5, sound: nil)
                        case .failed:
                            self.showNotice(record.rawTranscript != nil
                                            ? "Couldn't transcribe it again — the earlier text is kept"
                                            : "Retry didn't work — the row has the details", for: 3.5, sound: nil)
                        case .recovered(let text):
                            let copied = Self.copyRecovered([text])
                            self.showNotice(RecoveryNotice.message(for: .retry, copied: copied), for: 3.5, sound: .success)
                        case .alreadyDone:
                            self.showNotice("Couldn't find this recording", for: 3.0, sound: nil)
                        case .blocked:
                            break // onDrainBlocked shows the notice
                        }
                    }
                },
                onDeleteAllHistory: { [weak self] in
                    guard let self else { return }
                    if let store = self.historyStore {
                        store.deleteAll(
                            removeFolders: true,
                            sparing: self.coordinator.activeSessionFolder
                        )
                    } else {
                        // No DB handle (quarantined at launch) must not turn the
                        // destructive button into a silent no-op — the folders
                        // are the actual data; sweep them directly.
                        let folders = (try? FileManager.default.contentsOfDirectory(
                            at: FileLayout.recordingsRoot, includingPropertiesForKeys: nil
                        )) ?? []
                        let active = self.coordinator.activeSessionFolder?.standardizedFileURL
                        for folder in folders where folder.hasDirectoryPath && folder.standardizedFileURL != active {
                            try? FileManager.default.removeItem(at: folder)
                        }
                    }
                    // Wiping history also forgets the paste-last buffer.
                    self.coordinator.clearLastResult()
                },
                agentRuns: agentRuns
            )
        }
        mainWindow?.show(section: section)
    }

    /// UI-initiated hands-free session (idle-dot click, menu item). The hotkey
    /// grammar stays idle for these; the pill's stop button ends them, and so
    /// does a press of the dictation key (its refused begin becomes the stop).
    func startHandsFree() {
        // No session without a visible pill and a working stop path: before the
        // engine is active there is no pill surface and no fn stop gesture — a
        // hot mic with zero UI (production pass 2).
        guard engineActive else {
            if needsOnboarding {
                presentOnboarding()
            } else {
                NSSound.beep()
            }
            return
        }
        coordinator.handle(.begin)
        coordinator.handle(.lockIn)
    }

    /// Cmd-Q mid-recording must not strand the words until next launch —
    /// finalize synchronously enough that the CAF is complete and meta says
    /// .recorded; next launch's RecoveryScanner picks the transcript up.
    func prepareForTermination() {
        outputMute.unmute()
        if case .recording = coordinator.state {
            Log.session.info("terminating — finalizing active dictation")
            coordinator.handle(.finalize)
        }
    }

    private func registerGlobalShortcuts() {
        globalShortcutEngine.onKeyDown = { [weak self] action in
            guard let self else { return }
            switch action {
            case .pasteLastTranscript:
                break
            case .askAnything:
                self.toggleModeShortcut(.askAnything(selectedText: nil))
            case .translate:
                self.toggleModeShortcut(
                    .translate(target: SettingsStore().translationTargetLanguage)
                )
            case .meetingToggle:
                self.meetingHUD.toggle()
            case .agent:
                self.agentShortcutPressed()
            }
        }
        globalShortcutEngine.onKeyUp = { [weak self] action in
            guard let self else { return }
            switch action {
            case .pasteLastTranscript:
                Log.hotkey.info("paste-last shortcut fired")
                self.pasteLastTranscript()
            case .askAnything, .translate, .meetingToggle, .agent:
                break
            }
        }
    }

    // MARK: - Agent mode

    /// First press opens the session and listens. While listening, a press
    /// ends the command. While the panel is open and idle, a press listens
    /// again. The panel closes only from its Stop button.
    private func agentShortcutPressed() {
        guard SettingsStore().agentModeEnabled else { return }
        Log.hotkey.info("agent shortcut pressed")
        if agentListening {
            coordinator.handle(.finalize)
            return
        }
        if !agent.isOpen {
            guard coordinator.state == .idle || coordinator.state.isTerminal, shortcutMode == nil else { return }
            openAgentPanel()
        }
        guard agent.canRun, !agent.isBusy else { return }
        startAgentListening()
    }

    #if DEBUG
    /// voiceiq://agent[/<command>]. Nil presses the shortcut; text skips the
    /// microphone and goes straight to the loop.
    func debugAgent(command: String?) {
        guard let command else { return agentShortcutPressed() }
        guard SettingsStore().agentModeEnabled else { return }
        if !agent.isOpen { openAgentPanel() }
        guard agent.canRun, !agent.isBusy else { return }
        agent.submit(command: command)
    }
    #endif

    /// The pill panel is normally ordered in by activateEngine(); hud.show()
    /// is idempotent, so calling it here also covers an engine that never
    /// started (permissions still missing) and keeps the transcript visible.
    private func openAgentPanel() {
        hud.repositionToActiveScreen()
        agent.start()
        setPill(.agent)
        hud.show()
    }

    /// The agent panel must not take focus from the app the agent works in.
    /// A click on the panel's buttons can still activate VoiceiQ on some
    /// systems; when that happens with no regular window open, give the
    /// activation back to the app behind the panel.
    private func handBackActivation() {
        guard agent.isOpen else { return }
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let app = previousFrontmostApp.flatMap { $0.isTerminated ? nil : $0 }
            ?? NativeExecutor.topmostForeignWindowOwner().flatMap { NSRunningApplication(processIdentifier: $0) }
        guard let app else {
            Log.hotkey.info("agent panel activated VoiceiQ; no app to hand focus back to")
            return
        }
        Log.hotkey.info("agent panel activated VoiceiQ; handing focus back to \(app.localizedName ?? "app", privacy: .public)")
        app.activate()
    }

    private func startAgentListening() {
        guard coordinator.state == .idle || coordinator.state.isTerminal else { return }
        guard coordinator.handle(.begin, mode: .agent) else { return }
        coordinator.handle(.lockIn)
        shortcutMode = .agent
        agentListening = true
    }

    private func stopAgent() {
        if agentListening {
            coordinator.handle(.cancel)
            agentListening = false
        }
        agent.stop()
        setPill(restingPill(for: coordinator.state))
        if !engineActive { hud.hide() }
    }

    /// One press starts a hands-free Ask Anything or Translate session, the
    /// next press of the same shortcut ends it. Release does nothing.
    private func toggleModeShortcut(_ initialMode: DictationMode) {
        Log.hotkey.info("mode shortcut pressed")
        if shortcutMode != nil {
            coordinator.handle(.finalize)
            shortcutMode = nil
            return
        }
        guard coordinator.state == .idle || coordinator.state.isTerminal else { return }
        let mode: DictationMode
        var settable = false
        switch initialMode {
        case .askAnything:
            let selection = SelectedTextCapture.capture()
            mode = .askAnything(selectedText: selection.text)
            settable = selection.isSettable
        case .translate:
            mode = .translate(target: SettingsStore().translationTargetLanguage)
        case .dictate:
            mode = .dictate
        case .agent:
            mode = .agent
        }
        guard coordinator.handle(.begin, mode: mode, selectedTextIsSettable: settable) else { return }
        coordinator.handle(.lockIn)
        shortcutMode = mode
    }

    private func applyPreferredInputDevice() {
        guard let uid = SettingsStore().preferredInputDeviceUID,
              let device = AudioInputDevices.list().first(where: { $0.uid == uid }) else { return }
        _ = AudioInputDevices.setDefault(id: device.id)
    }

    private func handleInputDevicesChanged() {
        let devices = AudioInputDevices.list()
        let defaults = UserDefaults.standard
        let key = "seenInputDeviceUIDs"
        var seen = Set(defaults.stringArray(forKey: key) ?? [])
        if SettingsStore().preferredInputDeviceUID == nil,
           let device = devices.first(where: { !seen.contains($0.uid) }) {
            showNotice("New microphone detected: \(device.name)", for: 4.0, sound: nil)
        }
        seen.formUnion(devices.map(\.uid))
        defaults.set(Array(seen), forKey: key)
        applyPreferredInputDevice()
    }

    private func rememberCurrentInputDevices() {
        let defaults = UserDefaults.standard
        let key = "seenInputDeviceUIDs"
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(AudioInputDevices.list().map(\.uid), forKey: key)
    }

    func pasteLastTranscript() {
        guard let text = coordinator.lastResult else {
            // A silent no-op reads as a broken menu item.
            showNotice("Nothing to paste yet — dictate something first", for: 2.5, sound: nil)
            return
        }
        Task { @MainActor [weak self] in
            let app = NSWorkspace.shared.frontmostApplication
            let context = DictationContext(
                targetAppBundleID: app?.bundleIdentifier,
                targetAppName: app?.localizedName,
                targetPID: app?.processIdentifier
            )
            switch await InsertionCoordinator().insert(text, context: context) {
            case .inserted:
                break
            case .fellBackToClipboard, .frontmostChanged:
                self?.showNotice("Copied — press ⌘V to paste", for: 3.0, sound: nil)
            case .blockedSecureField:
                self?.showNotice("Secure input is on — can't paste here", for: 3.0, sound: nil)
            }
        }
    }

    // MARK: - State → HUD/earcons (frame-synced: sound fires on the same tick)

    private func bind() {
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.transition(to: state)
            }
            .store(in: &cancellables)

        coordinator.$micLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.hud.model.level.value = level
            }
            .store(in: &cancellables)

        coordinator.$coachingHint
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hint in
                self?.showNotice(hint, for: 3.0, sound: nil)
            }
            .store(in: &cancellables)
    }

    private func transition(to state: DictationState) {
        if case .recording = state {
            if SettingsStore().muteOtherAudioWhileDictating,
               !meetingIsRecording {
                outputMute.mute()
            }
        } else {
            outputMute.unmute()
        }
        // Only terminal states clear the mode. The coordinator re-publishes
        // `.idle` at the start of every begin, and this sink delivers it after
        // toggleModeShortcut already set shortcutMode — clearing on `.idle`
        // wiped the mode and let the dictation key fall through to "begin ignored".
        if state.isTerminal {
            shortcutMode = nil
            agentListening = false
        }
        defer { previousState = state }
        dismissTask?.cancel()

        // Esc must reach us even when the grammar is idle: in-flight transcription
        // and UI-started hands-free are "externally active" (audit L8/L13).
        // NOT .inserting: cancel is rejected there by design (the text exists),
        // so consuming Esc would just eat the user's keystroke for ~1s.
        switch state {
        case .finalizing, .transcribing, .recording:
            engine.setExternalSessionActive(true)
        default:
            engine.setExternalSessionActive(false)
        }

        // Background notices deferred during an active session flush once it ends.
        if case .idle = state { flushPendingNotice() }
        if state.isTerminal { flushPendingNotice() }

        switch state {
        case .idle:
            setPill(restingPill(for: .idle))
            onStatusItemState?(.idle)
            meetingHUD.dictationBecameIdle()

        case .warming:
            sessionStartedAt = Date()
            earcons.play(.start)
            hud.repositionToActiveScreen() // follow the dictation display (audit L14)
            setPill(.listening(locked: false))
            startElapsedTimer()
            onStatusItemState?(.listening)

        case .recording(let locked):
            if case .recording(false) = previousState, locked {
                earcons.play(.lock)
            }
            setPill(.listening(locked: locked))
            onStatusItemState?(.listening)

        case .finalizing:
            earcons.play(.stop)
            stopElapsedTimer()
            setPill(.processing)
            armSlowTimer()
            onStatusItemState?(.processing)

        case .transcribing, .inserting:
            setPill(.processing)
            onStatusItemState?(.processing)

        case .done(let outcome):
            clearSlowTimer()
            onStatusItemState?(.idle)
            handleOutcome(outcome)

        case .cancelled:
            clearSlowTimer()
            stopElapsedTimer()
            onStatusItemState?(.idle)
            // Short accidental taps stay silent; deliberate cancels get the soft damp.
            if let startedAt = sessionStartedAt, Date().timeIntervalSince(startedAt) > 0.5 {
                earcons.play(.cancel)
            }
            setPill(restingPill(for: .idle))

        case .failed(let failure):
            clearSlowTimer()
            stopElapsedTimer()
            earcons.play(.error)
            // Key/permission problems persist beyond the toast — the menu bar
            // icon carries the attention state until resolved (audit L12).
            onStatusItemState?(failure == .auth || failure == .modelAccess ? .attention : .idle)
            if failure == .rateLimited {
                // The copy promises a retry; the path monitor never fires for a
                // throttle, so the queue needs a timed one.
                retryQueue?.scheduleDrain(after: TimeoutPolicy.rateLimitWait)
            }
            showError(coordinator.modeFailureMessage ?? Self.copy(for: failure))
        }
    }

    /// Anything an update relaunch would cut short: a dictation or mode session,
    /// a meeting (detected, recording, or making notes), or an answer on screen.
    private var isInUse: Bool {
        switch coordinator.state {
        case .idle, .done, .cancelled, .failed: break
        default: return true
        }
        guard meetings.processing.isEmpty else { return true }
        switch meetings.phase {
        case .idle, .failed: break
        default: return true
        }
        switch hud.model.state {
        case .answer, .agent, .meetingPrompt: return true
        default: return shortcutMode != nil
        }
    }

    private var meetingIsRecording: Bool {
        if case .recording = meetings.phase { return true }
        return false
    }

    private func handleOutcome(_ outcome: DictationOutcome) {
        switch outcome {
        case .inserted:
            if let answer = pendingAnswer {
                pendingAnswer = nil
                setPill(.answer(answer))
                return
            }
            // An agent command is handed to the loop; the panel shows it.
            if agent.isOpen { return }
            showSuccessBadge(words: coordinator.lastResult.map { $0.split(separator: " ").count })
        case .copiedToClipboard:
            earcons.play(.success)
            showNotice("Copied — press ⌘V to paste", for: 4.0, sound: nil)
        case .awaitingChip:
            showNotice("You switched apps — press ⌘V to paste", for: 5.0, sound: nil)
        case .heldForSecureField:
            showNotice("Secure input is on — saved to History", for: 4.0, sound: nil)
        case .queuedForRetry:
            showNotice("You're offline — saved to History", for: 4.0, sound: nil)
        case .silent:
            consecutiveSilentSessions += 1
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                showNotice("Microphone access is off — re-enable it in System Settings → Privacy & Security", for: 5.0, sound: nil)
                onStatusItemState?(.attention)
            } else if coordinator.lastSilenceReason == .tooNoisy {
                // A loud room with nothing above it. The recording is kept, so say
                // where it went — this is the one no-speech case with a Retry.
                showNotice("Too noisy to make out speech — saved to History", for: 4.0, sound: nil)
            } else if consecutiveSilentSessions >= 2 {
                // Twice in a row is a muted/zero-volume mic, not a quiet user.
                showNotice("Didn't catch any speech — check your mic's input volume in System Settings", for: 5.0, sound: nil)
            } else {
                showNotice("Didn't catch any speech", for: 2.0, sound: nil)
            }
        }
        if case .silent = outcome {} else {
            consecutiveSilentSessions = 0
        }
    }

    /// Consecutive no-speech outcomes — two in a row means the MIC is the
    /// problem, and the user deserves better advice than a shrug.
    private var consecutiveSilentSessions = 0

    // MARK: - Pill helpers

    private func setPill(_ state: PillState) {
        if agent.isOpen, reflectInAgentPanel(state) { return }
        // "Only while dictating" preference: the resting dot becomes nothing.
        if case .idleDot = state, !SettingsStore().showIdleIndicator {
            hud.model.state = .hidden
        } else {
            hud.model.state = state
        }
        if case .processing = state {} else {
            hud.model.slow = false
        }
    }

    /// While the agent panel is open, the pill states a dictation session
    /// would show become the panel's phase line instead, so the transcript
    /// never flips away. True when the state was absorbed.
    private func reflectInAgentPanel(_ state: PillState) -> Bool {
        let panel = hud.model.agent
        let wasListening = panel.phase == .listening || panel.phase == .transcribing
        switch state {
        case .agent:
            return false
        case .listening:
            panel.phase = .listening
            panel.notice = nil
        case .processing:
            panel.phase = .transcribing
        case .error(let message), .notice(let message):
            panel.notice = message
            if wasListening { panel.phase = .idle }
        case .success, .idleDot, .hidden:
            if wasListening { panel.phase = .idle }
        case .answer, .meetingPrompt, .meetingRecording, .updateReady:
            return false
        }
        hud.model.state = .agent
        hud.model.slow = false
        return true
    }

    /// Notices about BACKGROUND events (retry drain, recovery)
    /// must never hijack an active session's pill — they wait for it to end.
    /// Session-critical notices (cap warning, device change) still interrupt.
    private var pendingNotice: (message: String, seconds: TimeInterval, sound: EarconPlayer.Earcon?)?

    /// The migration flips formatting back on for users the OLD auto-degrade had
    /// switched off — they were degraded because the cleanup model was unreliable,
    /// and native smart transcription is a different mechanism entirely. Telling
    /// them is not optional: this codebase's rule is that auto-degrade must never
    /// be silent, and silently UN-degrading is the same rule broken in the other
    /// direction. Deferred, because it fires during launch.
    private func announceSmartRestoredIfNeeded() {
        let key = "shouldAnnounceSmartRestored"
        guard UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        // showBackgroundNotice, not showNotice: bind() replays the coordinator's
        // current .idle state a moment after launch, which repaints the pill and
        // would stomp a directly-shown notice.
        showBackgroundNotice(
            "Smart transcription is back on — the model does the formatting itself now.",
            for: 5.0, sound: nil
        )
    }

    /// The green check, for a pasted dictation and for saved meeting notes alike.
    private func showSuccessBadge(words: Int?) {
        earcons.play(.success)
        setPill(.success(words: words))
        dismissAfter(0.7)
    }

    private func showBackgroundNotice(_ message: String, for seconds: TimeInterval, sound: EarconPlayer.Earcon?) {
        switch coordinator.state {
        case .idle, .done, .cancelled, .failed:
            showNotice(message, for: seconds, sound: sound)
        default:
            pendingNotice = (message, seconds, sound)
        }
    }

    private func flushPendingNotice() {
        guard let notice = pendingNotice else { return }
        pendingNotice = nil
        // Give the terminal pill (success check / error chip) its moment first.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self else { return }
            switch self.coordinator.state {
            case .idle, .done, .cancelled, .failed:
                self.showNotice(notice.message, for: notice.seconds, sound: notice.sound)
            default:
                // A new session started — re-queue for its end.
                self.pendingNotice = self.pendingNotice ?? notice
            }
        }
    }

    private func showNotice(_ message: String, for seconds: TimeInterval, sound: EarconPlayer.Earcon?) {
        if let sound {
            earcons.play(sound)
        }
        setPill(.notice(message))
        dismissAfter(seconds)
    }

    private func showError(_ message: String) {
        setPill(.error(message))
        dismissAfter(6.0)
    }

    private func dismissAfter(_ seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Re-derive from coordinator state — a hardcoded .idleDot after the
            // 9-min cap warning stranded a HOT MIC behind the resting dot
            // (production pass 2, P0). Terminal/idle states still land on the dot.
            self.setPill(self.restingPill(for: self.coordinator.state))
        }
    }

    /// A recording meeting stands in for the idle dot; a dictation in flight
    /// always wins over it.
    private func restingPill(for state: DictationState) -> PillState {
        switch state {
        case .warming: return .listening(locked: false)
        case .recording(let locked): return .listening(locked: locked)
        case .finalizing, .transcribing, .inserting: return .processing
        default: return meetingHUD.restingState ?? .idleDot
        }
    }

    // MARK: - Timers

    private func startElapsedTimer() {
        hud.model.elapsed = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.sessionStartedAt else { return }
                self.hud.model.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func armSlowTimer() {
        slowTimer?.invalidate()
        slowTimer = Timer.scheduledTimer(withTimeInterval: TimeoutPolicy.slowStateUI, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hud.model.slow = true
            }
        }
    }

    private func clearSlowTimer() {
        slowTimer?.invalidate()
        slowTimer = nil
        hud.model.slow = false
    }

    // MARK: - Copy

    /// The service the recording goes to: ElevenLabs or MAI Transcribe 2's
    /// gateway when either transcribes, otherwise the active route's provider
    /// or gateway.
    private static var providerName: String {
        let settings = SettingsStore()
        switch settings.transcriptionSource {
        case .elevenLabs: return "ElevenLabs"
        case .sarvam: return "Sarvam"
        case .maiTranscribe: return settings.maiTranscribeEndpoint?.hostName ?? "MAI Transcribe 2"
        case .provider:
            let route = settings.activeRoute
            return route.gateway == .direct ? route.provider.displayName : route.gateway.displayName(for: route.provider)
        }
    }

    private static func copy(for failure: DictationFailure) -> String {
        switch failure {
        case .network: return "Couldn't reach \(providerName) — saved to History"
        case .auth:
            return !KeychainStore.hasModelKey
                ? "Add your API key in Settings — recording saved to History"
                : "API key isn't working — saved to History"
        case .modelAccess:
            return SettingsStore().transcribeModelOverride != nil
                ? "That model isn't available to your key — check Settings → Advanced. Saved to History"
                : "Your key can't use the transcription model yet — recording saved to History"
        case .badRequest: return "\(providerName) rejected the request — saved to History"
        case .rateLimited: return "Rate limited — History will retry it shortly"
        case .noMicrophone: return "No microphone found — connect one to dictate"
        case .quotaExhausted:
            // ElevenLabs credits are a monthly balance, not a daily quota.
            return SettingsStore().transcriptionSource == .elevenLabs
                ? "ElevenLabs credits are used up. Saved to History"
                : "Daily quota reached for your \(providerName) key. Saved to History"
        case .timeout: return "Timed out — saved to History"
        case .validation: return "Couldn't transcribe — saved to History"
        case .safetyBlocked: return "The API declined this one — saved to History"
        case .noAudio: return "Mic didn't start in time — try again"
        case .audio: return "Mic didn't start — try again"
        case .storage: return "Disk problem — couldn't save the audio"
        }
    }
}
