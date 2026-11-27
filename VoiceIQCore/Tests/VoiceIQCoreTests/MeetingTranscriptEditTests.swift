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

    /// The views show one heading per turn; each line keeps its own id for Edit and Delete.
    func testTurnsGroupOnlyAdjacentLinesOfOneSpeaker() {
        let lines = [transcript[0], transcript[3], transcript[1], transcript[2], transcript[0]]
        let turns = MeetingSpeaker.turns(in: lines)
        XCTAssertEqual(turns.map { $0.map(\.text) }, [
            ["Where are we on pricing?", "Then Friday it is."],
            ["Pricing ships after the budget revue."],
            ["Um, sorry, my dog."],
            ["Where are we on pricing?"],
        ])
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
