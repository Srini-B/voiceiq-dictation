#if os(macOS)
import XCTest
@testable import VoiceIQCore

@MainActor
final class EditLearnerTests: XCTestCase {
    private let store = DictionaryStore()

    override func setUp() { Self.clear() }
    override func tearDown() { Self.clear() }

    private nonisolated static func clear() {
        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
        UserDefaults.standard.removeObject(forKey: "dictionaryTombstones")
    }

    private func fix(_ original: String, _ replacement: String, _ words: Range<Int>) -> LearnedCorrection {
        LearnedCorrection(original: original, replacement: replacement, words: words)
    }

    func testAnAdjacentFixRenamesTheJustLearnedWordIntoAPhrase() {
        let learner = EditLearner(dictionary: store)
        let first = fix("wizpor", "Wyzpr", 2..<3)
        learner.learn([.learn(first)], stillTaught: ["wyzpr": 1])
        let id = store.entries().first?.id
        learner.learn([.revise(replacing: [first], with: fix("wizpor flowqast", "Wyzpr Flowq", 2..<4))], stillTaught: ["wyzpr flowq": 1])
        XCTAssertEqual(store.entries().map(\.term), ["Wyzpr Flowq"])
        XCTAssertEqual(store.entries().first?.id, id)
        XCTAssertEqual(store.entries().first?.learnedFrom, "wizpor flowqast")
    }

    func testAWordAnotherFixStillTeachesIsKept() {
        let learner = EditLearner(dictionary: store)
        let srini = fix("Qrinnyx", "Qrinzo", 1..<2)
        learner.learn([.learn(srini)], stillTaught: ["qrinzo": 1])
        learner.learn([.learn(fix("Qrinzo", "Qrinza", 4..<5))], stillTaught: ["qrinzo": 1, "qrinza": 1])
        XCTAssertEqual(Set(store.entries().map(\.term)), ["Qrinzo", "Qrinza"])
        learner.learn([.forget(srini)], stillTaught: ["qrinzo": 1, "qrinza": 1])
        XCTAssertEqual(Set(store.entries().map(\.term)), ["Qrinzo", "Qrinza"])
        learner.learn([.forget(srini)], stillTaught: ["qrinza": 1])
        XCTAssertEqual(store.entries().map(\.term), ["Qrinza"])
    }

    func testANameThatIsAlsoAnEnglishWordIsLearnedButAWordFixIsNot() {
        let learner = EditLearner(dictionary: store)
        learner.learn([
            .learn(LearnedCorrection(original: "Sharon", replacement: "Saran", words: 2..<3, nameLike: true)),
            .learn(LearnedCorrection(original: "Then", replacement: "Than", words: 5..<6, nameLike: true)),
            .learn(LearnedCorrection(original: "Sara", replacement: "Sorry", words: 0..<1, nameLike: false)),
        ], stillTaught: [:])
        XCTAssertEqual(store.entries().map(\.term), ["Saran"])
    }

    func testAKeptWordHeardAsItsOwnLowercaseDoesNotBlockTheNewSpelling() {
        let learner = EditLearner(dictionary: store)
        learner.learn([.learn(fix("qrinzo", "Qrinzo", 1..<2))], stillTaught: ["qrinzo": 1])
        learner.learn([.learn(fix("Qrinzo", "Qrinza", 4..<5))], stillTaught: ["qrinzo": 1, "qrinza": 1])
        XCTAssertEqual(Set(store.entries().map(\.term)), ["Qrinzo", "Qrinza"])
    }
}
#endif
