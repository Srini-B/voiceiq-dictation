import XCTest
@testable import VoiceIQCore

@MainActor
final class DictationCoordinatorTests: XCTestCase {

    // MARK: Fakes

    /// Sendable by hand: each test drives it one step at a time, so its
    /// state is never touched from two places at once.
    final class FakeCapture: AudioCapturing, @unchecked Sendable {
        var onLevel: (@Sendable (Float) -> Void)?
        var onDeviceChange: (@Sendable (String) -> Void)?
        var onWriteFailure: (@Sendable () -> Void)?
        var onEngineDied: (@Sendable (String) -> Void)?
        var startError: Error?
        var result = AudioCaptureResult(framesWritten: 16_000, durationSeconds: 1.0)
        private(set) var started = false
        private(set) var stopCount = 0

        func start(writingTo url: URL) throws {
            if let startError { throw startError }
            started = true
        }
        func stop() async -> AudioCaptureResult {
            stopCount += 1
            return result
        }
    }

    struct FakeTranscription: TranscriptionServicing {
        var result: Result<TranscriptionResult, TranscriptionError> =
            .success(TranscriptionResult(rawTranscript: "raw", cleanedTranscript: "clean", modelID: "test"))
        /// Simulates a slow round-trip so tests can act mid-flight.
        var delayNanos: UInt64 = 0
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
            if delayNanos > 0 {
                try? await Task.sleep(nanoseconds: delayNanos)
            }
            switch result {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }

    final class FakeInserter: TextInserting {
        var outcome: InsertionOutcome = .inserted
        private(set) var insertedText: String?
        func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
            insertedText = text
            return outcome
        }
    }

