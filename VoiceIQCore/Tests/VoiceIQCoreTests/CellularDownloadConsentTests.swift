import XCTest
@testable import VoiceIQCore

final class CellularDownloadConsentTests: XCTestCase {
    func testWiFiNeverAsks() {
        var consent = CellularDownloadConsent()
        XCTAssertFalse(consent.shouldAsk(for: "fluid-speech-pro", onCellular: false))
        consent.begin("fluid-speech-pro")
        // Moving to cellular partway through: a started download is consented.
        XCTAssertFalse(consent.shouldAsk(for: "fluid-speech-pro", onCellular: true))
    }

    func testCellularAsksOnceForADownload() {
        var consent = CellularDownloadConsent()
        XCTAssertTrue(consent.shouldAsk(for: "fluid-speech-pro", onCellular: true))
        consent.begin("fluid-speech-pro")
        // The network drops and comes back, on Wi-Fi or cellular: Retry carries on.
        XCTAssertFalse(consent.shouldAsk(for: "fluid-speech-pro", onCellular: true))
        XCTAssertFalse(consent.shouldAsk(for: "fluid-speech-pro", onCellular: false))
        // Another model's download is its own decision.
        XCTAssertTrue(consent.shouldAsk(for: "parakeet", onCellular: true))
    }

    func testANewDownloadAsksAgain() {
        var consent = CellularDownloadConsent()
        consent.begin("fluid-speech-pro")
        consent.end("fluid-speech-pro")
        XCTAssertTrue(consent.shouldAsk(for: "fluid-speech-pro", onCellular: true))
    }

    func testCellularMeansACellularOrExpensivePath() {
        XCTAssertTrue(CellularDownloadConsent.isCellular(satisfied: true, cellular: true, expensive: true))
        XCTAssertTrue(CellularDownloadConsent.isCellular(satisfied: true, cellular: false, expensive: true))
        XCTAssertFalse(CellularDownloadConsent.isCellular(satisfied: true, cellular: false, expensive: false))
        XCTAssertFalse(CellularDownloadConsent.isCellular(satisfied: false, cellular: true, expensive: true))
    }
}
