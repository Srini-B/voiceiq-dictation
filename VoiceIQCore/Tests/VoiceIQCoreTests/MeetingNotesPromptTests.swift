import XCTest
@testable import VoiceIQCore

final class MeetingNotesPromptTests: XCTestCase {
    func testNotesFollowedByMoreTextStillParse() throws {
        let reply = #"{"title":"Release {planning}","summary":"Moved to \"Wednesday\".","decisions":[],"actions":[],"notes":[]}"# + "\n{\"title\":\"again\"}"

        let notes = try MeetingNotesPrompt.parse(reply)

        XCTAssertEqual(notes.title, "Release {planning}")
        XCTAssertEqual(notes.summary, "Moved to \"Wednesday\".")
    }

    func testNotesWithoutActionsForACommitmentAreAskedForAgain() {
        let call = [TranscriptSegment(speaker: "you", text: "Can I ask where the screenshots are?", chunkIndex: 0, start: 2, end: 4),
                    TranscriptSegment(speaker: "s1", text: "I think they're nearly done.", chunkIndex: 0, start: 5, end: 7),
                    TranscriptSegment(speaker: "s2", text: "Then I will upload them in the evening.", chunkIndex: 0, start: 65, end: 68)]
        let empty = MeetingNotes(title: "Release", summary: "", decisions: [], actions: [], notes: [])

        let ask = MeetingNotesPrompt.missingActions(empty, transcript: call)
        XCTAssertTrue(ask?.contains("[01:05] Then I will upload them in the evening.") == true)
        XCTAssertFalse(ask?.contains("screenshots are") == true)

        var listed = empty
        listed.actions = [ActionItem(text: "Upload the screenshots", owner: nil, deadline: "in the evening")]
        XCTAssertNil(MeetingNotesPrompt.missingActions(listed, transcript: call))
        XCTAssertNil(MeetingNotesPrompt.missingActions(empty, transcript: Array(call.prefix(2))))
    }
}
