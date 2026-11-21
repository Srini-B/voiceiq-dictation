import VoiceIQBridge
import XCTest

/// The keyboard's side of dictation, driven through the App Group as the app drives it.
@MainActor
final class KeyboardModelTests: XCTestCase {
    private let store = SharedStore.shared

    override func setUp() async throws {
        reset()
    }

    override func tearDown() async throws {
        reset()
    }

    private func reset() {
        UserDefaults(suiteName: SharedStore.appGroupID)?.removeObject(forKey: "bridge.commands")
        store.publish(SessionSnapshot())
        store.heartbeat = nil
    }

    private func waitForRefresh() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    /// A quick hold: the key is lifted before the app reports recording, so the
    /// stop has to wait for the recording to show up, then go once.
    func testAHoldReleasedBeforeRecordingShowsStopsTheRecording() {
        let model = KeyboardModel()
        model.micTapped()
        XCTAssertEqual(store.commands.map(\.action), [.start])

        model.holdReleased()
        model.appeared()
        waitForRefresh()
        XCTAssertEqual(store.commands.map(\.action), [.start], "no stop before anything records")

        store.heartbeat = Date()
        store.publish(SessionSnapshot(phase: .recording, mode: .dictate))
        waitForRefresh()
        XCTAssertEqual(store.commands.map(\.action), [.start, .stop])

        waitForRefresh()
        XCTAssertEqual(store.commands.map(\.action), [.start, .stop], "the stop goes once")
        model.disappeared()
    }

    /// Tapping the offered result A pastes A, and only A: a newer result B
    /// for this field is offered instead, never typed by the tap.
    func testTappingAnOfferPastesOnlyThatResult() {
        let field = UUID()
        let offered = HeldDictation(text: "A", mode: .dictate, document: field)
        let newer = HeldDictation(text: "B", mode: .dictate, document: field)
        XCTAssertEqual(KeyboardModel.heldToPaste(offered: offered.id, current: offered)?.text, "A")
        XCTAssertNil(KeyboardModel.heldToPaste(offered: offered.id, current: newer))
        XCTAssertNil(KeyboardModel.heldToPaste(offered: nil, current: newer))
        let expired = Date().addingTimeInterval(HeldDictation.offerWindow + 1)
        XCTAssertNil(KeyboardModel.heldToPaste(offered: offered.id, current: offered, now: expired))
    }
}