    private var capture: FakeCapture!
    private var inserter: FakeInserter!
    private var fakeNow = Date()
    private var sandbox: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Never touch the user's real recordings from tests.
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-tests-\(UUID().uuidString)", isDirectory: true)
        FileLayout.overrideRoot = sandbox
    }

    override func tearDown() async throws {
        FileLayout.overrideRoot = nil
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        try await super.tearDown()
    }

    private func makeCoordinator(
        transcription: FakeTranscription = FakeTranscription(),
        noiseHandling: Bool = false,
        secureInput: Bool = false
    ) -> DictationCoordinator {
        capture = FakeCapture()
        inserter = FakeInserter()
        fakeNow = Date()
        let coordinator = DictationCoordinator(
            audioFactory: { [capture] in capture! },
            transcription: transcription,
            insertion: inserter,
            now: { [weak self] in self?.fakeNow ?? Date() },
            // Explicit, never read from UserDefaults: a developer with the
            // experiment switched on must not get different test results.
            noiseHandlingEnabled: { noiseHandling },
            // Never read the host's real secure-input state: it is system-wide,
            // and a stuck loginwindow or Terminal's Secure Keyboard Entry would
            // fail every begin-a-session test for reasons unrelated to the code.
            secureInputActive: { secureInput }
        )
        lastCoordinator = coordinator
        return coordinator
    }

    private var lastCoordinator: DictationCoordinator?

    /// Drain the deferred engine start (begin queues it one main-actor tick out
    /// so the pill can paint before the engine blocks — the latency fix).
    private func pump() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func settle() async {
        // Drain the finalize Task chain — poll for a terminal state rather than a
        // fixed yield count (which flaked under cold-start scheduling variance).
        for _ in 0..<200 {
            if lastCoordinator?.state.isTerminal ?? true { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: Tests

    /// Recording ends at key-up, even mid-word: no listening past it.
    func testReleaseMidWordStopsImmediately() async {
        let c = makeCoordinator()
        c.handle(.begin)
        await pump()
        capture.onLevel?(0.9) // loud speech at the moment of release
        await pump()
        c.handle(.finalize)
        await pump()
        XCTAssertEqual(capture.stopCount, 1)
        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
    }

    func testHappyPathInserts() async {
        let c = makeCoordinator()
        c.handle(.begin)
        await pump()
        XCTAssertEqual(c.state, .recording(locked: false))
        XCTAssertTrue(capture.started)

        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
        XCTAssertEqual(inserter.insertedText, "clean")
        XCTAssertEqual(c.lastResult, "clean")
    }

    /// History shows each step of an uploaded dictation: the upload's
    /// transcription without the writing model's share, which is its own row.
    func testInsertedDictationKeepsItsStepTimes() async throws {
        var transcription = FakeTranscription()
        var result = TranscriptionResult(rawTranscript: "raw", cleanedTranscript: "clean", modelID: "test")
        result.writingSeconds = 0.2
        transcription.result = .success(result)
        transcription.delayNanos = 300_000_000
        let c = makeCoordinator(transcription: transcription)
        var last: SessionMeta?
        c.onSessionUpdate = { meta, _ in last = meta }
        c.handle(.begin)
        await pump()
        c.handle(.finalize)
        for _ in 0..<200 where !c.state.isTerminal { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(c.state, .done(.inserted))

        let steps = try XCTUnwrap(last?.steps)
        XCTAssertFalse(steps.live)
        XCTAssertEqual(steps.writing, 0.2)
        XCTAssertEqual(steps.transcription, 0.1, accuracy: 0.08, "the 0.3 s upload minus its 0.2 s writing share")
        XCTAssertNotNil(steps.insert)
        let pipeline = try XCTUnwrap(last?.pipelineSeconds)
        let sum = steps.finishRecording + steps.transcription + (steps.writing ?? 0) + (steps.insert ?? 0)
        XCTAssertEqual(pipeline, sum, accuracy: 0.01, "the steps add up to the pipeline shown above them")
    }

    /// An Ask result goes to the answer card, not the field: its last step
    /// is the hand-off, and the steps still add up to the pipeline.
    func testAnsweredDictationKeepsItsHandoffTime() async throws {
        var transcription = FakeTranscription()
        var result = TranscriptionResult(rawTranscript: "raw", cleanedTranscript: "answer", modelID: "test")
        result.writingSeconds = 0.2
        transcription.result = .success(result)
        transcription.delayNanos = 300_000_000
        let c = makeCoordinator(transcription: transcription)
        var last: SessionMeta?
        var answer: String?
        c.onSessionUpdate = { meta, _ in last = meta }
        c.onAnswerReady = { answer = $0 }
        c.handle(.begin, mode: .askAnything(selectedText: nil))
        await pump()
        c.handle(.finalize)
        for _ in 0..<200 where !c.state.isTerminal { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(answer, "answer")
        XCTAssertNil(inserter.insertedText)

        let steps = try XCTUnwrap(last?.steps)
        XCTAssertNil(steps.insert)
        XCTAssertNotNil(steps.handoff)
        XCTAssertEqual(steps.rows.last?.label, "Hand-off")
        let pipeline = try XCTUnwrap(last?.pipelineSeconds)
        let sum = steps.finishRecording + steps.transcription + (steps.writing ?? 0) + (steps.handoff ?? 0)
        XCTAssertEqual(pipeline, sum, accuracy: 0.01, "the steps add up to the pipeline shown above them")
    }

    func testLockInMarksHandsFree() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.lockIn) // arrives during warming — latched, applied on engineStarted
        await pump()
        XCTAssertEqual(c.state, .recording(locked: true))
    }

    func testZeroFramesOnRealHoldIsNoAudioFailure() async {
        let c = makeCoordinator()
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
        fakeNow += 2.0 // a deliberate 2s hold with zero buffers = engine race (F21)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .failed(.noAudio))
        XCTAssertNil(inserter.insertedText)
    }

    func testZeroFramesOnQuickBlipIsSilent() async {
        let c = makeCoordinator()
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
        c.handle(.finalize) // released almost immediately — first buffer never landed
        await settle()
        XCTAssertEqual(c.state, .done(.silent), "an accidental blip is not a mic failure")
    }

    // Storage policy: what History doesn't show, we don't store.

    func testSilentSessionDiscardsArtifacts() async {
        let c = makeCoordinator()
        var discarded: UUID?
        c.onSessionDiscard = { discarded = $0 }
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 3_000, durationSeconds: 0.19)
        fakeNow += 2.0
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.silent))
        XCTAssertNotNil(discarded, "micro-clip artifacts must be discarded")
    }

    func testShortCancelDiscardsButLongCancelKeeps() async {
        let c = makeCoordinator()
        var discarded: UUID?
        c.onSessionDiscard = { discarded = $0 }
        // Short cancel → discard.
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 16_000, durationSeconds: 1.0)
        c.handle(.cancel)
        await pump()
        XCTAssertNotNil(discarded, "1s cancel leaves no trace")
        // Long cancel → kept (recoverable from History).
        discarded = nil
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 16_000 * 60, durationSeconds: 60)
        c.handle(.cancel)
        await pump()
        XCTAssertNil(discarded, "a 60s cancelled recording stays recoverable")
    }

    func testMicroClipNeverUploads() async {
        var t = FakeTranscription()
        t.result = .failure(.network("should never be called")) // upload would fail loudly
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 3_000, durationSeconds: 0.19)
        fakeNow += 2.0
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.silent), "0.19s can't contain a word — classified locally")
    }

    /// A short word released at once is transcribed; a short quiet clip is not.
    func testShortClipIsSentOnlyWhenClearlySpoken() async {
        var t = FakeTranscription()
        t.result = .failure(.network("should never be called"))
        let quiet = makeCoordinator(transcription: t)
        quiet.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 4_800, durationSeconds: 0.3, peakLevel: 0.12)
        fakeNow += 2.0
        quiet.handle(.finalize)
        await settle()
        XCTAssertEqual(quiet.state, .done(.silent), "room tone in a short tap is not a word")

        let spoken = makeCoordinator()
        spoken.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 4_800, durationSeconds: 0.3, peakLevel: 0.9)
        fakeNow += 2.0
        spoken.handle(.finalize)
        await settle()
        XCTAssertEqual(spoken.state, .done(.inserted), "a loud 0.3 s \"Hi\" must not be deleted unheard")

        // Sent but answered with no text: a failure to retry, not silence to delete.
        var empty = FakeTranscription()
        empty.result = .failure(.emptyTranscript)
        let dropped = makeCoordinator(transcription: empty, noiseHandling: false)
        var discarded: [UUID] = []
        dropped.onSessionDiscard = { discarded.append($0) }
        dropped.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 4_800, durationSeconds: 0.3, peakLevel: 0.9)
        fakeNow += 2.0
        dropped.handle(.finalize)
        await settle()
        XCTAssertNotEqual(dropped.state, .done(.silent))
        XCTAssertTrue(discarded.isEmpty, "the recording stays for Retry")
    }

    func testEngineStartFailureNamesTheMissingMic() async {
        let c = makeCoordinator()
        capture.startError = AudioCaptureEngine.CaptureError.noInputDevice
        var discarded: UUID?
        c.onSessionDiscard = { discarded = $0 }
        c.handle(.begin)
        await pump()
        // Honest taxonomy: no input device ≠ "mic didn't start"; and zero frames
        // means nothing storable — no dead-end Failed row (production pass 2).
        XCTAssertEqual(c.state, .failed(.noMicrophone))
        XCTAssertNotNil(discarded)
    }

    func testTranscriptionAuthFailure() async {
        var t = FakeTranscription()
        t.result = .failure(.auth)
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .failed(.auth))
    }

    // Production pass 2 P0: Esc during transcription must honor the keep rule
    // using the PERSISTED duration — capture is gone by then, and reading 0
    // destroyed recordings of any length.

    func testEscDuringTranscribingKeepsLongRecording() async {
        var t = FakeTranscription()
        t.delayNanos = 2_000_000_000 // still in flight when cancel lands
        let c = makeCoordinator(transcription: t)
        capture.result = AudioCaptureResult(framesWritten: 16_000 * 60, durationSeconds: 60)
        var discarded: UUID?
        c.onSessionDiscard = { discarded = $0 }
        var lastMeta: SessionMeta?
        c.onSessionUpdate = { meta, _ in lastMeta = meta }

        c.handle(.begin)
        c.handle(.finalize)
        await pump()
        XCTAssertEqual(c.state, .transcribing)
        c.handle(.cancel)

        XCTAssertEqual(c.state, .cancelled)
        XCTAssertNil(discarded, "a 60s recording must survive an in-flight Esc")
        XCTAssertEqual(lastMeta?.status, .cancelled)
        XCTAssertEqual(lastMeta?.audioDurationSeconds, 60)
    }

    func testEscDuringTranscribingStillDiscardsShortRecording() async {
        var t = FakeTranscription()
        t.delayNanos = 2_000_000_000
        let c = makeCoordinator(transcription: t)
        capture.result = AudioCaptureResult(framesWritten: 16_000 * 3, durationSeconds: 3)
        var discarded: UUID?
        c.onSessionDiscard = { discarded = $0 }

        c.handle(.begin)
        c.handle(.finalize)
        c.handle(.cancel)

        XCTAssertEqual(c.state, .cancelled)
        // The keep-or-discard decision waits for the engine stop.
        for _ in 0..<200 where discarded == nil {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNotNil(discarded, "a 3s deliberate cancel still discards")
    }

    // Production pass 2 P0: a second finalize while in flight must be a pure
    // no-op — it used to stop capture again and clobber meta to failed/no_audio.

    func testSecondFinalizeWhileInFlightIsIgnored() async {
        var t = FakeTranscription()
        t.delayNanos = 60_000_000
        let c = makeCoordinator(transcription: t)
        var statuses: [SessionMeta.Status] = []
        c.onSessionUpdate = { meta, _ in statuses.append(meta.status) }

        c.handle(.begin)
        c.handle(.finalize)
        await pump()
        XCTAssertEqual(c.state, .transcribing)
        c.handle(.finalize) // pill Stop double-click / second voiceiq://stop
        XCTAssertEqual(c.state, .transcribing)
        await pump()
        XCTAssertEqual(capture.stopCount, 1, "second finalize must not stop capture again")

        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
        XCTAssertFalse(statuses.contains(.failed), "no false Failed row from the double stop")
    }

    // A chord only reaches the coordinator within a second of the press, so
    // the session it cancels is the chord's own, hands-free or not.

    func testAccidentalChordCancelsYoungHandsFreeSession() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.lockIn)
        await pump()
        XCTAssertEqual(c.state, .recording(locked: true))
        c.handle(.abortAccidental)
        XCTAssertEqual(c.state, .cancelled)
    }

    func testAccidentalChordStillCancelsOwnYoungSession() async {
        let c = makeCoordinator()
        c.handle(.begin)
        await pump()
        XCTAssertEqual(c.state, .recording(locked: false))
        c.handle(.abortAccidental)
        XCTAssertEqual(c.state, .cancelled)
    }

    func testAccidentalChordIgnoredWhileInFlight() async {
        var t = FakeTranscription()
        t.delayNanos = 60_000_000
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        c.handle(.finalize)
        c.handle(.abortAccidental)
        await pump() // capture teardown (tail drain) completes off the main path
        XCTAssertEqual(c.state, .transcribing, "transcript is sacred")
        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
    }

    func testCancelStopsCapture() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.cancel)
        XCTAssertEqual(c.state, .cancelled, "feedback is immediate, teardown is not")
        await pump()
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertNil(inserter.insertedText)
    }

    // Audit #1: a stray begin must never destroy an in-flight session.

    func testBeginDuringTranscriptionDoesNotCancelIt() async {
        var t = FakeTranscription()
        t.delayNanos = 60_000_000 // 60ms in flight
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        c.handle(.finalize)
        XCTAssertFalse(c.handle(.begin), "refused: session active")
        await settle()
        XCTAssertEqual(c.state, .done(.inserted), "the in-flight transcript is sacred")
        XCTAssertEqual(inserter.insertedText, "clean")
    }

    func testCancelDuringInsertingRejectedCleanly() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
        // A stray cancel after completion must not corrupt anything (audit #10).
        c.handle(.cancel)
        XCTAssertEqual(c.state, .done(.inserted))
    }

    // Audit #3: permanent API failures are terminal, not retryable-forever.

    func testBadRequestSurfacesAsItsOwnFailure() async {
        var t = FakeTranscription()
        t.result = .failure(.badRequest("malformed request"))
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        c.handle(.finalize)
        await settle()
        // Surfaced as its own failure now — not buried under .validation.
        XCTAssertEqual(c.state, .failed(.badRequest))
    }

    // Silence is judged by audio energy, not duration (F9a vs F9b — dogfood bug).

    func testQuietLongHoldIsNoSpeechNotFailed() async {
        var t = FakeTranscription()
        t.result = .failure(.emptyTranscript)
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 48_000, durationSeconds: 3.0, peakLevel: 0.01)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.silent), "a quiet 3s hold is 'no speech', never Failed")
    }

    func testLoudShortUtteranceWithEmptyTranscriptIsAFailure() async {
        // Audit #13: a loud 1s "Hi!" that comes back empty is a dropped transcript.
        var t = FakeTranscription()
        t.result = .failure(.emptyTranscript)
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 16_000, durationSeconds: 1.0, peakLevel: 0.6)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .failed(.validation), "speech energy + no transcript = retryable failure")
    }

    func testEmptyTranscriptWithSpeechEnergyIsARealFailure() async {
        var t = FakeTranscription()
        t.result = .failure(.emptyTranscript)
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 48_000, durationSeconds: 3.0, peakLevel: 0.5)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .failed(.validation), "speech energy + no transcript = retryable failure")
    }

    func testClipboardFallbackOutcome() async {
        let c = makeCoordinator()
        c.handle(.begin)
        inserter.outcome = .fellBackToClipboard
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.copiedToClipboard))
    }

    func testBeginWhileActiveIsIgnored() {
        let c = makeCoordinator()
        c.handle(.begin)
        let stateBefore = c.state
        c.handle(.begin)
        XCTAssertEqual(c.state, stateBefore)
    }

    func testNewSessionAfterCompletion() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
        // FakeCapture is reused by the factory; reset its state via a new begin.
        c.handle(.begin)
        await pump()
        XCTAssertEqual(c.state, .recording(locked: false))
    }
}


