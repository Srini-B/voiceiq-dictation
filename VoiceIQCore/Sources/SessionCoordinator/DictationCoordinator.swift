import Foundation

/// The brain: translates hotkey intents into session lifecycle via the pure
/// DictationStateMachine, drives audio → transcription → insertion, and owns the
/// per-session folder + meta.json writes.
///
/// One session records at a time. A press while the previous one is still being
/// transcribed detaches that job: it finishes in the background and its text is
/// inserted before the new one's, in spoken order (Hex does the same,
/// anomalyco/hex, MIT). All state hops through the main actor.
@MainActor
public final class DictationCoordinator: ObservableObject {
    // Observable surface for the HUD / status item.
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var micLevel: Float = 0
    @Published public private(set) var lastResult: String?
    @Published public private(set) var coachingHint: String?

    /// "Delete All History" should also forget the paste-last buffer — a user
    /// wiping their words expects them gone from everywhere we hold them.
    public func clearLastResult() {
        lastResult = nil
    }

    public struct Session {
        public let id: UUID
        public let folder: URL
        public let startedAt: Date
        public var context: DictationContext
        public var meta: SessionMeta
        /// Peak mic level from capture — silence vs dropped-transcript evidence.
        public var peakLevel: Float = 1.0
        /// Its place in the insert order, taken once its audio is final.
        var turn: InsertTurns.Ticket?
    }

    /// How a job that no longer owns the pill ended. The pill belongs to the
    /// new recording, so the app reports these on their own.
    public enum DetachedResult: Equatable, Sendable {
        case outcome(DictationOutcome)
        case failure(DictationFailure)
    }
    public var onDetachedResult: ((DetachedResult) -> Void)?
    public var hasBackgroundJobs: Bool { !detached.isEmpty }

    /// Jobs still being transcribed after a newer recording took the pill.
    private var detached: [UUID: Session] = [:]
    private var detachedTasks: [UUID: Task<Void, Never>] = [:]
    private let insertTurns = InsertTurns()

    /// Below this metered peak the user simply didn't speak (F9b). Scale matches
    /// AudioCaptureEngine's onLevel; whisper-quiet speech peaks well above it.
    nonisolated static let silencePeakThreshold: Float = 0.06
    /// Clips shorter than this can't contain a word — never sent to the API
    /// (dogfood: a 0.19s blip got uploaded, errored, and showed as Failed).
    static let minimumSendableDuration: Double = 0.2
    /// Up to this length a clip is sent only when it was clearly spoken. A
    /// short word ("Hi") released at once can be this short now that recording
    /// stops at key-up, while an accidental tap in a room is quieter.
    static let shortClipDuration: Double = 0.4
    /// ≈ −37 dBFS RMS: above room tone (about 0.1 in a −52 dBFS room), below
    /// any spoken word, which peaks near 1.
    static let shortClipSpeechPeak: Float = 0.3
    /// Zero frames on a hold shorter than this is an accidental blip, not an
    /// engine failure — the first buffer simply hadn't arrived yet.
    static let blipHoldThreshold: TimeInterval = 0.8
    /// Nothing rose this far above the room ⇒ nobody spoke, whatever the
    /// absolute peak says. Used to classify an empty transcript honestly.
    static let emptyTranscriptSNRThreshold: Double = 8
    /// A discard needs BOTH a quiet absolute peak and no separation from the
    /// room. This clause can only ever prevent a discard, never cause one.
    static let discardSNRThreshold: Double = 6

    /// The in-flight transcription task — cancelled when the user cancels the
    /// session (audit L8: Esc previously left the network work running).
    private var inFlightTask: Task<Void, Never>?

    /// Folder of the session in progress, if any — Delete All must not sweep it (audit L7).
    public var activeSessionFolder: URL? { session?.folder }

