import XCTest
@testable import VoiceIQCore

final class HotkeyProcessorTests: XCTestCase {
    private var processor = HotkeyProcessor()

    override func setUp() {
        super.setUp()
        processor = HotkeyProcessor()
    }

    @discardableResult
    private func send(_ event: HotkeyProcessor.Event, at t: TimeInterval) -> HotkeyProcessor.Effects {
        processor.handle(event, at: t)
    }

    func testPressStartsHandsFreeAndNextPressStops() {
        XCTAssertEqual(send(.hotkeyDown, at: 0).intents, [.begin, .lockIn])
        XCTAssertEqual(send(.hotkeyUp, at: 0.1).intents, [], "release does nothing")
        XCTAssertTrue(processor.isSessionActive)
        XCTAssertEqual(send(.hotkeyDown, at: 8).intents, [.finalize])
        XCTAssertEqual(send(.hotkeyUp, at: 8.1).intents, [])
        XCTAssertFalse(processor.isSessionActive)
    }

    func testLongHoldDoesNotStop() {
        send(.hotkeyDown, at: 0)
        XCTAssertEqual(send(.hotkeyUp, at: 5).intents, [], "holding the key is harmless")
        XCTAssertTrue(processor.isSessionActive)
    }

    func testEscCancels() {
        send(.hotkeyDown, at: 0)
        send(.hotkeyUp, at: 0.1)
        XCTAssertEqual(send(.escDown, at: 3).intents, [.cancel])
        XCTAssertFalse(processor.isSessionActive)
    }

    func testChordWithinWindowAborts() {
        send(.hotkeyDown, at: 0)
        XCTAssertEqual(send(.otherKeyDown, at: 0.4).intents, [.abortAccidental])
        XCTAssertFalse(processor.isSessionActive)
        XCTAssertEqual(send(.hotkeyUp, at: 0.5).intents, [], "the chord's release is not a stop")
    }

    func testTypingAfterWindowPasses() {
        send(.hotkeyDown, at: 0)
        send(.hotkeyUp, at: 0.1)
        XCTAssertEqual(send(.otherKeyDown, at: 1.0).intents, [], "at the boundary the session keeps going")
        XCTAssertEqual(send(.otherKeyDown, at: 4).intents, [])
        XCTAssertTrue(processor.isSessionActive)
    }

    func testResetClearsPhantomSession() {
        send(.hotkeyDown, at: 0)
        processor.reset()
        XCTAssertFalse(processor.isSessionActive)
        XCTAssertEqual(send(.hotkeyDown, at: 1).intents, [.begin, .lockIn], "next press starts, not stops")
    }

    func testIdleIgnoresOtherEvents() {
        XCTAssertEqual(send(.hotkeyUp, at: 0).intents, [])
        XCTAssertEqual(send(.escDown, at: 0).intents, [])
        XCTAssertEqual(send(.otherKeyDown, at: 0).intents, [])
        XCTAssertFalse(processor.isSessionActive)
    }

    func testBareF13IsAShortcutButABareLetterIsNot() {
        let f13 = KeyShortcut(keyCode: 105, modifiers: [])
        XCTAssertEqual(f13.displayString, "F13")
        // F-keys arrive with the fn flag set; it is not one of the modifiers.
        XCTAssertTrue(f13.matches(rawFlags: 0x80_0000, keyCode: 105))
        XCTAssertFalse(f13.matches(rawFlags: 0x10_0000, keyCode: 105)) // ⌘F13 is a different shortcut
        XCTAssertTrue(KeyShortcut.standaloneKeyCodes.contains(80))      // F19
        XCTAssertFalse(KeyShortcut.standaloneKeyCodes.contains(0))      // A
        XCTAssertFalse(KeyShortcut.standaloneKeyCodes.contains(111))    // F12 is a system key
    }
}