// MARK: - Noise-aware energy gates

@MainActor
extension DictationCoordinatorTests {

    /// Strictly safer, and unflagged: a quiet absolute peak that nonetheless rose
    /// far above a very quiet room is someone speaking softly, not a dead mic.
    /// This clause may only ever PREVENT a discard.
    func testQuietSpeechAboveAQuietRoomIsNotDiscarded() async {
        let c = makeCoordinator(noiseHandling: false)
        var discarded: [UUID] = []
        c.onSessionDiscard = { discarded.append($0) }
        capture.result = AudioCaptureResult(
            framesWritten: 16_000, durationSeconds: 1.0, peakLevel: 0.03
        )
        c.handle(.begin)
        await pump()
        for _ in 0..<12 { capture.onLevel?(0.005) }
        capture.onLevel?(0.03)
        await pump()
        capture.onLevel?(0.005)
        await pump()
        c.handle(.finalize)
        await settle()
        XCTAssertTrue(discarded.isEmpty, "24dB above the room is speech, whatever the absolute peak says")
        XCTAssertEqual(c.state, .done(.inserted))
    }

    /// Nothing measured the loudness at all ⇒ upload. A wasted round-trip costs a
    /// fraction of a cent; a discarded session costs the words.
    func testUnmeasuredPeakIsTreatedAsSpeech() async {
        let c = makeCoordinator(noiseHandling: false)
        var discarded: [UUID] = []
        c.onSessionDiscard = { discarded.append($0) }
        capture.result = AudioCaptureResult(
            framesWritten: 16_000, durationSeconds: 1.0,
            peakLevel: 0, writtenPeakLevel: 0, peakIsTrustworthy: false
        )
        c.handle(.begin)
        await pump()
        c.handle(.finalize)
        await settle()
        XCTAssertTrue(discarded.isEmpty, "unknown loudness must never be read as silence")
        XCTAssertEqual(c.state, .done(.inserted))
    }

