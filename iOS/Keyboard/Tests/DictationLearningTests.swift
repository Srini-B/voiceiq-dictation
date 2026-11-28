import XCTest

/// What the keyboard hands the app to learn from fixes to dictated text
/// (`DictationLearning`, through Hex's `DictationEditTracker`).
@MainActor
final class DictationLearningTests: XCTestCase {
    private typealias Context = DictationLearning.Context

    private let empty = Context(before: "", after: "", hasText: false)
    private let dictated = "I had lunch with Sharon today."
    /// Each fix handed over, as "heard → term".
    private var learned: [String] = []

    private func makeLearning() -> DictationLearning {
        DictationLearning(learn: { [unowned self] term, heard in learned.append("\(heard) → \(term)") })
    }

    /// The dictation goes into an empty field, cursor after it.
    private func dictate(_ text: String, into learning: DictationLearning) {
        learning.inserted(text, before: empty, after: Context(before: text, after: "", hasText: true), learns: true)
    }

    func testAMisheardNameFixedInAKeptDictationIsLearned() {
        let learning = makeLearning()
        dictate(dictated, into: learning)
        // The user selects "Sharon" and types "Saran".
        let fixed = Context(before: "I had lunch with Saran", after: " today.", hasText: true)
        learning.observe(fixed, fromKeys: true)
        learning.finish(fixed)
        XCTAssertEqual(learned, ["Sharon → Saran"])
    }

    /// Hex drops a capital that starts a sentence; a name fixed as the first word keeps it.
    func testANameFixedAsTheFirstWordKeepsItsCapital() {
        let learning = makeLearning()
        dictate("Sharon went home.", into: learning)
        let fixed = Context(before: "Saran", after: " went home.", hasText: true)
        learning.observe(fixed, fromKeys: true)
        learning.finish(fixed)
        XCTAssertEqual(learned, ["Sharon → Saran"])
    }

    func testARewrittenDeletedOrRedictatedDictationTeachesNothing() {
        let learning = makeLearning()
        dictate(dictated, into: learning)
        let rewritten = Context(before: "Meeting moved to Friday instead.", after: "", hasText: true)
        learning.observe(rewritten, fromKeys: true)
        learning.finish(rewritten)

        dictate(dictated, into: learning)
        learning.observe(empty, fromKeys: true)
        learning.finish(empty)

        // Deleted and dictated again: the word that came out differently is the
        // speech model's second guess, not a fix the user typed.
        dictate(dictated, into: learning)
        learning.observe(empty, fromKeys: true)
        dictate("I had lunch with Saran today.", into: learning)
        learning.finish(Context(before: "I had lunch with Saran today.", after: "", hasText: true))

        XCTAssertEqual(learned, [])
    }
}
