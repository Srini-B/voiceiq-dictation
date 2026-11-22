import XCTest
@testable import VoiceIQCore

final class SanitizedVocabularyTests: XCTestCase {
    private let store = DictionaryStore()

    override func setUp() { UserDefaults.standard.removeObject(forKey: "dictionaryEntries") }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "dictionaryEntries") }

    /// Dictionary entries are user/CSV data. A term carrying a newline could
    /// otherwise smuggle its own instruction line into the cleanup prompt (audit L31),
    /// and the same sanitizer now guards the transcription request.
    func testStripsNewlinesAndCapsLength() {
        _ = store.add(term: "Kuber\nnetes", misspelling: nil)
        _ = store.add(term: String(repeating: "x", count: 80), misspelling: nil)
        let vocabulary = store.sanitizedVocabulary()
        XCTAssertFalse(vocabulary.contains { $0.contains("\n") })
        XCTAssertTrue(vocabulary.allSatisfy { $0.count <= 60 })
    }

    /// Truncation drops from the END of the sorted list, and vocabulary() sorts
    /// starred first — so the terms the user explicitly prioritised survive a
    /// byte-ceiling trim.
    func testByteCeilingKeepsStarredTerms() {
        for index in 0..<60 { _ = store.add(term: "term-number-\(index)", misspelling: nil) }
        _ = store.add(term: "Kubernetes", misspelling: nil)
        if let starred = store.entries().first(where: { $0.term == "Kubernetes" }) {
            store.toggleStar(id: starred.id)
        }
        let vocabulary = store.sanitizedVocabulary(maxBytes: 60)
        XCTAssertTrue(vocabulary.contains("Kubernetes"), "starred terms must survive the trim")
        XCTAssertLessThanOrEqual(vocabulary.joined(separator: ",").utf8.count, 60)
    }

    /// Never send misspellings. Biasing a recogniser toward "cooper netties" is
    /// actively harmful, and spellings() sits close enough to wire up by accident.
    func testCarriesOnlyCorrectTermsNeverMisspellings() {
        _ = store.add(term: "Kubernetes", misspelling: "cooper netties")
        let vocabulary = store.sanitizedVocabulary()
        XCTAssertTrue(vocabulary.contains("Kubernetes"))
        XCTAssertFalse(vocabulary.contains("cooper netties"))
    }
}
