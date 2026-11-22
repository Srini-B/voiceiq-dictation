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
    private let sleepGuard: SessionSleepGuard

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
    private var stopGate = KeyboardStopGate()
    private var lastActivityRequestID: UUID?
    /// The keyboard's background session, while iOS has the app handle it.
    private var keyboardTransfers: (delegate: KeyboardTransfers, session: URLSession)?
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
        FormattingSettingsMigration.splitWritingRulesOnce()
        FormattingSettingsMigration.removeLiveTranscriptionSettings()
        FileLayout.removeRetiredModels()
        SettingsStore().adoptProviderWithKeyOnce()
        let client = GeminiClient(
            apiKey: { KeychainStore.loadAPIKey() },
            openAIKey: { KeychainStore.loadOpenAIKey() },
            openAIConfig: { SettingsStore().openAIConfig },
            provider: { SettingsStore().preferredProvider },
            elevenLabsKey: { KeychainStore.loadKey(.elevenLabs) }
        )
        transcription = GeminiTranscriptionService(client: client, verbatimCleaner: HexCleanup.cleaner)
        historyStore = try? HistoryStore.standard()
        UsageMeter.store = try? UsageStore.standard()
        meetings = MeetingEngine(
            client: client,
            config: { SettingsStore().geminiConfig },
            summaryModel: SettingsStore().geminiConfig.cleanupModel,
            providers: { SettingsStore().meetingProviders },
            speechEndpoints: { SettingsStore().meetingSpeechEndpoints },
            liveMeetingKey: { SettingsStore().transcribesWithElevenLabs ? KeychainStore.loadKey(.elevenLabs) : nil }
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
            },
            liveFactory: { _ in LiveTranscriber.makeFromSettings() }
        )
        sleepGuard = SessionSleepGuard(dictation: coordinator, meetings: meetings)
        inserter.onDeliver = { [weak self] text, mode in self?.deliver(text, mode: mode) }

        // Commands already in the App Group belong to an earlier process. Only
        // a command named in a launch URL may still be acted on.
        store.handledCommandID = store.commands.last?.id
        lastActivityRequestID = store.activityRequest?.id

        bind()
        startHistoryServices()
        DictionaryBridge.start()
        WritingRulesSync.shared.start()
        let deviceName = UIDevice.current.name
        Task { await HistorySync.shared.start(deviceName: deviceName) }
        Task { await MeetingSync.shared.start() }
        ActionButtonBridge.toggle = { [weak self] in await self?.toggleFromActionButton() }
        RecordingPlayer.voiceSessionIsActive = { [weak self] in self?.session.isActive ?? false }
        commandObserver = DarwinNotifier.observe(.command) { [weak self] in
            Task { @MainActor in self?.drainCommands() }
        }
        // The keyboard runs this same pipeline when no session is up; it
        // reads the keys and settings through the App Group.
        KeychainStore.shareWithKeyboard()
        AppSettingsMirror.publish()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { _ in AppSettingsMirror.publish() }
            .store(in: &cancellables)
    }

    /// One dictation's meta.json changed: History mirrors it, and "Never"
    /// audio retention drops the recording once the words exist.
    private func mirror(_ meta: SessionMeta, folder: URL) {
        historyStore?.upsert(meta: meta, folder: folder)
        RetentionPolicy.dropAudioIfNeverKept(meta, folder: folder)
    }

    // MARK: - Dictations the keyboard ran

    /// Adds the dictations the keyboard recorded and processed itself to
    /// History and the usage totals. One it left unfinished is recovered or
    /// queued like the app's own; a queued one is sent. In the foreground,
    /// a job the background session has not answered and no longer sends
    /// (Background App Refresh off, the app force-quit) is taken over and
    /// sent by the retry queue; one still uploading waits for its answer.
    func importKeyboardDictations(takeOverJobs: Bool) async {
        let jobs = KeyboardJob.pending()
        if takeOverJobs, jobs.contains(where: { $0.answer() == nil }) {
            let session = keyboardTransferSession()
            for job in await KeyboardJob.takeOverIdle(jobs, uploading: { await KeyboardTransfers.activeJobIDs(on: session) }) {
                SessionDiagnostics.note("keyboard job \(job.id.uuidString.prefix(8)) taken over by the app")
            }
        }
        for job in jobs where job.answer() != nil {
            await finishKeyboardJob(job.id)
        }
        await collectKeyboardDictations()
    }

    /// Moves what the keyboard finished into History and usage, and sends
    /// what is queued.
    private func collectKeyboardDictations() async {
        let (sessions, usage) = KeyboardInbox.collect()
        guard !sessions.isEmpty || !usage.isEmpty else { return }
        for record in usage { UsageMeter.store?.append(record) }
        for (meta, folder) in sessions { mirror(meta, folder: folder) }
        SessionDiagnostics.note("imported \(sessions.count) keyboard dictation(s)")
        if sessions.contains(where: { [.recording, .recorded, .transcribing].contains($0.meta.status) }) {
            // Only what the keyboard left: the app's own dictation may be running.
            await recoveryScanner?.scanAndRecover(sparing: { [weak self] in self?.coordinator.activeSessionFolder })
        }
        await retryQueue?.drain()
    }

    /// iOS woke the app for the keyboard's background session: connect to
    /// it, finish each answered job (writing model, History, usage, iCloud)
    /// and hold its text for the next keyboard.
    func handleKeyboardTransfers(completion: @escaping @MainActor () -> Void) {
        _ = keyboardTransferSession()
        keyboardTransfers?.delegate.setEventsDone { [weak self] in
            Task { @MainActor in
                // iOS may suspend the app once `completion` runs: every job
                // the session answered is finished first.
                for finish in self?.keyboardJobFinishes.values.map({ $0 }) ?? [] { await finish.value }
                await self?.importKeyboardDictations(takeOverJobs: false)
                completion()
            }
        }
        SessionDiagnostics.note("woken for the keyboard's background transfers")
    }

    /// The app's one connection to the keyboard's background session, made
    /// when iOS wakes the app for it or when the app checks what is still
    /// uploading. Answers that arrive on it are finished here; the job claim
    /// (`KeyboardJob.claim`) keeps a keyboard that also holds the answer from
    /// finishing it twice.
    private func keyboardTransferSession() -> URLSession {
        if let keyboardTransfers { return keyboardTransfers.session }
        let transfers = KeyboardTransfers { [weak self] id in
            // In the foreground nothing else collects it until the next
            // activation.
            Task { @MainActor in
                await self?.finishKeyboardJob(id)
                await self?.collectKeyboardDictations()
            }
        }
        let session = transfers.connect()
        keyboardTransfers = (transfers, session)
        return session
    }

    /// Finishes running now, by job: a second request for the same job
    /// (iOS's event, the launch import, the wake-up) waits for the first.
    private var keyboardJobFinishes: [UUID: Task<Void, Never>] = [:]

    private func finishKeyboardJob(_ id: UUID) async {
        if let running = keyboardJobFinishes[id] { return await running.value }
        let finish = Task { await self.runKeyboardJob(id) }
        keyboardJobFinishes[id] = finish
        await finish.value
        keyboardJobFinishes[id] = nil
    }

    private func runKeyboardJob(_ id: UUID) async {
        guard let job = KeyboardJob.read(id) else { return }
        let (outcome, claim) = await KeyboardTransfers.finish(job, service: transcription)
        switch outcome {
        case .busy:
            break
        case .waiting:
            // The retry queue sends it (now when online, later otherwise).
            job.takeOver(claim: claim)
        case .failed:
            job.takeOver(claim: claim)
        case .finished(let result):
            guard job.takeOver(claim: claim) else { break }
            store.heldByApp = HeldDictation(text: result.cleanedTranscript, mode: job.mode, document: job.document, host: job.host)
            SessionDiagnostics.note("keyboard job \(id.uuidString.prefix(8)) finished in the background")
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
        coordinator.$partialTranscript
            .removeDuplicates()
            .sink { [weak self] text in self?.session.setLiveText(text) }
            .store(in: &cancellables)
        coordinator.onAnswerReady = { [weak self] answer in
            self?.deliver(answer, mode: .ask)
        }
        coordinator.onSessionUpdate = { [weak self] meta, folder in
            self?.mirror(meta, folder: folder)
        }
        coordinator.onSessionDiscard = { [weak self] id in
            self?.historyStore?.delete(id: id.uuidString, removeFolder: false)
        }
        coordinator.onStageTimes = { stages in
            SessionDiagnostics.note(DictationNotice.stepsLine(stages))
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
            await importKeyboardDictations(takeOverJobs: false)
            // A keyboard start can launch the app straight into a dictation.
            await scanner.scanAndRecover(sparing: { [weak self] in self?.coordinator.activeSessionFolder })
            queue.start()
            Task.detached(priority: .utility) { RetentionPolicy().purge() }
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
        var leftStarts: Set<UUID> = []
        for command in commands[start...] where command.isFresh() && !processed.contains(command.id) {
            // A stop for a start left for the launch URL waits with it, so
            // the keyboard never reads its acknowledgement as the start's.
            if let startID = command.startID, leftStarts.contains(startID) { continue }
            // Without a warm session the mic is closed and cannot be opened
            // from the background. Leave the command for the launch URL the
            // keyboard opens next.
            if command.action == .start, !canStartInPlace {
                leftStarts.insert(command.id)
                if UIApplication.shared.applicationState != .active {
                    SessionDiagnostics.note("keyboard start left for the app (mic open: \(session.canRecordInBackground), needsForeground: \(needsForeground))")
                }
                continue
            }
            if command.action == .start, UIApplication.shared.applicationState != .active {
                SessionDiagnostics.note("keyboard start in place from the background")
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
            if stopGate.receive(command, state: coordinator.state) {
                coordinator.handle(.finalize)
            }
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

    /// Starts the command's dictation, or posts why it can't and returns that.
    @discardableResult
    private func start(_ command: KeyboardCommand) -> String? {
        if let problem = startBlocker() {
            session.post(notice: problem)
            return problem
        }
        target.host = command.hostBundleID
        currentMode = command.mode
        session.mode = command.mode
        let mode: DictationMode
        switch command.mode {
        case .dictate: mode = .dictate
        case .translate: mode = .translate(targets: SettingsStore().translationTargetLanguages)
        case .ask: mode = .askAnything(selectedText: command.context)
        }
        guard coordinator.handle(.begin, mode: mode) else {
            let problem = coordinator.coachingHint ?? "Still working on the last one"
            session.post(notice: problem)
            return problem
        }
        stopGate.started(by: command.id)
        coordinator.handle(.lockIn)
        applyHeldStop()
        return nil
    }

    /// Finalizes the dictation a held stop names, once it records.
    private func applyHeldStop() {
        guard stopGate.takeHeldStop(state: coordinator.state) else { return }
        SessionDiagnostics.note("keyboard hold released before recording: stopping now")
        coordinator.handle(.finalize)
    }

    private func startBlocker() -> String? {
        if let missing = setupBlocker() { return missing }
        if meetings.isRecording { return "Notes are recording" }
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
        // Freshness is checked after the session starts, which can take a moment.
        if !processed.contains(commandID), let command = store.commands.first(where: { $0.id == commandID }),
           command.isFresh() {
            accept(command)
            // A refused start stays here, with the reason, instead of
            // returning to an app where nothing is recording.
            if let problem = start(command) {
                SessionDiagnostics.note("keyboard start refused: \(problem)")
                banner = problem
                return
            }
            // A stop queued before this process started was skipped as old;
            // the commands after this start apply to it.
            drainCommands()
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
        if store.keyboardIsRecording() {
            // The keyboard records this one itself; it stops on this request.
            SessionDiagnostics.note("action button: stop the keyboard's dictation")
            store.keyboardStopRequestedAt = Date()
            return nil
        }
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
        if let since = processingSince {
            SessionDiagnostics.note(String(format: "app opened %.0fs into processing", Date().timeIntervalSince(since)))
        }
        needsForeground = false
        setup.refresh()
        drainCommands()
        DictionaryBridge.appBecameActive()
        Task { await importKeyboardDictations(takeOverJobs: true) }
        WritingRulesSync.shared.refresh()
        Task { await HistorySync.shared.refresh() }
        Task { await MeetingSync.shared.refresh() }
    }

    func appEnteredBackground() {
        showSwipeBack = false
    }

    func prepareForTermination() {
        sleepGuard.stop()
        if case .recording = coordinator.state { coordinator.handle(.finalize) }
        if meetings.isRecording { meetings.stopRecording() }
        session.end()
    }

    // MARK: - Pipeline → keyboard

    private var processingSince: Date?

    private func stateChanged(_ state: DictationState) {
        defer { previousState = state }
        switch state {
        case .warming, .recording:
            if case .recording = state, !(previousState.isRecording),
               UIApplication.shared.applicationState != .active {
                SessionDiagnostics.note("microphone started from the background")
            }
            if session.recordingStartedAt == nil { session.recordingStartedAt = Date() }
            session.dictationPhase = .recording
            // `$state` publishes before the coordinator stores the state, so
            // the held stop is checked on the next turn, against what it stored.
            if case .recording = state {
                Task { @MainActor [weak self] in self?.applyHeldStop() }
            }
        case .finalizing, .transcribing, .inserting:
            session.recordingStartedAt = nil
            session.dictationPhase = .processing
            if processingSince == nil { processingSince = Date() }
        case .idle, .done, .cancelled, .failed:
            if let since = processingSince {
                // How long the transcript and cleanup took, and where the app was.
                let place = UIApplication.shared.applicationState == .active ? "foreground" : "background"
                SessionDiagnostics.note(String(format: "processed in %.1fs (%@)", Date().timeIntervalSince(since), place))
                processingSince = nil
            }
            session.recordingStartedAt = nil
            session.dictationPhase = .warm
            session.releaseBackgroundTime()
            stopGate.ended()
            if state != previousState, case .failed(let failure) = state, DictationNotice.isMicrophoneFailure(failure),
               UIApplication.shared.applicationState != .active {
                // iOS refused the microphone to a backgrounded app. The next tap
                // opens the app once, which always works.
                SessionDiagnostics.note("background microphone start refused (\(failure)) with mic open \(self.session.canRecordInBackground); next dictation goes through the app")
                needsForeground = true
                session.post(notice: "Tap the mic again")
            } else if state != previousState, let message = DictationNotice.message(for: state, coordinator: coordinator) {
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
        let endTask = {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            task = .invalid
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typedCheckDelay) { [store] in
            guard store.insertedDeliveryID != delivery.id else { return endTask() }
            // Handled: a keyboard opened later must not type it as well.
            store.insertedDeliveryID = delivery.id
            let before = UIPasteboard.general.changeCount
            UIPasteboard.general.string = delivery.text
            // UIPasteboard bumps changeCount at the end of the current event
            // loop, so read it on the next pass.
            DispatchQueue.main.async {
                defer { endTask() }
                // Not something the user copied: the keyboard must not offer
                // it for the dictionary.
                store.appPasteboardChangeCount = UIPasteboard.general.changeCount
                // Whether iOS took the write from the background; the Control
                // Center path on a keyboard-case iPad depends on it.
                let landed = UIPasteboard.general.changeCount != before
                let state = UIApplication.shared.applicationState == .active ? "foreground" : "background"
                SessionDiagnostics.note(landed
                    ? "result not typed by a keyboard; copied to the clipboard (\(state))"
                    : "result not typed by a keyboard; clipboard write refused (\(state))")
            }
        }
    }

    static let typedCheckDelay: TimeInterval = 2
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
