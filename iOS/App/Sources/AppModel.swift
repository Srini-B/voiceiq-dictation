import AVFoundation
import Combine
import UIKit
import VoiceIQBridge
import VoiceIQCore

/// Composition root for the iOS app: the same dictation pipeline as macOS,
/// driven by keyboard commands instead of a hotkey, delivering to the keyboard
/// instead of the focused field.
@MainActor
final class AppModel: ObservableObject {
    let coordinator: DictationCoordinator
    let meetings: MeetingEngine
    let session = VoiceSession()
    let hostReturn = HostReturn()
    let setup = SetupMonitor()
    let historyStore: HistoryStore?
    let transcription: GeminiTranscriptionService

    /// Shown after the one-time bounce when the app could not send the user
    /// back on its own.
    @Published var showSwipeBack = false
    @Published var banner: String?

    private let store = SharedStore.shared
    private let inserter = KeyboardInserter()
    private var retryQueue: RetryQueue?
    private var recoveryScanner: RecoveryScanner?
    private var cancellables: Set<AnyCancellable> = []
    private var commandObserver: UUID?
    /// Commands acted on in this process. Guards against acting twice when a
    /// command arrives both by Darwin ping and by URL.
    private var processed: Set<UUID> = []
    private var lastActivityRequestID: UUID?
    /// The app the current dictation is for. A box so the coordinator's
    /// context closure can read it without capturing `self` during init.
    private let target = DictationTarget()
    private var currentMode: KeyboardMode = .dictate
    private var lastLevelWrite = Date.distantPast
    private var previousState: DictationState = .idle
    /// A background start failed to open the microphone. Until the app has
    /// been in the foreground again, starts go through the app.
    private var needsForeground = false

    init() {
        FormattingSettingsMigration.restoreAutoDegradedWritingRulesOnce()
        FormattingSettingsMigration.removeLiveTranscriptionSettings()
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
        transcription = GeminiTranscriptionService(client: client)
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
        let inserter = self.inserter
        coordinator = DictationCoordinator(
            audioFactory: {
                #if DEBUG
                if let simulated = SimulatedMicrophone.make() { return simulated }
                #endif
                return AudioCaptureEngine()
            },
            transcription: transcription,
            insertion: inserter,
            contextProvider: { [target] in
                DictationContext(
                    targetAppBundleID: target.host,
                    targetAppName: target.host.map(AppNames.displayName(for:))
                )
            }
        )
        inserter.onDeliver = { [weak self] text, mode in self?.deliver(text, mode: mode) }

        // Commands already in the App Group belong to an earlier process. Only
        // a command named in a launch URL may still be acted on.
        store.handledCommandID = store.commands.last?.id
        lastActivityRequestID = store.activityRequest?.id

        bind()
        startHistoryServices()
        DictionaryBridge.start()
        ActionButtonBridge.toggle = { [weak self] in await self?.toggleFromActionButton() }
        commandObserver = DarwinNotifier.observe(.command) { [weak self] in
            Task { @MainActor in self?.drainCommands() }
        }
    }

    // MARK: - Wiring

