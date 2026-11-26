import XCTest
@testable import VoiceIQCore

final class MeetingNotesPromptTests: XCTestCase {
    func testNotesFollowedByMoreTextStillParse() throws {
        let reply = #"{"title":"Release {planning}","summary":"Moved to \"Wednesday\".","decisions":[],"actions":[],"notes":[]}"# + "\n{\"title\":\"again\"}"

        let notes = try MeetingNotesPrompt.parse(reply)

        XCTAssertEqual(notes.title, "Release {planning}")
        XCTAssertEqual(notes.summary, "Moved to \"Wednesday\".")
    }
}
