import XCTest
@testable import VoiceIQCore

final class CellularDownloadConsentTests: XCTestCase {
    func testWiFiStartsWithoutAskingAndCarriesOnOverCellular() {
        var consent = CellularDownloadConsent()
        XCTAssertEqual(consent.tap("fluid-speech-pro", on: .wifi), .start)
        // Retry after the download moved to cellular and dropped.
        XCTAssertEqual(consent.tap("fluid-speech-pro", on: .cellular), .start)
    }

    func testCellularAsksOnceForADownload() {
        var consent = CellularDownloadConsent()
        XCTAssertEqual(consent.tap("fluid-speech-pro", on: .cellular), .ask)
        consent.confirm("fluid-speech-pro")
        XCTAssertEqual(consent.tap("fluid-speech-pro", on: .cellular), .start)
        XCTAssertEqual(consent.tap("fluid-speech-pro", on: .offline), .start)
        // Another model's download is its own decision.
        XCTAssertEqual(consent.tap("parakeet", on: .cellular), .ask)
    }

    func testAnOfflineTapStartsNothingAndLaterCellularStillAsks() {
        var consent = CellularDownloadConsent()
        XCTAssertEqual(consent.tap("fluid-speech-pro", on: .offline), .offline)
        XCTAssertEqual(consent.tap("fluid-speech-pro", on: .cellular), .ask)
    }

    /// Before the network monitor's first update, a tap asks rather than refusing as offline.
    func testAnUnknownNetworkAsks() {
        var consent = CellularDownloadConsent()
        XCTAssertEqual(consent.tap("fluid-speech-pro", on: .unknown), .ask)
    }

    func testANewDownloadAsksAgain() {
        var consent = CellularDownloadConsent()
        _ = consent.tap("fluid-speech-pro", on: .wifi)
        consent.end("fluid-speech-pro")
        XCTAssertEqual(consent.tap("fluid-speech-pro", on: .cellular), .ask)
    }

    func testCellularMeansACellularOrExpensivePath() {
        typealias Network = CellularDownloadConsent.Network
        XCTAssertEqual(Network(satisfied: true, cellular: true, expensive: true), .cellular)
        XCTAssertEqual(Network(satisfied: true, cellular: false, expensive: true), .cellular)
        XCTAssertEqual(Network(satisfied: true, cellular: false, expensive: false), .wifi)
        XCTAssertEqual(Network(satisfied: false, cellular: true, expensive: true), .offline)
    }
}
