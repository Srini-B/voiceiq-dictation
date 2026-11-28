import XCTest

/// What the keyboard hands the app to learn from fixes to dictated text
/// (`DictationLearning`, through Hex's `DictationEditTracker`).
@MainActor
final class DictationLearningTests: XCTestCase {
    private typealias Context = DictationLearning.Context

    private let empty = Context(before: "", after: "", hasText: false)
    private let dictated = "I had lunch with Sharon today."
    private let field = UUID()
    /// Each fix handed over, as "heard → term", marked when it starts a sentence.
    private var learned: [String] = []
    private var clock: TimeInterval = 0

    private func makeLearning() -> DictationLearning {
        DictationLearning(now: { [unowned self] in clock }, learn: { [unowned self] fix in
            learned.append("\(fix.heard) → \(fix.term)" + (fix.startsSentence ? " (sentence start)" : ""))
        })
    }

    /// The dictation goes into an empty field, cursor after it.
    private func dictate(_ text: String, into learning: DictationLearning) {
        learning.inserted(text, before: empty, after: Context(before: text, after: "", hasText: true),
                          in: field, learns: true)
    }

    /// The user edits the field to `before`|`after` and the keyboard goes.
    private func leave(_ learning: DictationLearning, as before: String, _ after: String = "") {
        let context = Context(before: before, after: after, hasText: !(before + after).isEmpty)
        learning.observe(context, in: field, fromKeys: true)
        learning.finish(context, in: field)
    }

    func testAMisheardNameFixedInAKeptDictationIsLearned() {
        let learning = makeLearning()
        dictate(dictated, into: learning)
        // The user selects "Sharon" and types "Saran".
        leave(learning, as: "I had lunch with Saran", " today.")
        XCTAssertEqual(learned, ["Sharon → Saran"])
    }

    /// Hex drops a capital that starts a sentence: a name fixed as the first word keeps
    /// it, and the app is told it starts the sentence, as the Mac would be.
    func testAWordFixedAtASentenceStartKeepsItsCapitalAndSaysSo() {
        let learning = makeLearning()
        dictate("Sharon went home.", into: learning)
        leave(learning, as: "Saran", " went home.")
        dictate("Sory, I'm late.", into: learning)
        leave(learning, as: "Sorry", ", I'm late.")
        XCTAssertEqual(learned, ["Sharon → Saran (sentence start)", "Sory → Sorry (sentence start)"])
    }

    /// Hex's word pairs lose what joins words; the term is the field's text.
    func testPunctuationInsideAFixIsKept() {
        let learning = makeLearning()
        dictate("I tested GPT4 today.", into: learning)
        leave(learning, as: "I tested GPT-4", " today.")
        XCTAssertEqual(learned, ["GPT4 → GPT-4"])
    }

    func testARewrittenDeletedOrRedictatedDictationTeachesNothing() {
        let learning = makeLearning()
        dictate(dictated, into: learning)
        leave(learning, as: "Meeting moved to Friday instead.")

        dictate(dictated, into: learning)
        leave(learning, as: "")

        // Deleted and dictated again: the word that came out differently is the
        // speech model's second guess, not a fix the user typed.
        dictate(dictated, into: learning)
        learning.observe(empty, in: field, fromKeys: true)
        dictate("I had lunch with Saran today.", into: learning)
        leave(learning, as: "I had lunch with Saran today.")

        XCTAssertEqual(learned, [])
    }

    /// The order the keyboard really calls in: `KeyboardModel` announces the delivery
    /// (`willInsert`), `EditController` types it and its edit callback reports the new
    /// text, then the dictation is reported inserted. A dictation deleted and dictated
    /// again with "Saran" for "Sharon" is not a fix the user typed.
    func testADictationTypedAfterADeletedOneIsNotAnEditOfIt() {
        let learning = makeLearning()
        dictate(dictated, into: learning)
        learning.observe(empty, in: field, fromKeys: true)
        let again = "I had lunch with Saran today."
        let typed = Context(before: again, after: "", hasText: true)
        learning.willInsert(empty, in: field)
        learning.observe(typed, in: field, fromKeys: true)
        learning.inserted(again, before: empty, after: typed, in: field, learns: true)
        leave(learning, as: again)
        XCTAssertEqual(learned, [])
    }

    /// The edit window ends at 60 s on the text as it was, as Hex's poll ends it: an
    /// untouched dictation deleted by the keys after it teaches nothing.
    func testADictationDeletedByKeysAfterTheEditWindowTeachesNothing() {
        let learning = makeLearning()
        dictate(dictated, into: learning)
        clock = DictationEditTracker.editWindow + 1
        learning.observe(empty, in: field, fromKeys: true)
        learning.finish(empty, in: field)
        XCTAssertEqual(learned, [])
    }

