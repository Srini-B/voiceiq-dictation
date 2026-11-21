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
