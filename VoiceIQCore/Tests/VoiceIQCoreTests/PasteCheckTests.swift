import XCTest
@testable import VoiceIQCore

final class PasteCheckTests: XCTestCase {
    private func reading(_ value: String, caret: Int, selected: Int = 0) -> PasteCheck.Reading {
        .init(value: value, caret: caret, selectionLength: selected)
    }

    func testTextThatAppearsHasLanded() {
        let before = reading("Hi ", caret: 3)
        XCTAssertEqual(PasteCheck.verdict(before: before, after: reading("Hi there", caret: 8), text: "there"), .landed)
    }

    func testReplacingASelectionHasLanded() {
        // "old" was selected and the paste replaced it: the field grew by 2, not 5.
        let before = reading("say old now", caret: 4, selected: 3)
        XCTAssertEqual(PasteCheck.verdict(before: before, after: reading("say hello now", caret: 9), text: "hello"), .landed)
    }

    func testAnUnchangedFieldIsAMiss() {
        let before = reading("draft", caret: 5)
        XCTAssertEqual(PasteCheck.verdict(before: before, after: before, text: "more words"), .missed)
    }

    func testOtherChangesSayNothing() {
        let before = reading("draft", caret: 5)
        // The app reformatted the field, or the user edited it: not a verdict either way.
        XCTAssertEqual(PasteCheck.verdict(before: before, after: reading("Draft", caret: 5), text: "more words"), .unknown)
        XCTAssertEqual(PasteCheck.verdict(before: before, after: nil, text: "more words"), .unknown)
    }

    #if os(macOS)
    func testReturnAfterPasteAppliesToEveryAppOrOnlyTheChosenOnes() {
        XCTAssertTrue(ReturnAfterPaste.applies(to: "com.tinyspeck.slackmacgap", apps: []))
        XCTAssertTrue(ReturnAfterPaste.applies(to: "com.tinyspeck.slackmacgap", apps: ["com.tinyspeck.slackmacgap"]))
        XCTAssertFalse(ReturnAfterPaste.applies(to: "com.apple.mail", apps: ["com.tinyspeck.slackmacgap"]))
        XCTAssertFalse(ReturnAfterPaste.applies(to: nil, apps: ["com.tinyspeck.slackmacgap"]))
    }
    #endif
}