    /// One keystroke after the window is not a fix of the dictation, whether the poll
    /// ended the window first or the keystroke is the first thing after it.
    func testAKeystrokeAfterTheEditWindowIsNotAFix() {
        let learning = makeLearning()
        dictate(dictated, into: learning)
        clock = DictationEditTracker.editWindow + 1
        learning.tick()
        leave(learning, as: "I had lunch with Sharo", " today.")

        dictate("See you tomorrow", into: learning)
        clock = 2 * DictationEditTracker.editWindow + 2
        leave(learning, as: "See you tomorro")
        XCTAssertEqual(learned, [])
    }

    /// The spelling is read from the dictation's place, not from the same words earlier
    /// in the field.
    func testTheSpellingComesFromTheDictationNotEarlierText() {
        let learning = makeLearning()
        let earlier = "I tested GPT 4 today. Earlier notes. "
        let text = "I tested GPT4 today."
        learning.inserted(text, before: Context(before: earlier, after: "", hasText: true),
                          after: Context(before: earlier + text, after: "", hasText: true), in: field, learns: true)
        leave(learning, as: earlier + "I tested GPT-4", " today.")
        XCTAssertEqual(learned, ["GPT4 → GPT-4"])
    }

    /// The fixed words appear twice in the dictation with the same words around them:
    /// which one was fixed can't be told, so nothing is learned.
    func testAFixWhoseWordsAppearTwiceInTheDictationIsSkipped() {
        let learning = makeLearning()
        dictate("I tested GPT 4 today. Then I tested GPT4 today.", into: learning)
        leave(learning, as: "I tested GPT 4 today. Then I tested GPT-4", " today.")
        XCTAssertEqual(learned, [])
    }

    /// Selecting part of a dictation edits nothing: the proxy leaves the selection out of
    /// the text before and after the cursor, and it goes back in.
    func testASelectionInsideADictationIsNotAnEdit() {
        let learning = makeLearning()
        dictate(dictated, into: learning)
        let selecting = DictationLearning.context(before: "I had lunch with Sharo", selected: "n",
                                                  after: " today.", hasText: true)
        learning.observe(selecting, in: field, fromKeys: false)
        learning.finish(selecting, in: field)
        XCTAssertEqual(learned, [])
    }

    /// A word being retyped as the edit window ends settles once typing pauses, not half done.
    func testAWordRetypedAsTheWindowEndsIsLearnedWhole() {
        let learning = makeLearning()
        dictate(dictated, into: learning)
        clock = 59.5
        learning.observe(Context(before: "I had lunch with Sar", after: " today.", hasText: true), in: field, fromKeys: true)
        clock = 61
        learning.tick()
        learning.observe(Context(before: "I had lunch with Saran", after: " today.", hasText: true), in: field, fromKeys: true)
        clock = 62
        learning.tick()
        clock = 65
        learning.tick()
        XCTAssertEqual(learned, ["Sharon → Saran"])
    }

    /// A symbol right against the fix falls outside its words: "Notepad++" would be
    /// learned as "Notepad", so it is skipped. A full stop after it is ordinary.
    func testAFixWithASymbolAgainstItIsSkipped() {
        let learning = makeLearning()
        dictate("I tested Notpad today.", into: learning)
        leave(learning, as: "I tested Notepad++", " today.")
        dictate("I had lunch with Sharon", into: learning)
        leave(learning, as: "I had lunch with Saran.")
        XCTAssertEqual(learned, ["Sharon → Saran"])
    }

    /// UIKit named no input session for the dictation, so the next field's text could
    /// read as an edit of it: it is not followed.
    func testADictationInAnUnnamedSessionIsNotFollowed() {
        let learning = makeLearning()
        learning.inserted(dictated, before: empty, after: Context(before: dictated, after: "", hasText: true),
                          in: nil, learns: true)
        let elsewhere = Context(before: "I had lunch with Saran today.", after: "", hasText: true)
        learning.observe(elsewhere, in: field, fromKeys: false)
        learning.finish(elsewhere, in: field)
        XCTAssertEqual(learned, [])
    }

    /// Focus moved to another field without the keyboard hiding: that field's text is
    /// not an edit of the dictation, even when it reads like one.
    func testAnotherFieldsTextIsNotAFix() {
        let learning = makeLearning()
        dictate(dictated, into: learning)
        let other = UUID()
        let elsewhere = Context(before: "I had lunch with Saran today.", after: "", hasText: true)
        learning.observe(elsewhere, in: other, fromKeys: false)
        learning.finish(elsewhere, in: other)
        XCTAssertEqual(learned, [])
    }
}
