import XCTest
@testable import VoiceIQCore

/// Editing and deleting one turn of a saved transcript: what the Mac and
/// iPhone transcript views, sync and agent access rely on.
final class MeetingTranscriptEditTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingTranscriptEditTests-\(UUID().uuidString)")
        store = MeetingStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let transcript = [
        TranscriptSegment(speaker: "you", text: "Where are we on pricing?", chunkIndex: 0, start: 3, end: 5),
        TranscriptSegment(speaker: "s1", text: "Pricing ships after the budget revue.", chunkIndex: 0, start: 6, end: 9),
        TranscriptSegment(speaker: "s2", text: "Um, sorry, my dog.", chunkIndex: 0, start: 10, end: 11),
        TranscriptSegment(speaker: "you", text: "Then Friday it is.", chunkIndex: 0, start: 12, end: 14),
    ]

    /// The views show one heading per run of one speaker; a one- or two-word
    /// reply sits inside the run without breaking it, and a lone letter is
    /// dropped. Each line keeps its own id for Edit and Delete.
    func testTurnsKeepShortRepliesInsideTheRun() {
        func line(_ speaker: String, _ text: String) -> TranscriptSegment {
            TranscriptSegment(speaker: speaker, text: text, chunkIndex: 0)
        }
        let lines = [
            line("you", "Okay."),
            line("s1", "So we've got both of these clipped on."),
            line("you", "Okay."),
            line("s1", "Is she going to answer me or not?"),
            line("you", "a"),
            line("s2", "Yes."),
            line("s1", "Right, then."),
            line("you", "Then Friday it is, everyone."),
        ]
        let turns = MeetingSpeaker.turns(in: lines)
        XCTAssertEqual(turns.map(\.speaker), ["you", "s1", "you"])
        XCTAssertEqual(turns[1].lines.map(\.segment.text), [
            "So we've got both of these clipped on.", "Okay.", "Is she going to answer me or not?", "Yes.", "Right, then.",
        ])
        XCTAssertEqual(turns[1].lines.map(\.aside), [false, true, false, true, false])
        XCTAssertEqual(turns[1].lines.map(\.id), [lines[1].id, lines[2].id, lines[3].id, lines[5].id, lines[6].id])
        // Written without spaces, a whole turn is one "word"; it still gets its own heading.
        let chinese = MeetingSpeaker.turns(in: [line("you", "我们先看一下上周的数据。"),
                                                line("s1", "注册量上周增长了百分之八，主要来自新的推荐链接。")])
        XCTAssertEqual(chinese.map(\.speaker), ["you", "s1"])
    }

    private func finishedMeeting(_ transcript: [TranscriptSegment]) throws -> MeetingID {
        var meta = MeetingMeta(id: MeetingID(), startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        _ = try store.create(meta: meta)
        try store.save(transcript: transcript, id: meta.id)
        try store.save(notes: MeetingNotes(title: "Pricing", summary: "s", decisions: [], actions: [], notes: []), id: meta.id)
        meta.status = .done
        try store.save(meta: meta)
        return meta.id
    }

    func testEditAndDeleteChangeOnlyTheirTurnAndKeepEveryID() throws {
        let id = try finishedMeeting(transcript)
        let before = try store.loadTranscript(id: id)
        XCTAssertEqual(Set(before.map(\.id)).count, 4)

        try store.editTranscriptSegment(before[1].id, text: " Pricing ships after the budget review.\n", meeting: id)
        try store.deleteTranscriptSegment(before[2].id, meeting: id)

        // A new store reads it from disk, as after a relaunch.
        let after = try MeetingStore(root: root).loadTranscript(id: id)
        XCTAssertEqual(after.map(\.id), [before[0].id, before[1].id, before[3].id])
        XCTAssertEqual(after[0], before[0])
        XCTAssertEqual(after[2], before[3])
        XCTAssertEqual(after[1].text, "Pricing ships after the budget review.")
        XCTAssertEqual(after[1].speaker, "s1")
        XCTAssertEqual(after[1].start, 6)
        XCTAssertEqual(after[1].end, 9)

        // The edited turn keeps its id through a second edit.
        try store.editTranscriptSegment(before[1].id, text: "Pricing ships in May.", meeting: id)
        XCTAssertEqual(try store.loadTranscript(id: id).map(\.text),
                       ["Where are we on pricing?", "Pricing ships in May.", "Then Friday it is."])
        XCTAssertEqual(try store.loadNotes(id: id).title, "Pricing")
    }

    func testARepeatedTurnIsEditedAndDeletedOnItsOwn() throws {
        let yeah = TranscriptSegment(speaker: "s1", text: "Yeah.", chunkIndex: 0)
        let id = try finishedMeeting([yeah, TranscriptSegment(speaker: "you", text: "Friday?", chunkIndex: 0), yeah])
        let before = try store.loadTranscript(id: id)
        XCTAssertNotEqual(before[0].id, before[2].id)

        try store.editTranscriptSegment(before[2].id, text: "Yeah, Friday.", meeting: id)
        XCTAssertEqual(try store.loadTranscript(id: id).map(\.text), ["Yeah.", "Friday?", "Yeah, Friday."])
        try store.deleteTranscriptSegment(before[0].id, meeting: id)
        let after = try store.loadTranscript(id: id)
        XCTAssertEqual(after.map(\.text), ["Friday?", "Yeah, Friday."])
        XCTAssertEqual(after.map(\.id), [before[1].id, before[2].id])
    }

    func testAnEditGoesUpAndAnOlderCopyFromICloudDoesNotUndoIt() throws {
        let id = try finishedMeeting(transcript)
        let synced = try XCTUnwrap(store.synced(id: id))
        store.markSent(synced, systemFields: Data("fields".utf8))
        XCTAssertEqual(store.pendingUploads(), [])

        try store.deleteTranscriptSegment(try store.loadTranscript(id: id)[2].id, meeting: id)
        XCTAssertEqual(store.pendingUploads(), [id])
        XCTAssertTrue(store.applyFromCloud(synced, systemFields: Data("fields".utf8)))
        XCTAssertEqual(try store.loadTranscript(id: id).count, 3)
    }

    func testAgentAccessReadsTheEditedWords() throws {
        let id = try finishedMeeting(transcript)
        try store.editTranscriptSegment(try store.loadTranscript(id: id)[1].id, text: "Pricing ships in May.", meeting: id)
        let library = AgentLibrary(history: nil, meetings: store)
        XCTAssertEqual(try library.meeting(id.uuid.uuidString).transcript[1].text, "Pricing ships in May.")
        XCTAssertEqual(library.meetings(query: "in May", since: nil, limit: 5).map(\.id), [id.uuid.uuidString])
        XCTAssertEqual(library.meetings(query: "revue", since: nil, limit: 5).count, 0)
    }
}