    /// `didSet` rather than a teardown call at each exit, because there are a
    /// dozen places that clear this — four early returns in `completeFinalize`
    /// alone (blip, zero frames, sub-0.4s, digital silence), plus cancel, error
    /// and warming paths. Every one of them must stop the screen collector.
    private var session: Session? {
        didSet {
            guard oldValue?.id != session?.id else { return }
            if oldValue != nil, let collector = screenContextCollector {
                screenContextCollector = nil
                _ = collector.stop()
            }
        }
    }
    private var capture: AudioCapturing?
    /// When the user let go; the gap to the audio's end is the finalize stage.
    private var finalizeRequestedAt: Date?
    /// The engine stop a finalize started, until its result is used.
    private var pendingStop: Task<AudioCaptureResult, Never>?
    private var screenContextCollector: ScreenContextCollector?
    /// How loud the room is, measured for every dictation.
    private var noiseFloor = NoiseFloorEstimator()
    /// Why the last session ended with no speech — the pill copy differs, nothing
    /// else does, so this rides alongside the outcome instead of widening the
    /// state machine for a string.
    public private(set) var lastSilenceReason: SilenceReason = .noSpeech
    /// Space-lock (or UI hands-free) that arrived while the engine was still
    /// coming up — applied on engineStarted, cleared when the session ends.
    private var pendingLockIn = false

    /// Fired after every meta.json write — the app mirrors sessions into HistoryStore.
    public var onSessionUpdate: ((SessionMeta, URL) -> Void)?
    /// Fired when a session's artifacts were discarded entirely (blips, no-speech,
    /// short cancels) — the app removes its History row. Disk mirrors the UI:
    /// what History doesn't show, we don't store.
    public var onSessionDiscard: ((UUID) -> Void)?

    /// Where the time after key-up went, for the session log.
    /// Fired once per completed session, after the result was handed over.
    public var onStageTimes: ((DictationSteps) -> Void)?

    /// Cancelled recordings at least this long stay recoverable in History —
    /// an accidental Esc after minutes of dictation must not destroy the words.
    static let cancelKeepThreshold: Double = 10

    private let audioFactory: @MainActor () -> AudioCapturing
    private let transcription: TranscriptionServicing
    private let insertion: TextInserting
    private let contextProvider: @MainActor () -> DictationContext
    /// Injectable clock so hold-duration classification is testable.
    private let now: () -> Date
    /// Injectable so the noise behaviours can be exercised both ways headlessly,
    /// without a UserDefaults round-trip in the test.
    /// Injectable because the real check reads SYSTEM-WIDE state. Left un-injected,
    /// every begin-a-session test fails on any machine that happens to have secure
    /// input held — a stuck loginwindow after a lock screen, or Terminal's Secure
    /// Keyboard Entry — which is a coin flip for a contributor, not a bug in
    /// their change.
    private let secureInputActive: @MainActor () -> Bool

    public init(
        audioFactory: @escaping @MainActor () -> AudioCapturing,
        transcription: TranscriptionServicing,
        insertion: TextInserting,
        contextProvider: @escaping @MainActor () -> DictationContext = { DictationContext() },
        now: @escaping () -> Date = Date.init,
        secureInputActive: @escaping @MainActor () -> Bool = { SecureInput.isActive }
    ) {
        self.audioFactory = audioFactory
        self.transcription = transcription
        self.insertion = insertion
        self.contextProvider = contextProvider
        self.now = now
        self.secureInputActive = secureInputActive
    }

    // MARK: - Hotkey entry point

    /// Returns whether the intent was ACCEPTED — a refused .begin (secure field,
    /// session already active) must reach the hotkey grammar, or the next press
    /// of the key would read as a stop.
    @discardableResult
    public func handle(_ intent: HotkeyIntent) -> Bool {
        switch intent {
        case .begin:
            return beginSession()
        case .lockIn:
            // Engine start is deferred a tick (and Bluetooth mics take longer):
            // a lock arriving during warming must not be dropped — latch it and
            // apply the moment the engine reports started.
            if state == .warming {
                pendingLockIn = true
                return true
            }
            return apply(.lockIn)
        case .finalize:
            finalizeSession()
            return true
        case .cancel:
            cancelSession(hint: nil)
            return true
        case .abortAccidental:
            handleAccidentalChord()
            return true
        }
    }