    /// An empty transcript in a loud room is not a failure — and the recording is
    /// KEPT, because a high absolute peak means the judgement could be wrong and
    /// Retry has to still exist when it is.
    func testEmptyTranscriptInLoudRoomIsSilentButKeepsTheRecording() async {
        var transcription = FakeTranscription()
        transcription.result = .failure(.emptyTranscript)
        let c = makeCoordinator(transcription: transcription, noiseHandling: true)
        var discarded: [UUID] = []
        var updates: [SessionMeta] = []
        c.onSessionDiscard = { discarded.append($0) }
        c.onSessionUpdate = { meta, _ in updates.append(meta) }
        capture.result = AudioCaptureResult(
            framesWritten: 16_000, durationSeconds: 1.0, peakLevel: 0.5
        )
        c.handle(.begin)
        await pump()
        for _ in 0..<12 { capture.onLevel?(0.4) }
        capture.onLevel?(0.5)
        await pump()
        capture.onLevel?(0.0)
        await pump()
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.silent), "the model is right: there was no speech above that room")
        XCTAssertEqual(c.lastSilenceReason, .tooNoisy)
        XCTAssertTrue(discarded.isEmpty, "keep the audio — Retry must remain possible")

        // Asserting the discard did NOT happen is only half the promise. The pill
        // says "saved to History", so the row must actually be REACHABLE: .silent
        // is excluded by HistoryStore's visible filter AND is purge-eligible in
        // RetentionPolicy, so writing it would delete the audio behind a message
        // claiming we kept it.
        let meta = try! XCTUnwrap(updates.last, "a row must be written at all")
        XCTAssertEqual(meta.status, .failed, ".silent rows are invisible in History and get purged")
        XCTAssertEqual(meta.errorCode, "tooNoisy")
    }

    /// With the flag off, that same empty transcript stays a real failure — the
    /// experiment is the only thing that changes the classification.
    func testEmptyTranscriptInLoudRoomStillFailsWithFlagOff() async {
        var transcription = FakeTranscription()
        transcription.result = .failure(.emptyTranscript)
        let c = makeCoordinator(transcription: transcription, noiseHandling: false)
        capture.result = AudioCaptureResult(
            framesWritten: 16_000, durationSeconds: 1.0, peakLevel: 0.5
        )
        c.handle(.begin)
        await pump()
        for _ in 0..<12 { capture.onLevel?(0.4) }
        capture.onLevel?(0.0)
        await pump()
        c.handle(.finalize)
        await settle()
        XCTAssertNotEqual(c.state, .done(.silent))
    }
}