    private func bind() {
        coordinator.$state
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &cancellables)
        coordinator.$micLevel
            .sink { [weak self] level in self?.levelChanged(level) }
            .store(in: &cancellables)
        coordinator.onAnswerReady = { [weak self] answer in
            self?.deliver(answer, mode: .ask)
        }
        coordinator.onSessionUpdate = { [weak self] meta, folder in
            self?.historyStore?.upsert(meta: meta, folder: folder)
            if SettingsStore().audioRetentionDays < 0, meta.rawTranscript != nil || meta.status == .silent {
                for audio in [FileLayout.audioCAF(in: folder), FileLayout.audioFLAC(in: folder)] {
                    try? FileManager.default.removeItem(at: audio)
                }
            }
        }
        coordinator.onSessionDiscard = { [weak self] id in
            self?.historyStore?.delete(id: id.uuidString, removeFolder: false)
        }
        meetings.$phase
            .sink { [weak self] phase in
                guard let self else { return }
                if case let .recording(_, since) = phase {
                    self.session.meetingStartedAt = since
                } else {
                    self.session.meetingStartedAt = nil
                }
            }
            .store(in: &cancellables)
        meetings.onNotice = { [weak self] message in self?.banner = message }
        session.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            if case .recording = self.coordinator.state {
                Log.session.info("interruption — finalizing the dictation")
                self.session.holdBackgroundTime()
                self.coordinator.handle(.finalize)
            }
            if self.meetings.isRecording { self.meetings.stopRecording() }
        }
    }

    private func startHistoryServices() {
        guard let historyStore else { return }
        let scanner = RecoveryScanner(store: historyStore, transcription: transcription)
        scanner.onRecovered = { [weak self] _ in self?.banner = RecoveryNotice.message(for: .relaunch, copied: false) }
        recoveryScanner = scanner
        let queue = RetryQueue(store: historyStore, transcription: transcription)
        queue.onDrained = { [weak self] texts in
            let count = texts.count
            self?.banner = count == 1 ? "A queued dictation is ready in History" : "\(count) queued dictations are ready in History"
        }
        retryQueue = queue
        Task {
            await scanner.scanAndRecover()
            queue.start()
            Task.detached(priority: .utility) { RetentionPolicy().purgeExpiredAudio() }
        }
    }

    func retry(_ record: DictationRecord) async -> String? {
        guard let retryQueue else { return nil }
        switch await retryQueue.retrySingle(record) {
        case .recovered: return "Transcribed again"
        case .alreadyDone: return "Couldn't find this recording"
        case .stillOffline: return "Still offline. It will retry when you're back online."
        case .rateLimited(let wait): return "Rate limited. Retrying in \(Int(wait.rounded()))s."
        case .blocked: return "Check your API key in Settings"
        case .failed: return record.rawTranscript != nil ? "Couldn't transcribe it again. The earlier text is kept." : "Retry failed"
        case .busy: return "Already retrying"
        }
    }

    // MARK: - Commands from the keyboard

    private func drainCommands() {
        let commands = store.commands
        let start = commands.lastIndex { $0.id == store.handledCommandID }.map { $0 + 1 } ?? 0
        for command in commands[start...] where command.isFresh() && !processed.contains(command.id) {
            // Without a warm session the mic is closed and cannot be opened
            // from the background. Leave the command for the launch URL the
            // keyboard opens next.
            if command.action == .start, !canStartInPlace {
                if UIApplication.shared.applicationState != .active {
                    SessionDiagnostics.note("keyboard start left for the app (keeper: \(session.keeperDescription), needsForeground: \(needsForeground))")
                }
                continue
            }
            if command.action == .start, UIApplication.shared.applicationState != .active {
                SessionDiagnostics.note("keyboard start in place from the background (keeper: \(session.keeperDescription))")
            }
            accept(command)
            handle(command)
            if command.action == .start, let host = command.hostBundleID {
                hostReturn.note(host: host, outcome: .inPlace)
            }
        }
        if let request = store.activityRequest, request.id != lastActivityRequestID,
           Date().timeIntervalSince(request.issuedAt) < KeyboardCommand.maximumAge {
            lastActivityRequestID = request.id
            handle(request)
        }
    }

    private var canStartInPlace: Bool {
        guard session.isActive else { return false }
        if UIApplication.shared.applicationState == .active { return true }
        return session.canRecordInBackground && !needsForeground
    }

    private func accept(_ command: KeyboardCommand) {
        processed.insert(command.id)
        store.handledCommandID = command.id
    }

    private func handle(_ command: KeyboardCommand) {
        switch command.action {
        case .start:
            start(command)
        case .stop:
            if case .recording = coordinator.state { coordinator.handle(.finalize) }
        case .cancel:
            coordinator.handle(.cancel)
        }
    }

    private func handle(_ request: ActivityRequest) {
        switch request.action {
        case .stopDictation:
            if case .recording = coordinator.state { coordinator.handle(.finalize) }
        case .stopMeeting:
            meetings.stopRecording()
        case .endSession:
            endSession()
        }
    }

    private func start(_ command: KeyboardCommand) {
        if let problem = startBlocker() {
            session.post(notice: problem)
            return
        }
        target.host = command.hostBundleID
        currentMode = command.mode
        session.mode = command.mode
        let mode: DictationMode
        switch command.mode {
        case .dictate: mode = .dictate
        case .translate: mode = .translate(target: SettingsStore().translationTargetLanguage)
        case .ask: mode = .askAnything(selectedText: command.context)
        }
        guard coordinator.handle(.begin, mode: mode) else {
            session.post(notice: coordinator.coachingHint ?? "Still working on the last one")
            return
        }
        coordinator.handle(.lockIn)
    }

    private func startBlocker() -> String? {
        if let missing = setupBlocker() { return missing }
        if meetings.isRecording { return "A meeting is recording" }
        switch coordinator.state {
        case .idle, .done, .cancelled, .failed: return nil
        case .recording, .warming: return nil
        default: return "Still working on the last one"
        }
    }

    /// What no dictation can start without. Either can be taken away after
    /// onboarding: the key deleted, or the microphone switched off in Settings
    /// (iOS then ends the app, so this is read fresh on the next launch).
    private func setupBlocker() -> String? {
        if !KeychainStore.hasModelKey { return "Add an API key in VoiceiQ" }
        if AVAudioApplication.shared.recordPermission != .granted { return "Allow the microphone in VoiceiQ" }
        return nil
    }

    /// Keeps the user in the app, on the screen that fixes the problem,
    /// instead of opening a session that cannot record and sending them back.
    private func showSetupProblem() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            banner = "Add an API key to dictate"
        case .undetermined:
            banner = "Allow the microphone to dictate"
            setup.requestMicrophone()
            NotificationCenter.default.post(name: .voiceIQShowKeyboardSetup, object: nil)
        default:
            banner = "Microphone access is off. Turn it on in Settings to dictate."
            NotificationCenter.default.post(name: .voiceIQShowKeyboardSetup, object: nil)
        }
    }

    // MARK: - Launch URLs

    func open(_ url: URL) {
        switch BridgeURL.parse(url) {
        case .start(let id, let host):
            startFromKeyboard(commandID: id, host: host)
        case .setup:
            // The keyboard opens this only when it runs without Full Access,
            // which it cannot report through the App Group itself. The earlier
            // "seen with Full Access" proof no longer holds.
            SharedStore.shared.keyboardSeenAt = nil
            setup.refresh()
            banner = nil
            NotificationCenter.default.post(name: .voiceIQShowKeyboardSetup, object: nil)
        case nil:
            break
        }
    }

    /// The one-time bounce: the keyboard found no live session and opened the
    /// app. Start the session while in the foreground, start the dictation,
    /// then send the user back.
    private func startFromKeyboard(commandID: UUID, host: String?) {
        SessionDiagnostics.note("keyboard start through the app (session active: \(session.isActive), host: \(host ?? "unknown"))")
        needsForeground = false
        if let problem = setupBlocker() {
            SessionDiagnostics.note("keyboard start refused: \(problem)")
            showSetupProblem()
            return
        }
        if !session.isActive {
            do {
                try session.begin()
            } catch {
                banner = "Couldn't start the microphone: \(error.localizedDescription)"
                return
            }
        }
        if !processed.contains(commandID), let command = store.commands.first(where: { $0.id == commandID }),
           command.isFresh() {
            accept(command)
            start(command)
        }
        hostReturn.returnToHost(host, isRecording: { [weak self] in
            if case .recording = self?.coordinator.state { return true }
            return false
        }) { [weak self] returned in
            if !returned { self?.showSwipeBack = true }
        }
    }

    // MARK: - Action button

    /// `ToggleDictationIntent`: stop the dictation in progress, or start one
    /// for whatever app is in front. Runs in the background inside the
    /// audio-recording intent, so the session and its Live Activity can start
    /// here without opening VoiceiQ. The keyboard follows the shared snapshot.
    /// Returns why nothing started, for the intent to show; nothing else
    /// would, since no keyboard or Live Activity is on screen.
    func toggleFromActionButton() async -> String? {
        switch coordinator.state {
        case .recording, .warming:
            SessionDiagnostics.note("action button: stop")
            coordinator.handle(.finalize)
            return nil
        default:
            break
        }
        if let problem = startBlocker() {
            SessionDiagnostics.note("action button: blocked (\(problem))")
            session.post(notice: problem)
            return problem
        }
        do {
            try session.begin(fromActionButton: true)
        } catch {
            SessionDiagnostics.note("action button: session did not start (\(error))")
            session.post(notice: "Couldn't start the microphone")
            return "Couldn't start the microphone"
        }
        SessionDiagnostics.note("action button: start")
        target.host = nil
        currentMode = .dictate
        session.mode = .dictate
        guard coordinator.handle(.begin, mode: .dictate) else {
            let notice = coordinator.coachingHint ?? "Still working on the last one"
            session.post(notice: notice)
            return notice
        }
        coordinator.handle(.lockIn)
        // The intent returns once recording is underway; iOS needs the Live
        // Activity up by then.
        for _ in 0..<20 {
            if case .recording = coordinator.state { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    // MARK: - Session controls in the app

    func startSession() {
        do { try session.begin() } catch {
            banner = "Couldn't start the microphone: \(error.localizedDescription)"
        }
    }

    func endSession() {
        if case .recording = coordinator.state {
            session.holdBackgroundTime()
            coordinator.handle(.finalize)
        }
        if meetings.isRecording { meetings.stopRecording() }
        session.end()
    }

    func startMeeting() {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            showSetupProblem()
            return
        }
        if !session.isActive { startSession() }
        guard session.isActive else { return }
        if case .recording = coordinator.state { coordinator.handle(.finalize) }
        meetings.startRecording()
    }

    func stopMeeting() {
        meetings.stopRecording()
    }

    func appBecameActive() {
        needsForeground = false
        setup.refresh()
        drainCommands()
        DictionaryBridge.appBecameActive()
    }

    func appEnteredBackground() {
        showSwipeBack = false
    }

    func prepareForTermination() {
        if case .recording = coordinator.state { coordinator.handle(.finalize) }
        if meetings.isRecording { meetings.stopRecording() }
        session.end()
    }

    // MARK: - Pipeline → keyboard

    private func stateChanged(_ state: DictationState) {
        defer { previousState = state }
        switch state {
        case .warming, .recording:
            if case .recording = state, !(previousState.isRecording),
               UIApplication.shared.applicationState != .active {
                SessionDiagnostics.note("microphone started from the background (keeper: \(session.keeperDescription))")
            }
            if session.recordingStartedAt == nil { session.recordingStartedAt = Date() }
            session.dictationPhase = .recording
        case .finalizing, .transcribing, .inserting:
            session.recordingStartedAt = nil
            session.dictationPhase = .processing
        case .idle, .done, .cancelled, .failed:
            session.recordingStartedAt = nil
            session.dictationPhase = .warm
            session.releaseBackgroundTime()
            if state != previousState, case .failed(let failure) = state, Self.isMicrophoneFailure(failure),
               UIApplication.shared.applicationState != .active {
                // iOS refused the microphone to a backgrounded app. The next tap
                // opens the app once, which always works.
                SessionDiagnostics.note("background microphone start refused (\(failure)) with keeper \(self.session.keeperDescription); next dictation goes through the app")
                needsForeground = true
                session.post(notice: "Tap the mic again")
            } else if state != previousState, let message = Self.notice(for: state, coordinator: coordinator) {
                session.post(notice: message)
            }
        }
    }

    private func levelChanged(_ level: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelWrite) > 0.06 else { return }
        lastLevelWrite = now
        session.setLevel(level)
    }

    private func deliver(_ text: String, mode: KeyboardMode) {
        let delivery = Delivery(mode: mode, text: text, hostBundleID: target.host)
        session.deliver(delivery)
        if mode != .ask { copyIfNotTyped(delivery) }
    }

    /// The keyboard on screen types the result wherever the user is. When no
    /// keyboard has typed it shortly after (the user closed it, or is on a
    /// screen with no text field), the result goes on the clipboard.
    private func copyIfNotTyped(_ delivery: Delivery) {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Copy result") {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typedCheckDelay) { [store] in
            defer {
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
                task = .invalid
            }
            guard store.insertedDeliveryID != delivery.id else { return }
            // Handled: a keyboard opened later must not type it as well.
            store.insertedDeliveryID = delivery.id
            UIPasteboard.general.string = delivery.text
            // Not something the user copied: the keyboard must not offer it
            // for the dictionary.
            store.appPasteboardChangeCount = UIPasteboard.general.changeCount
            SessionDiagnostics.note("result not typed by a keyboard; copied to the clipboard")
        }
    }

    static let typedCheckDelay: TimeInterval = 2

    static func isMicrophoneFailure(_ failure: DictationFailure) -> Bool {
        switch failure {
        case .audio, .noMicrophone: return true
        default: return false
        }
    }

    static func notice(for state: DictationState, coordinator: DictationCoordinator) -> String? {
        switch state {
        case .failed(let failure):
            if let message = coordinator.modeFailureMessage { return message }
            switch failure {
            case .auth: return "API key rejected. Check it in VoiceiQ."
            case .modelAccess: return "Model unavailable. Check Settings › Advanced."
            case .network: return "Couldn't reach the model. It's saved in History."
            case .rateLimited: return "Rate limited. Retry from History."
            case .quotaExhausted: return "Daily quota reached"
            case .timeout: return "Timed out. Retry from History."
            case .audio, .noMicrophone, .noAudio: return "Microphone unavailable"
            case .storage: return "Storage is full"
            case .badRequest, .validation, .safetyBlocked: return "Couldn't transcribe. It's in History."
            }
        case .done(.queuedForRetry): return "Offline. It will send when you're back."
        case .done(.silent): return "Didn't catch that"
        default: return nil
        }
    }
}

@MainActor
final class DictationTarget {
    var host: String?
}

/// Hands results to the keyboard. The keyboard does the actual typing.
@MainActor
final class KeyboardInserter: TextInserting {
    var onDeliver: ((String, KeyboardMode) -> Void)?

    func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        let mode: KeyboardMode
        switch context.mode {
        case .dictate: mode = .dictate
        case .translate: mode = .translate
        case .askAnything: mode = .ask
        // The iPhone never starts an agent session; its transcript is
        // handed to the caller, not inserted. Deliver as plain text.
        case .agent: mode = .dictate
        }
        onDeliver?(text, mode)
        return .inserted
    }
}

extension Notification.Name {
    static let voiceIQShowKeyboardSetup = Notification.Name("voiceIQShowKeyboardSetup")
}

private extension DictationState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
