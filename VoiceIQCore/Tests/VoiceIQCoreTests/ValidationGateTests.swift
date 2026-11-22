import XCTest
@testable import VoiceIQCore

final class ValidationGateTests: XCTestCase {
    func testStripsCodeFences() {
        XCTAssertEqual(ValidationGate.stripArtifacts("```\nHello there.\n```"), "Hello there.")
    }

    func testStripsLabels() {
        XCTAssertEqual(ValidationGate.stripArtifacts("CLEAN: Hello there."), "Hello there.")
        XCTAssertEqual(ValidationGate.stripArtifacts("Transcript: Hello."), "Hello.")
    }

    func testStripsWrappingQuotes() {
        XCTAssertEqual(ValidationGate.stripArtifacts("\"Hello there.\""), "Hello there.")
    }

    func testLeavesInternalQuotesAlone() {
        XCTAssertEqual(ValidationGate.stripArtifacts("She said \"hi\" to me."), "She said \"hi\" to me.")
    }
}
