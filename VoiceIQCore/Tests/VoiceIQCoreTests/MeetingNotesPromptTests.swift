import XCTest
@testable import VoiceIQCore

final class MeetingNotesPromptTests: XCTestCase {
    func testNotesFollowedByMoreTextStillParse() throws {
        let reply = #"{"title":"Release {planning}","summary":"Moved to \"Wednesday\".","decisions":[],"actions":[],"notes":[]}"# + "\n{\"title\":\"again\"}"

        let notes = try MeetingNotesPrompt.parse(reply)

        XCTAssertEqual(notes.title, "Release {planning}")
        XCTAssertEqual(notes.summary, "Moved to \"Wednesday\".")
    }

    /// MEASURED 2026-11-28, AMI ES2004a: "Speaker 4 noted that…" in 1 of 6
    /// runs, and "Speaker B" (the eval's owner) in another.
    func testSpeakerLabelsNeverReachTheNotes() throws {
        let reply = #"{"title":"Kickoff","summary":"Speaker 4 noted the website. The team agreed with Speaker 2.","decisions":["Speaker 1 picks the colour."],"actions":[{"text":"Ask Speaker 1 for costs","owner":"Speaker 2"},{"text":"Draw","owner":"Speaker 1"}],"notes":[],"speakers":[{"label":"Speaker 1","name":"Sarah","evidence":"Thanks, Sarah"},{"label":"Speaker 2","name":null}]}"#

        let notes = try MeetingNotesPrompt.parse(reply)

        XCTAssertEqual(notes.summary, "Another participant noted the website. The team agreed with another participant.")
        XCTAssertEqual(notes.decisions, ["Sarah picks the colour."])
        XCTAssertEqual(notes.actions.map(\.text), ["Ask Sarah for costs", "Draw"])
        XCTAssertEqual(notes.actions.map(\.owner), [nil, "Sarah"])

        let prompt = MeetingNotesPrompt.build(transcript: [TranscriptSegment(speaker: "you", text: "Hi.", chunkIndex: 0, start: 1)],
                                              context: .init(startedAt: Date(), durationSeconds: 60, app: nil, names: [:], ownerName: "Speaker B"))
        XCTAssertFalse(prompt.contains("Speaker B"))
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

    func testNotesLanguageIsTheSettingUnlessTheTranscriptIsClearlyAnother() {
        let say = { (text: String) in [TranscriptSegment(speaker: "s1", text: text, chunkIndex: 0, start: 0, end: 1)] }
        let shortForeign = say("Design de produto e usabilidade, vamos falar do controle remoto.")
        let spanish = say(Array(repeating: "Hoy vamos a revisar el presupuesto del proyecto y decidir quién prepara el informe para la reunión del viernes con el cliente.", count: 8).joined(separator: " "))
        let english = say(Array(repeating: "Okay so um the remote control should be cheap and we need to decide the buttons before Friday.", count: 10).joined(separator: " "))

        XCTAssertEqual(MeetingNotesPrompt.outputLanguage(shortForeign, preferred: nil), "English")
        XCTAssertEqual(MeetingNotesPrompt.outputLanguage(shortForeign, preferred: "en"), "English")
        XCTAssertEqual(MeetingNotesPrompt.outputLanguage(shortForeign, preferred: "hi"), "Hindi")
        XCTAssertEqual(MeetingNotesPrompt.outputLanguage(spanish, preferred: "en"), "Spanish")
        XCTAssertEqual(MeetingNotesPrompt.outputLanguage(english, preferred: "pt"), "English")
        let japanese = say(Array(repeating: "今日はプロジェクトの予算を確認して、金曜日の会議までに誰が報告書を準備するかを決めましょう。", count: 12).joined())
        XCTAssertEqual(MeetingNotesPrompt.outputLanguage(japanese, preferred: nil), "Japanese")
    }
}
