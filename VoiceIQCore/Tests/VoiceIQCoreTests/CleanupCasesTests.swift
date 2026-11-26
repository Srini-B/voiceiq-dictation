import XCTest
@testable import VoiceIQCore

/// The shared cleanup cases (Fixtures/cleanup-cases.json) through the
/// writing-Off tidy-up: each on-device transcript (`heard`) must come out as
/// the expected text, or as its recorded shortfall (`tidy`). The same cases
/// score the Gemini path by hand or by a judge, from `said`.
final class CleanupCasesTests: XCTestCase {
    private struct Cases: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let id: String
        let check: String
        let style: String?
        let language: String?
        let heard: String
        let written: String
        let tidy: String?
    }

    func testEveryCaseTidiesAsExpected() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cleanup-cases", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url)).cases
        XCTAssertGreaterThan(cases.count, 30)
        for item in cases {
            let style = try XCTUnwrap(TidyStyle(rawValue: item.style ?? "sentences"), item.id)
            let language = item.language ?? "en-US"
            let written = Tidy.styled(Tidy.spoken(item.heard, style: style, language: language), style: style, language: language)
            XCTAssertEqual(written, item.tidy ?? item.written, "\(item.id) (\(item.check))")
        }
    }
}
