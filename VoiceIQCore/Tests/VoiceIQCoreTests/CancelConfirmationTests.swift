import XCTest
@testable import VoiceIQCore

final class CancelConfirmationTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    func testShortRecordingCancelsAtOnce() {
        var confirmation = CancelConfirmation()
        XCTAssertTrue(confirmation.cancels(recordingSince: start, now: start + 9.9))
        XCTAssertTrue(confirmation.cancels(recordingSince: nil, now: start + 60))
    }

    func testLongRecordingAsksThenCancelsOnSecondPress() {
        var confirmation = CancelConfirmation()
        XCTAssertFalse(confirmation.cancels(recordingSince: start, now: start + 10), "one stray ⌘Esc keeps the take")
        XCTAssertTrue(confirmation.cancels(recordingSince: start, now: start + 12))
    }

    func testPressAfterTheWindowAsksAgain() {
        var confirmation = CancelConfirmation()
        XCTAssertFalse(confirmation.cancels(recordingSince: start, now: start + 20))
        XCTAssertFalse(confirmation.cancels(recordingSince: start, now: start + 24))
        XCTAssertTrue(confirmation.cancels(recordingSince: start, now: start + 25))
    }
}