    /// The grammar only reports a chord within a second of its own press, so
    /// the session is young and cancelling it silently loses nothing. A session
    /// already in flight is never touched; the transcript is sacred.
    private func handleAccidentalChord() {
        switch state {
        case .warming, .recording:
            cancelSession(hint: nil)
        case .finalizing, .transcribing, .inserting:
            Log.session.info("accidental chord ignored — session in flight")
        default:
            break
        }
    }

    // MARK: - Session lifecycle

    @discardableResult
    private func beginSession() -> Bool {
        if state == .transcribing { detachInFlightSession() }
        guard state == .idle || state.isTerminal else {
            Log.session.info("begin ignored: session already active (\(String(describing: self.state), privacy: .public))")
            return false
        }
        // F18: never record over a secure input field.
        if secureInputActive() {
            // Name the app holding it and say what to do. The flag is SYSTEM-WIDE,
            // so the culprit is usually not the window the user is looking at —
            // "secure input is on" alone reads as "VoiceiQ is broken", especially
            // during onboarding where a stuck loginwindow flag is common.
            if let holder = SecureInput.holder() {
                coachingHint = "\(holder.name) has secure input on. \(SecureInput.advice(forHolder: holder.name))"
                Log.session.info("begin refused: secure input held by \(holder.name, privacy: .public) (pid \(holder.pid))")
            } else {
                coachingHint = "Can't dictate here — another app has secure input on"
                Log.session.info("begin refused: secure input active, holder unknown")
            }
            return false
        }
        state = .idle
        coachingHint = nil
        pendingLockIn = false // never inherit a stale latch from a dead session
        apply(.hotkeyBegin)

        let id = UUID()
        let startedAt = now()
        do {
            let folder = try FileLayout.makeSessionFolder(id: id, now: startedAt)
            var meta = SessionMeta(id: id, startedAt: startedAt, status: .recording)
            let context = contextProvider()
            meta.targetAppBundleID = context.targetAppBundleID
            meta.targetAppName = context.targetAppName
            meta.write(to: folder)
            session = Session(id: id, folder: folder, startedAt: startedAt, context: context, meta: meta)

            if SettingsStore().screenContextEnabled {
                let collector = ScreenContextCollector()
                screenContextCollector = collector
                collector.start()
            }

            noiseFloor = NoiseFloorEstimator()

            let capture = audioFactory()
            self.capture = capture
            capture.onLevel = { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.ingestLevel(level)
                }
            }
            capture.onDeviceChange = { [weak self] message in
                Log.audio.info("device change surfaced: \(message, privacy: .public)")
                // Mid-recording mic switch must be VISIBLE — an AirPods
                // auto-connect changes what's being recorded (production pass 2).
                Task { @MainActor [weak self] in
                    if case .recording = self?.state {
                        self?.coachingHint = message
                    }
                }
            }
            capture.onWriteFailure = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleWriteFailure()
                }
            }
            capture.onEngineDied = { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.handleEngineDeath(message)
                }
            }
            // Prewarm-on-keydown: engine starts before grammar classification so
            // t=0 audio is never lost (VoiceInk #687 is the canonical race).
            // Deferred ONE runloop turn: engine.start() blocks the main thread
            // (hundreds of ms on a Bluetooth mic renegotiating into headset
            // mode), and the pill cannot paint until this function returns —
            // the key press must be acknowledged instantly (dogfood).
            Task { @MainActor [weak self] in
                self?.startCaptureIfStillWarming(capture, sessionID: id, folder: folder)
            }
            return true
        } catch {
            Log.audio.error("session setup failed: \(error)")
            apply(.engineFailed(.audio))
            capture = nil
            discardSessionArtifacts()
            self.session = nil
            return false
        }
    }

    /// The job keeps running and inserts in its turn; the state machine and
    /// the pill move on to the new recording.
    private func detachInFlightSession() {
        guard let current = session else { return }
        detached[current.id] = current
        detachedTasks[current.id] = inFlightTask
        inFlightTask = nil
        session = nil
        state = .idle
        Log.session.info("new dictation while \(current.id.uuidString, privacy: .public) is transcribing — it finishes in the background")
    }

    /// The deferred half of beginSession. The session may already be gone by
    /// the time this runs (Esc during warming, a blip release) — starting the
    /// mic for a dead session would record with no session to own the audio.
    private func startCaptureIfStillWarming(_ capture: AudioCapturing, sessionID: UUID, folder: URL) {
        guard session?.id == sessionID, self.capture === capture, state == .warming else {
            Log.audio.info("engine start skipped — session moved on before the mic came up")
            return
        }
        do {
            try capture.start(writingTo: FileLayout.audioCAF(in: folder))
            apply(.engineStarted)
            if pendingLockIn {
                pendingLockIn = false
                apply(.lockIn)
            }
        } catch {
            Log.audio.error("audio engine failed to start: \(error)")
            // Honest failure taxonomy: "Mic didn't start" is wrong advice on a
            // Mac with no input device at all. And zero frames were captured, so
            // there is NOTHING to store — a "Failed" History row with a dead-end
            // Retry would be a lie (blip/discard doctrine).
            let failure: DictationFailure =
                (error as? AudioCaptureEngine.CaptureError) == .noInputDevice ? .noMicrophone : .audio
            apply(.engineFailed(failure))
            // Release the failed engine + its open CAF handle (audit L19).
            if let failed = self.capture {
                Task.detached(priority: .utility) { _ = await failed.stop() }
            }
            self.capture = nil
            discardSessionArtifacts()
            self.session = nil
        }
    }

    // MARK: - Disk failure (F22)

    private func handleWriteFailure() {
        guard case .recording = state else { return }
        Log.audio.error("sustained CAF write failures — finalizing with what we have (F22)")
        updateMeta { $0.errorCode = "disk_write" }
        finalizeSession()
    }

    /// Engine died mid-recording and could not be revived: a pill that keeps
    /// "listening" while nothing records loses every word after the seam.
    /// Finalize with the partial audio — same shape as handleWriteFailure.
    private func handleEngineDeath(_ message: String) {
        guard case .recording = state else { return }
        Log.audio.error("audio engine died mid-recording (\(message, privacy: .public)) — finalizing with what we have")
        updateMeta { $0.errorCode = "engine_died" }
        // A mic that never delivered anything finalizes with zero frames, and
        // that failure has its own message; "dictating what was captured"
        // would promise text that does not exist.
        if message != AudioCaptureEngine.noAudioMessage {
            coachingHint = "\(message) — dictating what was captured"
        }
        finalizeSession()
    }

    private func ingestLevel(_ level: Float) {
        micLevel = level
        noiseFloor.ingest(level: level)
    }

    private func finalizeSession() {
        guard let sessionID = session?.id else { return }
        // The machine decides first; side effects only on an ACCEPTED finalize
        // (same pattern as cancelSession, audit #10). A second stop while a
        // session is in flight must not stop capture or clobber meta.
        guard apply(.finalize) else { return }
        finalizeRequestedAt = Date()
        session?.context.recordingEndedAt = finalizeRequestedAt
        finishScreenContext()
        // Recording ends at key-up: no listening past it, even mid-word. stop()
        // only collects the buffer the HAL already holds (audio from before
        // key-up, at most one I/O buffer away) and tears the graph down, off the
        // main actor.
        let engine = capture
        capture = nil
        micLevel = 0
        let stop = Task { @MainActor in
            await engine?.stop() ?? AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
        }
        pendingStop = stop
        Task { @MainActor [weak self] in
            let result = await stop.value
            // A cancel while the engine was stopping took the result over.
            guard let self, self.pendingStop == stop else { return }
            self.pendingStop = nil
            guard self.session?.id == sessionID else { return }
            self.completeFinalize(result: result)
        }
    }

    private func completeFinalize(result: AudioCaptureResult) {
        guard var session else { return }

        let heldFor = now().timeIntervalSince(session.startedAt)
        guard result.framesWritten > 0 else {
            if heldFor < Self.blipHoldThreshold {
                // Accidental blip: released before the first buffer landed. Not an
                // error — and not worth storing (pill feedback only).
                lastSilenceReason = .noSpeech
                apply(.silenceOnly)
                discardSessionArtifacts()
                self.session = nil
                return
            }
            // Zero frames = nothing a Retry could ever transcribe. Show the
            // error in the pill, store no dead-end row (blip/discard doctrine).
            apply(.noAudioCaptured)
            discardSessionArtifacts()
            self.session = nil
            return
        }
        session.peakLevel = result.peakLevel
        self.session = session
        // Only meaningful together: a peak with no floor to compare it against
        // says nothing about the room, and would read as a measurement.
        let roomFloorDB = noiseFloor.floorDB
        let speechPeakDB = roomFloorDB == nil ? nil : noiseFloor.peakDB
        let separation = noiseFloor.measuredSNR
        updateMeta {
            $0.status = .recorded
            $0.audioDurationSeconds = result.durationSeconds
            $0.gapMarkers = result.gapMarkers
            // Recorded unconditionally — this is the data that will calibrate the
            // thresholds, and it has to exist before the behaviour that uses it.
            $0.noiseFloorDBFS = roomFloorDB
            $0.speechPeakDBFS = speechPeakDB
        }
        if let roomFloorDB, let speechPeakDB, let separation {
            Log.audio.info("room \(roomFloorDB, format: .fixed(precision: 1))dBFS, speech \(speechPeakDB, format: .fixed(precision: 1))dBFS, separation \(separation, format: .fixed(precision: 1))dB")
        }

        // Micro-clips can't contain a word — classify locally, never upload
        // (the API errors on them, which used to surface as Failed).
        let spokeClearly = result.peakIsTrustworthy && result.peakLevel >= Self.shortClipSpeechPeak
        guard result.durationSeconds >= Self.shortClipDuration
                || (result.durationSeconds >= Self.minimumSendableDuration && spokeClearly) else {
            lastSilenceReason = .noSpeech
            apply(.silenceOnly)
            discardSessionArtifacts()
            self.session = nil
            return
        }
        // Digital silence (muted mic, zero input volume) can't transcribe either:
        // the peak gate that already classifies the FAILURE response also decides
        // BEFORE upload — two pointless API round-trips per muted attempt
        // (production pass 2 P1 #29). Whisper-quiet speech peaks well above this.
        //
        // Two further clauses, both of which can only ever PREVENT a discard:
        //  - unmeasured loudness ⇒ upload. A wasted round-trip costs a fraction of
        //    a cent; a discarded session costs the user's words.
        //  - a quiet absolute peak that still rose clearly above the room is
        //    someone speaking softly in a quiet place, not a dead mic.
        let roseAboveRoom = (separation ?? .infinity) >= Self.discardSNRThreshold
        if !result.peakIsTrustworthy {
            Log.audio.info("peak unmeasured — uploading rather than guessing silence")
        } else if result.peakLevel < Self.silencePeakThreshold, !roseAboveRoom {
            lastSilenceReason = .noSpeech
            apply(.silenceOnly)
            discardSessionArtifacts()
            self.session = nil
            return
        }
        apply(.audioFinalized)

        let ticket = insertTurns.take()
        session.turn = ticket
        self.session = session
        let sessionID = session.id
        let finalizeStartedAt = Date()
        let requestedAt = finalizeRequestedAt ?? finalizeStartedAt
        let finalizeSeconds = finalizeStartedAt.timeIntervalSince(requestedAt)
        let usageScope = UsageScope(activity: .dictation, sessionID: sessionID.uuidString)
        inFlightTask = Task { [weak self] in
          // Every way out of the job frees the next one's turn.
          defer { ticket.finish() }
          await UsageMeter.$scope.withValue(usageScope) {
            guard let self else { return }
            do {
                let outcome = try await self.transcription.transcribe(
                    audioURL: FileLayout.audioCAF(in: session.folder),
                    durationSeconds: result.durationSeconds,
                    context: session.context
                )
                // One model call hears the audio and writes the text, so the
                // whole request is the transcription step.
                let readyAt = Date()
                let stages = DictationSteps(
                    finishRecording: finalizeSeconds,
                    transcription: readyAt.timeIntervalSince(finalizeStartedAt)
                )
                guard !Task.isCancelled else { return }
                await self.completeTranscription(
                    sessionID: sessionID, outcome: outcome,
                    startedAt: requestedAt, readyAt: readyAt, stages: stages
                )
            } catch {
                guard !Task.isCancelled else { return }
                await self.failTranscription(sessionID: sessionID, error: error)
            }
          }
        }
    }

    private func completeTranscription(
        sessionID: UUID, outcome: TranscriptionResult, startedAt: Date, readyAt: Date, stages: DictationSteps
    ) async {
        guard let waiting = job(sessionID) else { return } // stale completion
        var stages = stages
        updateMeta(sessionID) {
            $0.rawTranscript = outcome.rawTranscript
            $0.cleanedTranscript = outcome.cleanedTranscript
            $0.modelID = outcome.modelID
            $0.status = .transcribing
        }
        // Still .transcribing while an earlier job inserts, so a press now
        // can detach this one too.
        await waiting.turn?.waitForPrevious()
        guard !Task.isCancelled, let job = self.job(sessionID) else { return } // cancelled while waiting
        let isForeground = session?.id == sessionID
        if isForeground { apply(.transcriptReady) }

        let insertionOutcome = await insertion.insert(outcome.cleanedTranscript, context: job.context)
        let insertedAt = Date()
        let pipelineSeconds = insertedAt.timeIntervalSince(startedAt)
        // From the text being ready, so saving it to History counts here too.
        stages.insert = insertedAt.timeIntervalSince(readyAt)
        let status: SessionMeta.Status, event: DictationEvent, result: DictationOutcome
        switch insertionOutcome {
        case .inserted: (status, event, result) = (.inserted, .inserted, .inserted)
        case .frontmostChanged: (status, event, result) = (.awaitingChip, .frontmostChangedAwaitingChip, .awaitingChip)
        case .fellBackToClipboard: (status, event, result) = (.copiedToClipboard, .insertionFellBackToClipboard, .copiedToClipboard)
        case .blockedSecureField: (status, event, result) = (.heldSecure, .insertionBlockedSecure, .heldForSecureField)
        }
        updateMeta(sessionID) { $0.status = status; $0.pipelineSeconds = pipelineSeconds; $0.steps = stages }
        lastResult = outcome.cleanedTranscript
        if session?.id == sessionID {
            apply(event)
            session = nil
        } else {
            endDetached(sessionID)
            onDetachedResult?(.outcome(result))
        }
        reportStageTimes(stages, sessionID: sessionID, requestedAt: startedAt)
    }

    /// The session with this id, whether it owns the pill or was detached.
    private func job(_ id: UUID) -> Session? {
        session?.id == id ? session : detached[id]
    }

    private func endDetached(_ id: UUID) {
        detached[id] = nil
        detachedTasks[id] = nil
    }

    /// One line per dictation from key-up to the result, so a slow one can be
    /// blamed on the mic teardown, the transcript, the writing model or the
    /// typing. History shows the same steps.
    private func reportStageTimes(_ stages: DictationSteps, sessionID: UUID, requestedAt: Date) {
        func ms(_ seconds: TimeInterval?) -> String { seconds.map { "\(Int($0 * 1000))ms" } ?? "-" }
        let total: TimeInterval? = Date().timeIntervalSince(requestedAt)
        Log.session.notice("timing \(sessionID.uuidString, privacy: .public): finalize \(ms(stages.finishRecording), privacy: .public), upload \(ms(stages.transcription), privacy: .public), insert \(ms(stages.insert), privacy: .public), key-up to done \(ms(total), privacy: .public)")
        onStageTimes?(stages)
    }

    private func failTranscription(sessionID: UUID, error: Error) async {
        if let job = detached[sessionID] {
            failDetached(job, error: error)
            return
        }
        guard session?.id == sessionID else { return }
        // Empty transcript: silence is judged by AUDIO ENERGY, not duration —
        // a long quiet hold is "no speech", never "Failed" (F9b; dogfood bug).
        // Speech energy present but no transcript = real failure, retryable (F9a).
        if case .some(.emptyTranscript) = error as? TranscriptionError {
            let peak = session?.peakLevel ?? 1.0
            let duration = session?.meta.audioDurationSeconds ?? 0
            // Energy decides; the duration escape hatch only covers true blips —
            // a LOUD "Hi!" with a dropped transcript is a real failure (F9a),
            // however short now that recording stops at key-up.
            if peak < Self.silencePeakThreshold || (duration < 0.6 && peak < Self.shortClipSpeechPeak) {
                lastSilenceReason = .noSpeech
                apply(.silenceOnly)
                discardSessionArtifacts()
                session = nil
                return
            }
            // Loud room, nothing rising above it. The model is right that there is
            // no speech here, and calling it a failure hands the user an error
            // earcon, a red pill and a Retry that can never succeed — for the same
            // gesture that reads as a soft "didn't catch that" in a quiet room.
            // Classify honestly, but KEEP the recording: a high absolute peak means
            // we might be wrong, and Retry has to still exist when we are.
            if let snr = noiseFloor.measuredSNR,
               snr < Self.emptyTranscriptSNRThreshold {
                Log.audio.info("empty transcript with only \(snr, format: .fixed(precision: 1))dB above the room — no speech, not a failure")
                // NOT .silent: HistoryStore's visible filter ends with
                // `AND status != 'silent'`, and RetentionPolicy treats .silent as
                // purge-eligible — so a .silent row is invisible AND its audio is
                // deleted, while the pill says "saved to History". .failed is in
                // the visible set and gets a Retry button, and "tooNoisy" is not
                // in retryableRecords()'s auto-drain list, so nothing re-uploads
                // on its own.
                updateMeta { $0.status = .failed; $0.errorCode = "tooNoisy" }
                lastSilenceReason = .tooNoisy
                apply(.silenceOnly)
                session = nil
                return
            }
        }
        // Offline is not a failure — the audio queues and drains on reconnect (F1).
        if case .some(.offline) = error as? TranscriptionError {
            updateMeta { $0.status = .queuedForRetry; $0.errorCode = "offline" }
            apply(.queuedForRetry)
            session = nil
            return
        }
        let (failure, code, detail) = Self.classify(error)
        updateMeta { $0.status = .failed; $0.errorCode = code; $0.errorMessage = detail }
        apply(.transcriptFailed(failure))
        session = nil
    }

    /// A detached job has no pill of its own: a no-speech result is dropped
    /// quietly, and anything else is kept in History and reported.
    private func failDetached(_ job: Session, error: Error) {
        defer { endDetached(job.id) }
        if case .some(.emptyTranscript) = error as? TranscriptionError, job.peakLevel < Self.silencePeakThreshold {
            try? FileManager.default.removeItem(at: job.folder)
            onSessionDiscard?(job.id)
            return
        }
        if case .some(.offline) = error as? TranscriptionError {
            updateMeta(job.id) { $0.status = .queuedForRetry; $0.errorCode = "offline" }
            onDetachedResult?(.outcome(.queuedForRetry))
            return
        }
        let (failure, code, detail) = Self.classify(error)
        updateMeta(job.id) { $0.status = .failed; $0.errorCode = code; $0.errorMessage = detail }
        onDetachedResult?(.failure(failure))
    }

    private static func classify(_ error: Error) -> (DictationFailure, String, String?) {
        let failure: DictationFailure
        let code: String
        var detail: String?
        switch error as? TranscriptionError {
        case .offline: failure = .network; code = "offline" // handled above
        case .badRequest(let message):
            failure = .badRequest; code = "bad_request"; detail = message
        case .modelUnavailable(let model, let message):
            failure = .modelAccess; code = "model"
            detail = message ?? "model \(model) not accessible"
        case .network: failure = .network; code = "network"
        case .auth: failure = .auth; code = "auth"
        case .rateLimitedDaily: failure = .quotaExhausted; code = "quota"
        case .rateLimitedTransient: failure = .rateLimited; code = "rate_limit"
        case .timeout: failure = .timeout; code = "timeout"
        case .emptyTranscript: failure = .validation; code = "empty"
        case .safetyBlocked: failure = .safetyBlocked; code = "safety"
        case nil: failure = .network; code = "unknown"
        }
        return (failure, code, detail)
    }

    private func cancelSession(hint: String?) {
        // The machine decides first; side effects only on an ACCEPTED cancel
        // (audit finding #10 — a rejected cancel must not corrupt meta/session).
        guard apply(.cancel) else {
            coachingHint = hint
            return
        }
        finishScreenContext()
        inFlightTask?.cancel() // stop the network work too (audit L8)
        inFlightTask = nil
        micLevel = 0
        coachingHint = hint // feedback is immediate; the bookkeeping can wait

        // Teardown is async (it drains the HAL tail), so the keep-or-discard
        // decision — which needs the real recorded duration — completes after it.
        // The pill is already showing cancelled, so nothing visible waits.
        // A new recording may start while the stop drains, so the decision
        // is made for the session cancelled here, not whichever is current.
        let cancelled = session
        if let engine = capture {
            capture = nil
            Task { @MainActor [weak self] in
                let result = await engine.stop()
                self?.completeCancel(cancelled, result: result)
            }
            return
        }
        // ⌘Esc with a Command trigger: the ⌘ press already began finalizing,
        // so the real duration arrives with that stop, not from meta.
        if let stop = pendingStop {
            pendingStop = nil
            Task { @MainActor [weak self] in
                let result = await stop.value
                self?.completeCancel(cancelled, result: result)
            }
            return
        }
        completeCancel(cancelled, result: nil)
    }

    private func completeCancel(_ cancelled: Session?, result: AudioCaptureResult?) {
        guard let cancelled else { return }
        let isCurrent = session?.id == cancelled.id
        guard var target = isCurrent ? session : cancelled else { return }
        // Post-finalize cancels have no live capture — fall back to the duration
        // finalizeSession already persisted, or Esc-during-transcription reads 0
        // and destroys a recording of ANY length (production pass 2, P0).
        let duration = result?.durationSeconds ?? target.meta.audioDurationSeconds ?? 0
        let hasTranscript = target.meta.rawTranscript != nil
        if hasTranscript || duration >= Self.cancelKeepThreshold {
            // Long cancels stay recoverable — History shows them with Retry.
            target.meta.status = .cancelled
            target.meta.audioDurationSeconds = target.meta.audioDurationSeconds ?? duration
            target.meta.write(to: target.folder)
            onSessionUpdate?(target.meta, target.folder)
            // Said once the duration is known, so a cancel that leaves no
            // trace never promises a row that is not there.
            if isCurrent { coachingHint = "Cancelled. Kept in History with Retry" }
        } else {
            // Blips and short deliberate cancels leave no trace: the pill already
            // gave feedback in the moment; hidden audio is pure liability.
            try? FileManager.default.removeItem(at: target.folder)
            onSessionDiscard?(target.id)
        }
        if isCurrent { session = nil }
    }

    private func finishScreenContext() {
        guard let collector = screenContextCollector else { return }
        screenContextCollector = nil
        let images = collector.stop()
        guard var session else { return }
        session.context.screenshots = images
        self.session = session
    }

    /// Removes the session folder and asks the app to drop its History row.
    private func discardSessionArtifacts() {
        guard let session else { return }
        try? FileManager.default.removeItem(at: session.folder)
        onSessionDiscard?(session.id)
    }

    // MARK: - Machine plumbing

    @discardableResult
    private func apply(_ event: DictationEvent) -> Bool {
        guard let next = DictationStateMachine.transition(state, on: event) else {
            Log.session.debug("ignored event \(String(describing: event), privacy: .public) in \(String(describing: self.state), privacy: .public)")
            return false
        }
        state = next
        Log.session.info("state → \(String(describing: next), privacy: .public)")
        return true
    }

    private func updateMeta(_ mutate: (inout SessionMeta) -> Void) {
        guard let id = session?.id else { return }
        updateMeta(id, mutate)
    }

    private func updateMeta(_ id: UUID, _ mutate: (inout SessionMeta) -> Void) {
        guard var job = job(id) else { return }
        mutate(&job.meta)
        job.meta.write(to: job.folder)
        if session?.id == id { session = job } else { detached[id] = job }
        onSessionUpdate?(job.meta, job.folder)
    }
}
