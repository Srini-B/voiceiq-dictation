import XCTest
@testable import VoiceIQCore

final class ReplacementEngineTests: XCTestCase {
    private func rule(_ wrong: String, _ right: String) -> ReplacementEngine.Rule {
        .init(wrong: wrong, right: right)
    }

    func testMeetingTranscriptsGetTheDictionarysSpellings() {
        let heard = [
            TranscriptSegment(speaker: "A", text: "Ship it to cooper netties today", chunkIndex: 0, start: 1.5, end: 4),
            TranscriptSegment(speaker: "B", text: "COOPER NETTIES is down", chunkIndex: 1, start: 4, end: 6.25),
        ]
        let fixed = MeetingEngine.corrected(heard, rules: [rule("cooper netties", "Kubernetes")])
        XCTAssertEqual(fixed.map(\.text), ["Ship it to Kubernetes today", "Kubernetes is down"])
        XCTAssertEqual(fixed.map(\.speaker), ["A", "B"])
        XCTAssertEqual(fixed.map(\.end), [4, 6.25])
    }

    func testBasicReplacement() {
        let out = ReplacementEngine.apply([rule("cooper netties", "Kubernetes")], to: "deploy the cooper netties cluster")
        XCTAssertEqual(out, "deploy the Kubernetes cluster")
    }

    func testWordBoundaryRespected() {
        let out = ReplacementEngine.apply([rule("cat", "dog")], to: "the category has a cat")
        XCTAssertEqual(out, "the category has a dog")
    }

    func testLongestMatchWins() {
        let out = ReplacementEngine.apply(
            [rule("gemini", "Gemini"), rule("gemini api", "Gemini API")],
            to: "open gemini api now"
        )
        XCTAssertEqual(out, "open Gemini API now")
    }

    func testExplicitCasingCarries() {
        let out = ReplacementEngine.apply([rule("g r p c", "gRPC")], to: "The G R P C endpoint")
        XCTAssertEqual(out, "The gRPC endpoint")
    }

    func testCaseInsensitiveMatching() {
        let out = ReplacementEngine.apply([rule("genny", "Gemini")], to: "Genny is fast. genny wins.")
        XCTAssertEqual(out, "Gemini is fast. Gemini wins.")
    }

    func testLowercaseRulePropagatesSentenceCase() {
        let out = ReplacementEngine.apply([rule("standup", "stand-up")], to: "Standup at nine. The standup ran long.")
        XCTAssertEqual(out, "Stand-up at nine. The stand-up ran long.")
    }

    func testNoRulesIsIdentity() {
        XCTAssertEqual(ReplacementEngine.apply([], to: "unchanged"), "unchanged")
    }

    func testMultipleOccurrences() {
        let out = ReplacementEngine.apply([rule("amar", "Ammaar")], to: "amar told amar's team")
        XCTAssertEqual(out, "Ammaar told Ammaar's team")
    }
}
