import CoreGraphics
import XCTest

final class TypingEngineTests: XCTestCase {
    private func engine() throws -> TypingEngine {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lexicon", withExtension: "bin"))
        let lexicon = try XCTUnwrap(Lexicon(url: url))
        return TypingEngine(lexicon: lexicon, geometry: KeyGeometry(centers: [:], keyWidth: 1, keyHeight: 1))
    }

    /// A contact such as "Apple Developer" adds "Developer" to the user's
    /// words; slid mid-sentence, "developer" must stay lowercase.
    func testSlidDeveloperMidSentenceIgnoresContactCapital() throws {
        var engine = try engine()
        engine.user.contacts = ["developer": "Developer", "srini": "Srini", "london": "London"]
        engine.user.dictionary = ["github": "GitHub", "cant": "can't"]

        XCTAssertFalse(TypingEngine.context(before: "I work as a ").sentenceStart)
        XCTAssertNil(engine.userSpelling(of: "developer"))
        XCTAssertEqual(engine.spelling(of: "developer"), "developer")

        // Names and spellings with capitals beyond the first keep them.
        XCTAssertEqual(engine.userSpelling(of: "srini"), "Srini")
        XCTAssertEqual(engine.userSpelling(of: "london"), "London")
        XCTAssertEqual(engine.userSpelling(of: "github"), "GitHub")
        // A lowercase spelling that restores an apostrophe is kept.
        XCTAssertEqual(engine.userSpelling(of: "cant"), "can't")
    }
}
