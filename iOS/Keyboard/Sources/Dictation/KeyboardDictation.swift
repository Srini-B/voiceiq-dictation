import AVFAudio
import Combine
import os
import UIKit
import VoiceIQBridge
import VoiceIQCore
import WidgetKit

/// Dictation inside the keyboard, for when no app session is running: the
/// app's own pipeline (`DictationCoordinator`, `GeminiTranscriptionService`,
/// Real-time transcription, writing rules, dictionary, Translate, Ask), wired
/// as `AppModel` wires it, with `WebMicCapture` as the microphone. One per
/// keyboard process, so a keyboard that reappears mid-dictation picks it up.
///
/// Settings and keys come from the app through the App Group
/// (`AppSettingsMirror`, `KeychainStore`). Session folders go to
/// `KeyboardInbox`, which the app adds to History; billed calls are counted
/// in memory and handed over with the folder.
///
/// From anomalyco/hex's KeyboardLocalDictation (MIT): the microphone opens on
/// touch-down (#2089); a hidden keyboard stops the capture at once, finishes
/// and holds the text for the next keyboard (#2163); a watchdog ends a quiet
/// capture or a stuck transcription; and a memory guard (#2045). A
/// transcription that outlives the keyboard goes to `KeyboardTransfers`.
@MainActor
final class KeyboardDictation: ObservableObject {
    static let shared = KeyboardDictation()

    /// A touch-down capture neither kept nor dropped by then is dropped, so a
    /// lost touch never leaves the microphone open.
    static let armedTimeout: TimeInterval = 3
    /// A capture with no audio this long finishes with what it heard.
    static let captureSilence: TimeInterval = 6
    /// A transcription this old is given up (kept in History when long).
    nonisolated static let transcriptionTimeout: TimeInterval = 120
    /// Memory below iOS's limit the first dictation needs: the capture web
    /// view, its page and WebKit's first use. Later ones reuse the page.
    /// Short of this, the tap opens the app instead (anomalyco/hex #2045).
    static let startHeadroomNeeded = 32 * 1_048_576
    static let restartHeadroomNeeded = 24 * 1_048_576

    /// `.off` when idle or only armed; otherwise `.recording` or `.processing`.
    @Published private(set) var phase: SessionSnapshot.Phase = .off
    @Published private(set) var recordingStartedAt: Date?
    private(set) var bars = LevelBars()
    var liveText: String { phase == .recording ? coordinator?.partialTranscript ?? "" : "" }
    var mode: KeyboardMode { job?.mode ?? .dictate }

    /// Types a result into the keyboard on screen; false when none can.
    var onDeliver: ((String, KeyboardMode) -> Bool)?
    var onNotice: ((String) -> Void)?
    /// The microphone never started; the tap should go through the app.
    var onStartFailed: (() -> Void)?

    /// One dictation, from the tap to its handover.
    private struct Job {
        let id = UUID()
        var mode: KeyboardMode
        var selectedText: String?
        var host: String?
        var document: UUID?
        /// The text before the cursor when the keyboard hid.
        var textBefore: String?
        var folder: URL?
        /// Touch-down on the Hex key: recording, not yet shown or kept.
        var armed: Bool
        /// The keyboard hid: the result is held instead of typed.
        var interrupted = false
        var processingSince: Date?
    }

    private var mic: WebMicCapture?
    private var coordinator: DictationCoordinator?
    private var inserter = KeyboardInserter()
    private let target = DictationTarget()
    private var cancellables: Set<AnyCancellable> = []
    private var job: Job?
    private var previousState: DictationState = .idle
    /// Cancelled sessions waiting for the coordinator's keep-or-delete, by
    /// session: a second cancel while the first drains must not lose it.
    private var cancelledFolders: [UUID: URL] = [:]
    private var expiring: DispatchSemaphore?
    private var transfers: (delegate: KeyboardTransfers, session: URLSession)?
    /// Folders whose hand-over failed (`hand(over:)`).
    private var unhanded: Set<URL> = []
    private var lastPublished: Date?
    private lazy var client = GeminiClient(
        apiKey: { KeychainStore.loadAPIKey() },
        openAIKey: { KeychainStore.loadOpenAIKey() },
        openAIConfig: { SettingsStore().openAIConfig },
        provider: { SettingsStore().preferredProvider },
        elevenLabsKey: { KeychainStore.loadKey(.elevenLabs) },
        keepsSentTranscription: true
    )

