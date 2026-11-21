import VoiceIQBridge
import VoiceIQCore
import XCTest
@testable import VoiceiQ

/// Which dictation a stop from the keyboard ends.
final class KeyboardStopGateTests: XCTestCase {
    private let recording = DictationState.recording(locked: true)

    func testAStopDuringWarmingEndsItsDictationOnceItRecords() {
        var gate = KeyboardStopGate()
        let start = UUID()
        gate.started(by: start)
        XCTAssertFalse(gate.receive(KeyboardCommand(action: .stop), state: .warming))
        XCTAssertTrue(gate.takeHeldStop(state: recording))
        XCTAssertFalse(gate.takeHeldStop(state: recording), "the stop applies once")
    }

    func testAStopForAnotherStartKeepsTheWarmingStop() {
        var gate = KeyboardStopGate()
        gate.started(by: UUID())
        XCTAssertFalse(gate.receive(KeyboardCommand(action: .stop), state: .warming))
        XCTAssertFalse(gate.receive(KeyboardCommand(action: .stop, startID: UUID()), state: .warming))
        XCTAssertTrue(gate.takeHeldStop(state: recording))
    }

    func testAStopBeforeItsStartIsHeldForIt() {
        var gate = KeyboardStopGate()
        let start = UUID()
        XCTAssertFalse(gate.receive(KeyboardCommand(action: .stop, startID: start), state: .idle))
        gate.started(by: start)
        XCTAssertTrue(gate.takeHeldStop(state: recording))
    }

    func testAStopForAReplacedRecordingNeverEndsTheNewOne() {
        var gate = KeyboardStopGate()
        let first = UUID()
        gate.started(by: first)
        gate.ended()
        gate.started(by: UUID())
        XCTAssertFalse(gate.receive(KeyboardCommand(action: .stop, startID: first), state: recording))
        XCTAssertFalse(gate.takeHeldStop(state: recording))
    }

    func testAStopForTheRecordingInProgressEndsIt() {
        var gate = KeyboardStopGate()
        let start = UUID()
        gate.started(by: start)
        XCTAssertTrue(gate.receive(KeyboardCommand(action: .stop, startID: start), state: recording))
    }
}

/// The gate as the app wires it, around a real coordinator: a keyboard stop
/// that arrives while the dictation still warms up ends it once it records.
@MainActor
final class KeyboardStopDuringWarmingTests: XCTestCase {
    final class Capture: AudioCapturing, @unchecked Sendable {
        var onLevel: (@Sendable (Float) -> Void)?
        var onDeviceChange: (@Sendable (String) -> Void)?
        var onWriteFailure: (@Sendable () -> Void)?
        var onEngineDied: (@Sendable (String) -> Void)?
        private(set) var stopCount = 0
        func start(writingTo url: URL) throws {}
        func stop() async -> AudioCaptureResult {
            stopCount += 1
            return AudioCaptureResult(framesWritten: 32_000, durationSeconds: 2)
        }
    }

    final class Transcription: TranscriptionServicing, @unchecked Sendable {
        private(set) var calls = 0
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
            calls += 1
            return TranscriptionResult(rawTranscript: "raw", cleanedTranscript: "clean", modelID: "test")
        }
    }

    final class Inserter: TextInserting {
        func insert(_ text: String, context: DictationContext) async -> InsertionOutcome { .inserted }
    }

    private var gate = KeyboardStopGate()

    override func tearDown() async throws {
        FileLayout.overrideRoot = nil
    }

    func testAStopDuringWarmingFinalizesOnceItRecords() async throws {
        FileLayout.overrideRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let capture = Capture()
        let transcription = Transcription()
        var started = Date()
        let coordinator = DictationCoordinator(audioFactory: { capture }, transcription: transcription,
                                               insertion: Inserter(), now: { started },
                                               noiseHandlingEnabled: { false }, secureInputActive: { false })
        var finalizing = 0
        // As AppModel.stateChanged: the held stop is checked on the turn
        // after `$state` publishes `.recording`.
        let sink = coordinator.$state.sink { [unowned self] state in
            if state == .finalizing { finalizing += 1 }
            guard case .recording = state else { return }
            Task { @MainActor in
                if self.gate.takeHeldStop(state: coordinator.state) { coordinator.handle(.finalize) }
            }
        }
        defer { sink.cancel() }

        // As AppModel.start(_:): begin, bind the start, lock in.
        let start = UUID()
        XCTAssertTrue(coordinator.handle(.begin))
        gate.started(by: start)
        coordinator.handle(.lockIn)
        XCTAssertEqual(coordinator.state, .warming)
        started -= 2

        // The keyboard's stop for that start lands while the engine warms up.
        XCTAssertFalse(gate.receive(KeyboardCommand(action: .stop, startID: start), state: coordinator.state))

        for _ in 0..<300 where !coordinator.state.isTerminal {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(coordinator.state, .done(.inserted))
        XCTAssertEqual(finalizing, 1)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(transcription.calls, 1)
    }
}
