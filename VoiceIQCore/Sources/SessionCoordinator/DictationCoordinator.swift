import Foundation

/// The brain: translates hotkey intents into session lifecycle via the pure
/// DictationStateMachine, drives audio → transcription → insertion, and owns the
/// per-session folder + meta.json writes.
///
/// M2 scope: one session at a time (overlapping in-flight sessions arrive with M3's
/// async transcription). All state hops through the main actor.
@MainActor
public final class DictationCoordinator: ObservableObject {
    // Observable surface for the HUD / status item.
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var micLevel: Float = 0
    @Published public private(set) var lastResult: String?
    @Published public private(set) var coachingHint: String?
    @Published public private(set) var modeFailureMessage: String?
    @Published public private(set) var partialTranscript = ""
    private var partialPump: Task<Void, Never>?

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
    }

    /// Below this metered peak the user simply didn't speak (F9b). Scale matches
    /// AudioCaptureEngine's onLevel; whisper-quiet speech peaks well above it.
    static let silencePeakThreshold: Float = 0.06
    /// Clips shorter than this can't contain a word — never sent to the API
    /// (dogfood: a 0.19s blip got uploaded, errored, and showed as Failed).
    static let minimumSendableDuration: Double = 0.4
    /// Zero frames on a hold shorter than this is an accidental blip, not an
    /// engine failure — the first buffer simply hadn't arrived yet.
    static let blipHoldThreshold: TimeInterval = 0.8
    /// Releasing the key a beat before the last word is finished is a NORMAL
    /// human gesture — the hand anticipates the mouth. When the user is still
    /// speaking at key-up, keep capturing until they actually stop.
    /// Costs nothing in the common case: already-quiet releases stop instantly.
    static let trailingSpeechThreshold: Float = 0.08
    /// Quiet this long ⇒ they finished the word.
    static let trailingQuietToStop: TimeInterval = 0.25
    /// Hard cap so a noisy room can never hold a session open. On iPhone the
    /// stop is a tap on the keyboard, made after looking at the screen, so the
    /// hand rarely runs ahead of the mouth and a long tail only adds wait.
    #if os(iOS)
    static let trailingCaptureCap: TimeInterval = 0.6
    #else
    static let trailingCaptureCap: TimeInterval = 1.5
    #endif
    /// How far above the measured room a level must sit to still read as speech.
    /// Only ever raises the bar from `trailingSpeechThreshold`, never lowers it.
    static let trailingFloorMarginDB: Double = 3
    /// The session must have shown at least this much separation between speech
    /// and room before we trust its energy readings enough to stop early. Below
    /// it we keep today's behaviour: run to the cap and never clip a word.
    static let trailingTrustSNR: Double = 12
    /// A mis-estimated floor must never make ordinary speech read as quiet.
    static let trailingRelativeCap: Float = 0.30
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
            partialPump?.cancel()
            partialPump = nil
            partialTranscript = ""
            if let live = liveTranscriber {
                liveTranscriber = nil
                let scope = oldValue.map { UsageScope(mode: $0.context.mode, sessionID: $0.id.uuidString) }
                Task { await UsageMeter.$scope.withValue(scope) { await live.abort() } }
            }
            if oldValue != nil, let collector = screenContextCollector {
                screenContextCollector = nil
                _ = collector.stop()
            }
        }
    }
    private var capture: AudioCapturing?
    private var liveTranscriber: (any DictationStreaming)?
    private var screenContextCollector: ScreenContextCollector?
    /// Most recent metered level — decides whether the user was mid-word when
    /// they released the key.
    private var latestLevel: Float = 0
    /// How loud the room is. Always measured, never in charge: what it feeds is
    /// gated on `noiseHandlingActive`, what it records is not.
    private var noiseFloor = NoiseFloorEstimator()
    /// Why the last session ended with no speech — the pill copy differs, nothing
    /// else does, so this rides alongside the outcome instead of widening the
    /// state machine for a string.
    public private(set) var lastSilenceReason: SilenceReason = .noSpeech
    /// The experiment's state, read ONCE at key-down. A toggle flipped while the
    /// pill is up must not change the rules the recording is judged by.
    private var noiseHandlingActive = false
    /// Space-lock (or UI hands-free) that arrived while the engine was still
    /// coming up — applied on engineStarted, cleared when the session ends.
    private var pendingLockIn = false

    /// Fired after every meta.json write — the app mirrors sessions into HistoryStore.
    public var onSessionUpdate: ((SessionMeta, URL) -> Void)?
    /// Fired when a session's artifacts were discarded entirely (blips, no-speech,
    /// short cancels) — the app removes its History row. Disk mirrors the UI:
    /// what History doesn't show, we don't store.
    public var onSessionDiscard: ((UUID) -> Void)?
    public var onAnswerReady: ((String) -> Void)?
    public var onAgentCommandReady: ((TranscriptionResult) -> Void)?

    /// Cancelled recordings at least this long stay recoverable in History —
    /// an accidental Esc after minutes of dictation must not destroy the words.
    static let cancelKeepThreshold: Double = 10

    private let audioFactory: @MainActor () -> AudioCapturing
    private let liveFactory: @MainActor (URL) -> (any DictationStreaming)?
    private let transcription: TranscriptionServicing
    private let insertion: TextInserting
    private let contextProvider: @MainActor () -> DictationContext
    /// Injectable clock so hold-duration classification is testable.
    private let now: () -> Date
    /// Injectable so the noise behaviours can be exercised both ways headlessly,
    /// without a UserDefaults round-trip in the test.
    private let noiseHandlingEnabled: @MainActor () -> Bool
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
        liveFactory: @escaping @MainActor (URL) -> (any DictationStreaming)? = { _ in nil },
        now: @escaping () -> Date = Date.init,
        noiseHandlingEnabled: @escaping @MainActor () -> Bool = { SettingsStore().experimentalNoiseHandling },
        secureInputActive: @escaping @MainActor () -> Bool = { SecureInput.isActive }
    ) {
        self.audioFactory = audioFactory
        self.transcription = transcription
        self.insertion = insertion
        self.contextProvider = contextProvider
        self.liveFactory = liveFactory
        self.now = now
        self.noiseHandlingEnabled = noiseHandlingEnabled
        self.secureInputActive = secureInputActive
    }

    // MARK: - Hotkey entry point

    /// Returns whether the intent was ACCEPTED — a refused .begin (secure field,
    /// session already active) must reach the hotkey grammar, or the next press
    /// of the key would read as a stop.
    @discardableResult
    public func handle(_ intent: HotkeyIntent) -> Bool {
        handle(intent, mode: .dictate)
    }

    @discardableResult
    public func handle(
        _ intent: HotkeyIntent,
        mode: DictationMode,
        selectedTextIsSettable: Bool = false
    ) -> Bool {
        switch intent {
        case .begin:
            return beginSession(mode: mode, selectedTextIsSettable: selectedTextIsSettable)
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
    private func beginSession(
        mode: DictationMode = .dictate,
        selectedTextIsSettable: Bool = false
    ) -> Bool {
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
        modeFailureMessage = nil
        pendingLockIn = false // never inherit a stale latch from a dead session
        apply(.hotkeyBegin)

        let id = UUID()
        let startedAt = now()
        do {
            let folder = try FileLayout.makeSessionFolder(id: id, now: startedAt)
            var meta = SessionMeta(id: id, startedAt: startedAt, status: .recording)
            var context = contextProvider()
            context.mode = mode
            context.selectedTextIsSettable = selectedTextIsSettable
            meta.targetAppBundleID = context.targetAppBundleID
            meta.targetAppName = context.targetAppName
            meta.write(to: folder)
            session = Session(id: id, folder: folder, startedAt: startedAt, context: context, meta: meta)

            if mode == .dictate, SettingsStore().screenContextEnabled {
                let collector = ScreenContextCollector()
                screenContextCollector = collector
                collector.start()
            }

            noiseFloor = NoiseFloorEstimator()
            noiseHandlingActive = noiseHandlingEnabled()

            let capture = audioFactory()
            self.capture = capture
            let live = liveFactory(FileLayout.audioCAF(in: folder))
            liveTranscriber = live
            if let live {
                capture.setPCMSink { pcm in live.enqueue(pcm) }
                partialPump = Task { [weak self] in
                    for await text in live.partials {
                        guard let self, !Task.isCancelled, self.session?.id == id else { return }
                        guard case .recording = self.state else { continue }
                        self.partialTranscript = text
                    }
                }
            } else {
                capture.setPCMSink(nil)
            }
            capture.onLevel = { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.ingestLevel(level, updatingMeter: true)
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

    /// The ONE place levels enter the coordinator.
    ///
    /// `captureTrailingSpeech` reassigns `capture.onLevel`, replacing the closure
    /// installed at session start. Both paths must feed the estimator or it
    /// starves in exactly the window that needs it most — the moment after key-up
    /// when we are deciding whether the user is still talking.
    private func ingestLevel(_ level: Float, updatingMeter: Bool) {
        if updatingMeter { micLevel = level }
        latestLevel = level
        noiseFloor.ingest(level: level)
    }

    /// The level below which the user has stopped talking.
    ///
    /// Absolute by default. With the experiment on it rises to sit just above a
    /// loud room — but only UPWARD from the absolute threshold, and only when the
    /// session has proved it can tell speech from the room at all. Without that
    /// separation the energy signal is not trustworthy, so we keep today's
    /// behaviour and pay the full cap rather than risk clipping a word.
    private func currentTrailingThreshold() -> Float {
        guard noiseHandlingActive,
              let floorDB = noiseFloor.floorDB,
              let snr = noiseFloor.measuredSNR,
              snr >= Self.trailingTrustSNR
        else { return Self.trailingSpeechThreshold }
        let targetDB = floorDB + Self.trailingFloorMarginDB
        let relative = AudioLevelCurve.level(fromRMS: Float(pow(10, targetDB / 20)))
        return min(Self.trailingRelativeCap, max(Self.trailingSpeechThreshold, relative))
    }

    private func finalizeSession() {
        guard let sessionID = session?.id else { return }
        // The machine decides first; side effects only on an ACCEPTED finalize
        // (same pattern as cancelSession, audit #10). A second stop while a
        // session is in flight must not stop capture or clobber meta.
        guard apply(.finalize) else { return }
        partialPump?.cancel()
        partialPump = nil
        partialTranscript = ""
        finishScreenContext()
        // Hand the engine off and release it immediately: stop() now drains the
        // HAL's in-flight buffer (~50ms mean of real speech) and tears the graph
        // down — tens to hundreds of ms that must not freeze the main actor. The
        // pill is already showing .finalizing, so the wait is visually covered.
        let engine = capture
        capture = nil
        let wasSpeaking = latestLevel >= currentTrailingThreshold()
        micLevel = 0
        Task { @MainActor [weak self] in
            if wasSpeaking, let engine {
                await self?.captureTrailingSpeech(from: engine)
            }
            let result = await engine?.stop() ?? AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
            guard self?.session?.id == sessionID else { return }
            self?.completeFinalize(result: result)
        }
    }

    /// Keep the mic open past key-up until the user actually stops talking.
    /// Returns as soon as they're quiet — capped so it can never hang.
    private func captureTrailingSpeech(from engine: AudioCapturing) async {
        // Real elapsed time, not the injectable session clock: this is about how
        // long actual audio keeps arriving.
        let start = DispatchTime.now()
        func elapsed(since mark: DispatchTime) -> TimeInterval {
            Double(DispatchTime.now().uptimeNanoseconds - mark.uptimeNanoseconds) / 1_000_000_000
        }
        var quietSince: DispatchTime?
        // The engine keeps reporting levels after key-up; watch them directly.
        engine.onLevel = { [weak self] level in
            // updatingMeter: false — the pill already shows .finalizing; this is
            // about hearing whether they are still talking, not drawing bars.
            Task { @MainActor [weak self] in self?.ingestLevel(level, updatingMeter: false) }
        }
        while elapsed(since: start) < Self.trailingCaptureCap {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if latestLevel < currentTrailingThreshold() {
                let since = quietSince ?? DispatchTime.now()
                quietSince = since
                if elapsed(since: since) >= Self.trailingQuietToStop { break }
            } else {
                quietSince = nil
            }
        }
        let carried = elapsed(since: start)
        Log.audio.info("carried capture \(carried * 1000, format: .fixed(precision: 0))ms past key-up — you were still talking")
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
            Log.audio.info("room \(roomFloorDB, format: .fixed(precision: 1))dBFS, speech \(speechPeakDB, format: .fixed(precision: 1))dBFS, separation \(separation, format: .fixed(precision: 1))dB\(self.noiseHandlingActive ? " [experiment on]" : "")")
        }

        // Micro-clips can't contain a word — classify locally, never upload
        // (the API errors on them, which used to surface as Failed).
        guard result.durationSeconds >= Self.minimumSendableDuration else {
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

        let sessionID = session.id
        let finalizeStartedAt = Date()
        let live = liveTranscriber
        let usageScope = UsageScope(mode: session.context.mode, sessionID: sessionID.uuidString)
        inFlightTask = Task { [weak self] in
          await UsageMeter.$scope.withValue(usageScope) {
            guard let self else { return }
            do {
                let liveResult = await live?.finish(framesWritten: result.framesWritten)
                try Task.checkCancellation()
                let outcome: TranscriptionResult
                if let liveResult {
                    outcome = try await self.transcription.process(
                        liveResult, durationSeconds: result.durationSeconds, context: session.context
                    )
                } else {
                    outcome = try await self.transcription.transcribe(
                        audioURL: FileLayout.audioCAF(in: session.folder),
                        durationSeconds: result.durationSeconds,
                        context: session.context
                    )
                }
                guard !Task.isCancelled else { return }
                await self.completeTranscription(sessionID: sessionID, outcome: outcome, startedAt: finalizeStartedAt)
            } catch {
                guard !Task.isCancelled else { return }
                await self.failTranscription(sessionID: sessionID, error: error)
            }
          }
        }
    }

    private func completeTranscription(sessionID: UUID, outcome: TranscriptionResult, startedAt: Date) async {
        guard session?.id == sessionID else { return } // stale completion
        updateMeta {
            $0.rawTranscript = outcome.rawTranscript
            $0.cleanedTranscript = outcome.cleanedTranscript
            $0.modelID = outcome.modelID
            $0.errorMessage = outcome.cleanupNote
            $0.status = .transcribing
        }
        apply(.transcriptReady)

        if session?.context.mode.handsTranscriptToCaller == true {
            lastResult = outcome.cleanedTranscript
            if session?.context.mode == .agent, let onAgentCommandReady {
                onAgentCommandReady(outcome)
            } else {
                onAnswerReady?(outcome.cleanedTranscript)
            }
            updateMeta { $0.status = .inserted; $0.pipelineSeconds = Date().timeIntervalSince(startedAt) }
            apply(.inserted)
            discardUnlessKept()
            session = nil
            return
        }

        let insertionOutcome = await insertion.insert(outcome.cleanedTranscript, context: session?.context ?? DictationContext())
        let pipelineSeconds = Date().timeIntervalSince(startedAt)
        switch insertionOutcome {
        case .inserted:
            updateMeta { $0.status = .inserted; $0.pipelineSeconds = pipelineSeconds }
            apply(.inserted)
        case .frontmostChanged:
            updateMeta { $0.status = .awaitingChip; $0.pipelineSeconds = pipelineSeconds }
            apply(.frontmostChangedAwaitingChip)
        case .fellBackToClipboard:
            updateMeta { $0.status = .copiedToClipboard; $0.pipelineSeconds = pipelineSeconds }
            apply(.insertionFellBackToClipboard)
        case .blockedSecureField:
            updateMeta { $0.status = .heldSecure; $0.pipelineSeconds = pipelineSeconds }
            apply(.insertionBlockedSecure)
        }
        lastResult = outcome.cleanedTranscript
        session = nil
    }

    private func failTranscription(sessionID: UUID, error: Error) async {
        guard session?.id == sessionID else { return }
        if session?.context.mode != .dictate {
            if case .translate(let target) = session?.context.mode {
                modeFailureMessage = "Couldn't translate to \(target)"
            }
            updateMeta { $0.status = .failed; $0.errorCode = "mode_transform" }
            apply(.transcriptFailed(.network))
            discardUnlessKept()
            session = nil
            return
        }
        // Empty transcript: silence is judged by AUDIO ENERGY, not duration —
        // a long quiet hold is "no speech", never "Failed" (F9b; dogfood bug).
        // Speech energy present but no transcript = real failure, retryable (F9a).
        if case .some(.emptyTranscript) = error as? TranscriptionError {
            let peak = session?.peakLevel ?? 1.0
            let duration = session?.meta.audioDurationSeconds ?? 0
            // Energy decides; the duration escape hatch only covers true blips —
            // a LOUD 1s "Hi!" with a dropped transcript is a real failure (F9a).
            if peak < Self.silencePeakThreshold || duration < 0.6 {
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
            if noiseHandlingActive,
               let snr = noiseFloor.measuredSNR,
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
        updateMeta { $0.status = .failed; $0.errorCode = code; $0.errorMessage = detail }
        apply(.transcriptFailed(failure))
        session = nil
    }

    private func cancelSession(hint: String?) {
        // The machine decides first; side effects only on an ACCEPTED cancel
        // (audit finding #10 — a rejected cancel must not corrupt meta/session).
        guard apply(.cancel) else {
            coachingHint = hint
            return
        }
        finishScreenContext()
        if let live = liveTranscriber {
            let scope = session.map { UsageScope(mode: $0.context.mode, sessionID: $0.id.uuidString) }
            liveTranscriber = nil
            Task { await UsageMeter.$scope.withValue(scope) { await live.abort() } }
        }
        inFlightTask?.cancel() // stop the network work too (audit L8)
        inFlightTask = nil
        micLevel = 0
        coachingHint = hint // feedback is immediate; the bookkeeping can wait

        // Teardown is async (it drains the HAL tail), so the keep-or-discard
        // decision — which needs the real recorded duration — completes after it.
        // The pill is already showing cancelled, so nothing visible waits.
        if let engine = capture {
            capture = nil
            Task { @MainActor [weak self] in
                let result = await engine.stop()
                self?.completeCancel(result: result)
            }
            return
        }
        completeCancel(result: nil)
    }

    private func completeCancel(result: AudioCaptureResult?) {
        // Post-finalize cancels have no live capture — fall back to the duration
        // finalizeSession already persisted, or Esc-during-transcription reads 0
        // and destroys a recording of ANY length (production pass 2, P0).
        let duration = result?.durationSeconds ?? session?.meta.audioDurationSeconds ?? 0
        let hasTranscript = session?.meta.rawTranscript != nil
        let keeps = session?.context.mode.keepsRecording ?? true
        if keeps, hasTranscript || duration >= Self.cancelKeepThreshold {
            // Long cancels stay recoverable — History shows them with Retry.
            updateMeta {
                $0.status = .cancelled
                $0.audioDurationSeconds = $0.audioDurationSeconds ?? duration
            }
        } else {
            // Blips and short deliberate cancels leave no trace: the pill already
            // gave feedback in the moment; hidden audio is pure liability.
            discardSessionArtifacts()
        }
        session = nil
    }

    private func finishScreenContext() {
        guard let collector = screenContextCollector else { return }
        screenContextCollector = nil
        let images = collector.stop()
        guard var session else { return }
        session.context.screenshots = images
        self.session = session
    }

    /// Agent commands leave no History row; the agent run keeps the text.
    private func discardUnlessKept() {
        guard session?.context.mode.keepsRecording == false else { return }
        discardSessionArtifacts()
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
        guard var session else { return }
        mutate(&session.meta)
        session.meta.write(to: session.folder)
        self.session = session
        onSessionUpdate?(session.meta, session.folder)
    }
}
