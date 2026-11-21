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
    /// stop goes at once, bound to the hold's start, for the app to apply once
    /// that dictation records and to no other one.
    func testAHoldReleasedBeforeRecordingSendsAStopForItsStart() throws {
        let model = KeyboardModel()
        model.micTapped()
        let start = try XCTUnwrap(store.commands.last)
        XCTAssertEqual(start.action, .start)

        model.holdReleased()
        XCTAssertEqual(store.commands.map(\.action), [.start, .stop])
        XCTAssertEqual(store.commands.last?.startID, start.id)

        model.holdReleased()
        XCTAssertEqual(store.commands.count, 2, "the stop goes once")
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

    /// A hold longer than a command's 30 s lifetime still ends its own dictation.
    func testALongHoldReleasedSendsAStopForItsStart() throws {
        let model = KeyboardModel()
        model.micTapped()
        let start = try XCTUnwrap(store.commands.last)
        model.holdStart = KeyboardCommand(id: start.id, action: .start, issuedAt: Date().addingTimeInterval(-60))

        model.holdReleased()
        XCTAssertEqual(store.commands.last?.action, .stop)
        XCTAssertEqual(store.commands.last?.startID, start.id)
    }
}
