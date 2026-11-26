import XCTest
@testable import VoiceIQCore

final class EditDiffTests: XCTestCase {
    private func fix(_ original: String, _ replacement: String, _ words: Range<Int>) -> LearnedCorrection {
        LearnedCorrection(original: original, replacement: replacement, words: words)
    }

    private let dictated = "I tried whisper flowcast yesterday and the Paystack and super base setup worked, "
        + "so I will ask Shrinny to review it before Friday."

    func testEditsAcrossAParagraphAreLearnedSeparatelyAndAdjacentWordsAsOnePhrase() {
        let edited = "I tried Wispr Flow yesterday and the pstack and Supabase setup worked, "
            + "so I will ask Srini to review it before Friday."
        let field = "Notes from today.\n\n" + edited + "\n\nMore later."

        let window = EditDiff.locateWindows(insertions: [dictated], in: field)[0]?.window
        XCTAssertEqual(window, String(edited.dropLast()))
        XCTAssertEqual(EditDiff.edits(original: dictated, replacement: edited).corrections, [
            fix("whisper flowcast", "Wispr Flow", 2..<4),
            fix("Paystack", "pstack", 7..<8),
            fix("super base", "Supabase", 9..<11),
            fix("Shrinny", "Srini", 17..<18),
        ])
    }

    func testRewordingPunctuationDeletionsAndAdditionsTeachNothing() {
        let original = "Please call him tomorrow about the invoice, it is the second reminder."
        let edited = "Please ping Priya Monday about the invoice. it is the reminder we discussed."
        XCTAssertEqual(EditDiff.edits(original: original, replacement: edited).corrections, [])
    }

    func testWordsFixedAFewSecondsApartFoldIntoOnePhrase() {
        let first = "I tried Wispr flowcast yesterday and the Paystack and super base setup worked, "
            + "so I will ask Shrinny to review it before Friday."
        let second = "I tried Wispr Flow yesterday and the Paystack and super base setup worked, "
            + "so I will ask Srini to review it before Friday."

        let firstEdits = EditDiff.edits(original: dictated, replacement: first)
        XCTAssertEqual(EditDiff.steps(for: firstEdits, after: []), [.learn(fix("whisper", "Wispr", 2..<3))])

        let secondEdits = EditDiff.edits(original: dictated, replacement: second)
        XCTAssertEqual(EditDiff.steps(for: secondEdits, after: firstEdits.corrections), [
            .revise(replacing: [fix("whisper", "Wispr", 2..<3)], with: fix("whisper flowcast", "Wispr Flow", 2..<4)),
            .learn(fix("Shrinny", "Srini", 17..<18)),
        ])
        XCTAssertEqual(EditDiff.steps(for: secondEdits, after: secondEdits.corrections), [])
    }

    func testChangingALearnedWordAgainRevisesItAndPuttingItBackForgetsIt() {
        let original = "We moved billing to Paystack last week."
        let first = EditDiff.edits(original: original, replacement: "We moved billing to Pastack last week.")
        let second = EditDiff.edits(original: original, replacement: "We moved billing to pstack last week.")
        XCTAssertEqual(EditDiff.steps(for: second, after: first.corrections), [
            .revise(replacing: [fix("Paystack", "Pastack", 4..<5)], with: fix("Paystack", "pstack", 4..<5)),
        ])
        let reverted = EditDiff.edits(original: original, replacement: original)
        XCTAssertEqual(EditDiff.steps(for: reverted, after: second.corrections), [.forget(fix("Paystack", "pstack", 4..<5))])
    }

    func testTheSameWordFixedAtAnotherPlaceIsANewEdit() {
        let original = "Shrinny said hi, and later Shrinny left."
        let first = EditDiff.edits(original: original, replacement: "Srini said hi, and later Shrinny left.")
        let second = EditDiff.edits(original: original, replacement: "Srini said hi, and later Shrini left.")
        XCTAssertEqual(EditDiff.steps(for: second, after: first.corrections), [.learn(fix("Shrinny", "Shrini", 5..<6))])
    }

    func testAnEditTooLongToLearnDoesNotForgetTheWordsInsideIt() {
        let original = "Ask the cooper netties team today."
        let first = EditDiff.edits(original: original, replacement: "Ask the Kubernetes team today.")
        let second = EditDiff.edits(original: original, replacement: "Ask the Kubernetes platform crew members today.")
        XCTAssertEqual(EditDiff.steps(for: second, after: first.corrections), [])

        let history = EditDiff.history(after: second, earlier: first.corrections)
        let restored = EditDiff.edits(original: original, replacement: "Ask the cooper netties platform crew members today.")
        XCTAssertEqual(EditDiff.steps(for: restored, after: history), [.forget(fix("cooper netties", "Kubernetes", 2..<4))])
    }
}
