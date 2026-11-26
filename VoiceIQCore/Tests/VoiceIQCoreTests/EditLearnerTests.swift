#if os(macOS)
import XCTest
@testable import VoiceIQCore

@MainActor
final class EditLearnerTests: XCTestCase {
    private let store = DictionaryStore()

    override func setUp() { UserDefaults.standard.removeObject(forKey: "dictionaryEntries") }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "dictionaryEntries") }

    private func fix(_ original: String, _ replacement: String, _ words: Range<Int>) -> LearnedCorrection {
        LearnedCorrection(original: original, replacement: replacement, words: words)
    }

    func testAnAdjacentFixRenamesTheJustLearnedWordIntoAPhrase() {
        let learner = EditLearner(dictionary: store)
        let first = fix("whisper", "Wispr", 2..<3)
        learner.learn([.learn(first)], stillTaught: ["wispr": 1])
        let id = store.entries().first?.id
        learner.learn([.revise(replacing: [first], with: fix("whisper flowcast", "Wispr Flow", 2..<4))], stillTaught: ["wispr flow": 1])
        XCTAssertEqual(store.entries().map(\.term), ["Wispr Flow"])
        XCTAssertEqual(store.entries().first?.id, id)
        XCTAssertEqual(store.entries().first?.learnedFrom, "whisper flowcast")
    }

    func testAWordAnotherFixStillTeachesIsKept() {
        let learner = EditLearner(dictionary: store)
        let srini = fix("Shrinny", "Srini", 1..<2)
        learner.learn([.learn(srini)], stillTaught: ["srini": 1])
        learner.learn([.learn(fix("Srini", "Shrini", 4..<5))], stillTaught: ["srini": 1, "shrini": 1])
        XCTAssertEqual(Set(store.entries().map(\.term)), ["Srini", "Shrini"])
        learner.learn([.forget(srini)], stillTaught: ["srini": 1, "shrini": 1])
        XCTAssertEqual(Set(store.entries().map(\.term)), ["Srini", "Shrini"])
        learner.learn([.forget(srini)], stillTaught: ["shrini": 1])
        XCTAssertEqual(store.entries().map(\.term), ["Shrini"])
    }
}
#endif