    var isArmed: Bool { job?.armed == true }

    /// Why this tap cannot dictate in the keyboard, or nil when it can.
    func blocker() -> String? {
        if job != nil || phase != .off { return "a dictation is running" }
        guard let mic, mic.isReady else { return "capture page not ready" }
        if !AppSettingsMirror.apply() { return "app settings not shared yet" }
        if !KeychainStore.hasModelKey { return "no key for the selected provider" }
        if AVAudioApplication.shared.recordPermission != .granted { return "microphone not allowed" }
        let headroom = os_proc_available_memory()
        let needed = coordinator == nil ? Self.startHeadroomNeeded : Self.restartHeadroomNeeded
        // The Simulator says 0: no limit known.
        if headroom != 0, headroom < needed { return "only \(headroom / 1_048_576) MB of memory left" }
        return nil
    }

    /// Touch-down on the Hex key: recording starts unseen, so the first
    /// words are not lost while the touch becomes a tap or a hold (`keep`)
    /// or a slide (`discard`). Call `blocker()` first.
    func arm(mode: KeyboardMode, selectedText: String?, host: String?, document: UUID?, textBefore: String?) {
        guard begin(mode: mode, selectedText: selectedText, host: host, document: document, textBefore: textBefore, armed: true),
              let touch = job?.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armedTimeout) { [weak self] in
            // Only this touch's capture: a later touch has its own timeout.
            guard let self, self.isArmed, self.job?.id == touch else { return }
            self.discard(reason: "never kept")
        }
    }

    /// The armed touch became a tap or a hold: the recording shows.
    func keep() {
        guard isArmed else { return }
        job?.armed = false
        KeyboardLog.note("touch-down capture kept")
        switch coordinator?.state {
        case .recording, .warming: phase = .recording
        default: break
        }
    }

    /// The armed touch became a slide or was cancelled: nothing is kept.
    func discard(reason: String) {
        guard isArmed else { return }
        KeyboardLog.note("touch-down capture discarded (\(reason))")
        coordinator?.handle(.cancel)
    }

    /// Starts a dictation. Call `blocker()` first.
    func start(mode: KeyboardMode, selectedText: String?, host: String?, document: UUID?, textBefore: String?) -> Bool {
        begin(mode: mode, selectedText: selectedText, host: host, document: document, textBefore: textBefore, armed: false)
    }

    private func begin(mode: KeyboardMode, selectedText: String?, host: String?, document: UUID?, textBefore: String?, armed: Bool) -> Bool {
        let coordinator = self.coordinator ?? makeCoordinator()
        target.host = host
        let dictationMode: DictationMode = switch mode {
        case .dictate: .dictate
        case .translate: .translate(targets: SettingsStore().translationTargetLanguages)
        case .ask: .askAnything(selectedText: selectedText)
        }
        job = Job(mode: mode, selectedText: selectedText, host: host, document: document, textBefore: textBefore, armed: armed)
        client.forgetSentTranscription()
        guard coordinator.handle(.begin, mode: dictationMode) else {
            KeyboardLog.note("in-keyboard start refused: \(coordinator.coachingHint ?? "busy")")
            job = nil
            return false
        }
        coordinator.handle(.lockIn)
        return true
    }

    func stop() {
        guard let coordinator, !isArmed else { return }
        switch coordinator.state {
        case .recording, .warming: coordinator.handle(.finalize)
        default: break
        }
    }

    func cancel() {
        coordinator?.handle(.cancel)
    }

    /// A keyboard is on screen: the capture page loads (the first time) or
    /// moves into it, so a touch-down can record at once.
    func keyboardAppeared(in view: UIView) {
        let mic = self.mic ?? WebMicCapture()
        self.mic = mic
        mic.attach(to: view)
        endExpiringActivity()
        if !unhanded.isEmpty { hand(over: nil) }
    }

    /// The keyboard is going away mid-dictation. A touch still deciding is
    /// dropped; a recording stops at once and keeps what was said; and the
    /// text is held for the next keyboard. iOS gives the process a little
    /// time to finish (`performExpiringActivity`); when it runs out first,
    /// the request goes to the background session.
    func keyboardHidden(document: UUID?, textBefore: String?) {
        guard var job else { return }
        if job.armed {
            discard(reason: "keyboard hidden")
            return
        }
        job.interrupted = true
        // Only the recorded field's text: another field's would let this
        // result be typed there. Otherwise the text from the start stays.
        if let textBefore, let document, document == job.document { job.textBefore = textBefore }
        self.job = job
        switch coordinator?.state {
        case .recording, .warming:
            KeyboardLog.note("keyboard hidden while recording: finishing with what was said")
            coordinator?.handle(.finalize)
        case .finalizing, .transcribing, .inserting:
            KeyboardLog.note("keyboard hidden while transcribing: holding its text for the next keyboard")
        default:
            return
        }
        keepRunningWhileHidden()
    }

    /// Self-heal, on every poll while the keyboard shows.
    func healIfStalled(now: Date = Date()) {
        guard let job, !job.armed else { return }
        if phase == .recording, let mic, let last = mic.lastAudioAt, now.timeIntervalSince(last) > Self.captureSilence {
            if mic.markStartTimedOut() {
                // Never started (WebKit's audio stayed pending): the app
                // records this one instead (`onStartFailed`).
                KeyboardLog.note("capture never started in \(Int(now.timeIntervalSince(last))) s")
            } else {
                KeyboardLog.note("capture silent for \(Int(now.timeIntervalSince(last))) s: finishing with what it heard")
            }
            stop()
        } else if phase == .processing, let since = job.processingSince, now.timeIntervalSince(since) > Self.transcriptionTimeout {
            KeyboardLog.note("transcription stuck for \(Int(now.timeIntervalSince(since))) s: giving up")
            cancel()
        }
    }

    /// The Control Center control reads this while the keyboard records,
    /// as it reads the app's snapshot; the app asks the keyboard to stop
    /// through `keyboardStopRequestedAt`.
    func publishState(store: SharedStore = .shared) {
        if let started = recordingStartedAt, let request = store.keyboardStopRequestedAt, request > started, phase == .recording {
            KeyboardLog.note("stopped from the Control Center control")
            stop()
        }
        let recording = phase == .recording
        let wasRecording = store.keyboardIsRecording()
        guard recording else {
            if lastPublished != nil {
                lastPublished = nil
                store.publishKeyboard(nil)
                ControlCenter.shared.reloadControls(ofKind: SharedStore.dictationControlKind)
            }
            return
        }
        guard Date().timeIntervalSince(lastPublished ?? .distantPast) >= SharedStore.heartbeatInterval else { return }
        lastPublished = Date()
        store.publishKeyboard(SessionSnapshot(phase: .recording, mode: mode, recordingStartedAt: recordingStartedAt))
        if !wasRecording { ControlCenter.shared.reloadControls(ofKind: SharedStore.dictationControlKind) }
    }

    // MARK: - Wiring

    private init() {
        LevelGlowSource.levels = { [unowned self] in
            self.phase == .recording ? self.bars.heights : SharedStore.shared.levelBars
        }
    }

    private func makeCoordinator() -> DictationCoordinator {
        FileLayout.overrideRoot = KeyboardInbox.root
        if UsageMeter.store == nil { UsageMeter.store = try? UsageStore.inMemory() }
        let target = self.target
        inserter = KeyboardInserter()
        let coordinator = DictationCoordinator(
            audioFactory: { [unowned self] in self.mic ?? WebMicCapture() },
            transcription: GeminiTranscriptionService(client: client),
            insertion: inserter,
            contextProvider: {
                DictationContext(targetAppBundleID: target.host, targetAppName: target.host.map(AppNames.displayName(for:)))
            },
            liveFactory: { _ in LiveTranscriber.makeFromSettings() }
        )
        inserter.onDeliver = { [weak self] text, mode in self?.deliver(text, mode: mode) }
        coordinator.onAnswerReady = { [weak self] answer in self?.deliver(answer, mode: .ask) }
        coordinator.onStageTimes = { stages in KeyboardLog.note(DictationNotice.stepsLine(stages)) }
        coordinator.onSessionUpdate = { [weak self] meta, folder in
            RetentionPolicy.dropAudioIfNeverKept(meta, folder: folder)
            // The coordinator kept a cancelled recording (it was long): History gets it.
            if meta.status == .cancelled, self?.cancelledFolders.removeValue(forKey: meta.id) != nil {
                self?.hand(over: folder)
            }
        }
        coordinator.onSessionDiscard = { [weak self] id in self?.cancelledFolders[id] = nil }
        coordinator.$state
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &cancellables)
        coordinator.$micLevel
            .sink { [weak self] level in
                guard let self, self.phase == .recording else { return }
                self.bars.append(level)
            }
            .store(in: &cancellables)
        self.coordinator = coordinator
        return coordinator
    }

    private func stateChanged(_ state: DictationState) {
        defer { previousState = state }
        switch state {
        case .warming, .recording:
            // The folder exists only once the engine is up.
            if job?.folder == nil { job?.folder = coordinator?.activeSessionFolder }
            if recordingStartedAt == nil {
                recordingStartedAt = Date()
                bars = LevelBars()
                KeyboardLog.note("in-keyboard dictation started (host: \(target.host ?? "unknown"))")
            }
            if !isArmed { phase = .recording }
        case .finalizing, .transcribing, .inserting:
            recordingStartedAt = nil
            phase = .processing
            if job?.processingSince == nil { job?.processingSince = Date() }
        case .idle, .done, .cancelled, .failed:
            // A new dictation passes from the last one's end through idle;
            // only the first terminal state ends a job.
            switch previousState {
            case .idle, .done, .cancelled, .failed: return
            default: break
            }
            let finished = job
            job = nil
            // The request kept for a hand-off holds the whole recording:
            // released once this dictation is handed off or over, before the
            // next memory check.
            defer { client.forgetSentTranscription() }
            recordingStartedAt = nil
            phase = .off
            bars = LevelBars()
            // After the hand-over below, which waits a turn.
            defer { DispatchQueue.main.async { [weak self] in self?.endExpiringActivity() } }
            if let since = finished?.processingSince {
                KeyboardLog.note(String(format: "processed in %.1fs (keyboard)", Date().timeIntervalSince(since)))
            }
            if state != .cancelled, finished?.armed != true, let reason = mic?.startFailure {
                // Nothing was recorded; the app records this one instead.
                if let folder = finished?.folder { try? FileManager.default.removeItem(at: folder) }
                KeyboardLog.note("in-keyboard microphone did not start (\(reason)); going through the app")
                onStartFailed?()
                return
            }
            if state == .cancelled {
                // The coordinator decides keep-or-delete once capture stops
                // (`onSessionUpdate`/`onSessionDiscard`); the folder moves then.
                if let folder = finished?.folder, let id = SessionMeta.read(from: folder)?.id { cancelledFolders[id] = folder }
                return
            }
            if state == .done(.queuedForRetry), let finished {
                // Offline, or handed off because iOS's time ran out.
                queueOffline(finished)
                if finished.interrupted { return }
            } else {
                // `$state` publishes before the coordinator's bookkeeping, which
                // deletes a silent or blip session: hand over what is left after it.
                let folder = finished?.folder
                DispatchQueue.main.async { [weak self] in self?.hand(over: folder) }
            }
            if let coordinator, let message = DictationNotice.message(for: state, coordinator: coordinator) {
                onNotice?(message)
            }
        }
    }

    /// A result: the keyboard on screen types it, unless this keyboard hid
    /// meanwhile; otherwise the next keyboard gets it.
    private func deliver(_ text: String, mode: KeyboardMode) {
        if mode != .ask { SharedStore.shared.keyboardDelivery = Delivery(mode: mode, text: text, hostBundleID: nil) }
        if job?.interrupted != true, onDeliver?(text, mode) == true { return }
        SharedStore.shared.heldByKeyboard = HeldDictation(text: text, mode: mode, document: job?.document,
                                                          host: job?.host, textBefore: job?.textBefore)
        KeyboardLog.note("result held for the next keyboard")
    }

    /// The dictation is over: its folder and billed calls go to the app.
    /// One whose calls could not be written stays in `recordings` and is
    /// handed over again with the next one, or when the keyboard reappears.
    private func hand(over folder: URL?) {
        for earlier in unhanded { handOver(earlier) }
        if let folder { handOver(folder) }
    }

    private func handOver(_ folder: URL) {
        // The coordinator discarded it: nothing for History.
        guard FileManager.default.fileExists(atPath: folder.path) else { unhanded.remove(folder); return }
        let id = SessionMeta.read(from: folder)?.id.uuidString
        let usage = id.map { UsageMeter.store?.records(forSession: $0) ?? [] } ?? []
        guard KeyboardInbox.finish(folder: folder, usage: usage) else {
            if FileManager.default.fileExists(atPath: folder.path) { unhanded.insert(folder) }
            return KeyboardLog.note("hand-over to the app failed; will try again")
        }
        unhanded.remove(folder)
        // Only this dictation's: another may still be waiting for its answer.
        if let id { UsageMeter.store?.deleteRecords(forSession: id) }
    }

    // MARK: - Outliving the keyboard

    /// Keeps the process running after the keyboard hid, until the job ends
    /// or iOS's time runs out; then the request goes to the background
    /// session.
    private func keepRunningWhileHidden() {
        guard expiring == nil else { return }
        let done = DispatchSemaphore(value: 0)
        expiring = done
        let id = job?.id
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Finishing a dictation") { [weak self] expired in
            if expired {
                // Not once the keyboard came back and ended this activity.
                DispatchQueue.main.sync { MainActor.assumeIsolated { if self?.expiring === done { self?.timeRanOut(for: id) } } }
                done.signal()
            } else {
                _ = done.wait(timeout: .now() + Self.transcriptionTimeout)
            }
        }
    }

    private func endExpiringActivity() {
        expiring?.signal()
        expiring = nil
    }

    /// The request the service would send for this recording, not sent.
    private func captureRequest(folder: URL, job: Job) async -> CapturedTranscriptionRequest? {
        let service = GeminiTranscriptionService(client: client)
        let seconds = SessionMeta.read(from: folder)?.audioDurationSeconds ?? 0
        let context = KeyboardJob(folder: folder.lastPathComponent, mode: job.mode,
                                  translationTargets: SettingsStore().translationTargetLanguages,
                                  selectedText: job.selectedText, host: job.host, durationSeconds: seconds).context
        do {
            _ = try await GeminiClient.$capturesTranscription.withValue(true) {
                try await service.transcribe(audioURL: FileLayout.audioCAF(in: folder), durationSeconds: seconds, context: context)
            }
        } catch let captured as CapturedTranscriptionRequest {
            return captured
        } catch {
            KeyboardLog.note("background request not built: \(error)")
        }
        return nil
    }

    /// An offline or handed-off dictation: the background session sends it
    /// (once the network is back), and the app finishes it. Without a
    /// session it goes to the app's retry queue as before.
    private func queueOffline(_ job: Job) {
        guard let folder = job.folder else { return }
        guard Self.fitsOneRequest(folder), !client.transcriptionAnswered else {
            KeyboardLog.note("longer than one request, or answered already: left to the app's retry")
            return hand(over: folder)
        }
        // The request this keyboard already sent, byte for byte: nothing is
        // encoded again. When handed off, iOS is about to suspend the
        // keyboard, so it goes out now.
        if let request = client.sentTranscription {
            if !send(request, job: job, reason: job.interrupted ? "keyboard suspended" : "offline") { hand(over: folder) }
            return
        }
        Task {
            if let request = await captureRequest(folder: folder, job: job), send(request, job: job, reason: "offline") { return }
            hand(over: folder)
        }
    }

    /// Hands `job` to the background session.
    @discardableResult
    private func send(_ request: CapturedTranscriptionRequest, job: Job, reason: String) -> Bool {
        guard let folder = job.folder else { return false }
        let seconds = SessionMeta.read(from: folder)?.audioDurationSeconds ?? 0
        let record = KeyboardJob(folder: folder.lastPathComponent, mode: job.mode,
                                 translationTargets: SettingsStore().translationTargetLanguages,
                                 selectedText: job.selectedText, host: job.host,
                                 hostName: job.host.map(AppNames.displayName(for:)), document: job.document,
                                 durationSeconds: seconds)
        do {
            try KeyboardTransfers.send(request, for: record, on: transferSession())
        } catch {
            KeyboardLog.note("background transfer not started: \(error)")
            return false
        }
        KeyboardLog.note("transcription handed to the background session (\(reason))")
        return true
    }

    /// iOS's time ran out before the transcription answered: the coordinator
    /// stops its own request (and its retry), so no answer can arrive here,
    /// and ends as queued; `stateChanged` then hands the request it sent
    /// from the background session. When a successful answer has already
    /// reached the keyboard, or the audio went out live, nothing is handed
    /// over and the keyboard finishes it when iOS resumes it. An answer still
    /// on its way, or a cancelled request the provider already received, can
    /// still mean the audio reaches the provider twice (accepted risk,
    /// docs/IOS.md).
    private func timeRanOut(for id: UUID?) {
        // Only the job this activity was started for: a later one is not handed off.
        guard let id, job?.id == id else { return }
        guard let folder = job?.folder, phase == .processing, client.sentTranscription != nil, let coordinator else { return }
        // Several chunks: the keyboard finishes it when iOS resumes it, or
        // the app recovers the recording.
        guard Self.fitsOneRequest(folder) else { return }
        // Answered already (the writing pass is running): finishing here
        // sends nothing again.
        guard !client.transcriptionAnswered else {
            return KeyboardLog.note("not handed over: the provider already answered")
        }
        KeyboardLog.note("keyboard's time ran out while transcribing")
        if !coordinator.handOffTranscription() {
            KeyboardLog.note("not handed over: the provider already has this dictation")
        }
    }

    private static func fitsOneRequest(_ folder: URL) -> Bool {
        KeyboardJob.fitsOneRequest(durationSeconds: SessionMeta.read(from: folder)?.audioDurationSeconds ?? .infinity)
    }

    private func transferSession() -> URLSession {
        if let transfers { return transfers.session }
        let delegate = KeyboardTransfers { id in
            Task { @MainActor in await KeyboardDictation.shared.finishTransfer(id) }
        }
        let session = delegate.connect()
        transfers = (delegate, session)
        return session
    }

    /// The background session answered while the keyboard runs: the rest of
    /// the pipeline runs here, and the text is held for the keyboard.
    private func finishTransfer(_ id: UUID) async {
        guard let record = KeyboardJob.read(id), let folder = record.folderURL() else { return }
        let (outcome, claim) = await KeyboardTransfers.finish(record, service: GeminiTranscriptionService(client: client))
        switch outcome {
        case .busy:
            return
        case .waiting:
            // The app's retry sends it again when it opens.
            record.takeOver(claim: claim)
        case .failed:
            guard record.remove(claim: claim) else { return }
            hand(over: folder)
        case .finished(let result):
            guard record.remove(claim: claim) else { return }
            hand(over: folder)
            let text = result.cleanedTranscript
            SharedStore.shared.heldByKeyboard = HeldDictation(text: text, mode: record.mode, document: record.document, host: record.host)
            KeyboardLog.note("background transcription finished in the keyboard; text held")
        }
    }
}
