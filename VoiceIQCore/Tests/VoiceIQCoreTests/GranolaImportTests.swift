import XCTest
@testable import VoiceIQCore

/// Importing Granola's account export (a ZIP of CSVs) into meetings. The
/// fixtures are synthetic; Fixtures/make_granola_export.py writes them.
final class GranolaImportTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!

    private let planning = MeetingID(uuid: UUID(uuidString: "0b7e6d2a-1c3f-4e5a-9b8c-7d6e5f4a3b21")!)
    private let hiring = MeetingID(uuid: UUID(uuidString: "5f1a2b3c-4d5e-4f60-8a71-b2c3d4e5f607")!)
    private let customer = MeetingID(uuid: UUID(uuidString: "7c6b5a49-3827-4165-9f4e-3d2c1b0a9f8e")!)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GranolaImportTests-\(UUID().uuidString)")
        store = MeetingStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures"))
    }

    @MainActor
    private func importFixture() async throws -> GranolaImportReport {
        let plan = GranolaImport.plan(try GranolaImport.read(try fixture("granola-export")), store: store)
        return await GranolaImport.run(plan, store: store)
    }

    func testReadsEveryMeetingAndReportsTheRowsItSkips() throws {
        let export = try GranolaImport.read(try fixture("granola-export"))
        XCTAssertEqual(export.meetings.map(\.id), [planning, hiring, customer])
        let first = export.meetings[0]
        XCTAssertEqual(first.title, "Atlas planning, Q1 ☕")
        XCTAssertEqual(first.createdAt.timeIntervalSince1970, 1_792_852_480.866, accuracy: 0.001)
        XCTAssertEqual(first.notes, "remember the \"beta\" badge\n- ask about SSO")
        XCTAssertEqual(export.meetings[2].createdAt.timeIntervalSince1970, 1_795_191_300)
        XCTAssertEqual(export.skipped.map(\.title), ["Bad date", "Empty note", "Hiring sync"])
        XCTAssertEqual(export.skipped.map(\.place), ["notes-1.csv, row 4", "notes-1.csv, row 5", "notes-2.csv, row 3"])
        XCTAssertEqual(export.skipped.map(\.reason), ["No readable date (not a date)", "No notes, summary or transcript",
                                                      "Appears earlier in the export"])
    }

    @MainActor
    func testImportedMeetingsAreFinishedMeetingsWithGranolasNotesInVoiceiQsShape() async throws {
        let report = try await importFixture()
        XCTAssertEqual(report.imported, 3)
        XCTAssertEqual(report.skipped.count, 3)

        let listed = store.list()
        XCTAssertEqual(listed.map(\.id), [customer, planning, hiring])
        let meta = try XCTUnwrap(listed.first { $0.id == planning })
        XCTAssertEqual(meta.status, .done)
        XCTAssertEqual(meta.title, "Atlas planning, Q1 ☕")
        XCTAssertEqual(meta.importedFrom, "Granola")
        XCTAssertEqual(meta.startedAt.timeIntervalSince1970, 1_792_852_480.866, accuracy: 0.001)

        let notes = try store.loadNotes(id: planning)
        XCTAssertEqual(notes.summary, "Quarterly planning for the Atlas launch.")
        XCTAssertEqual(notes.sections, [NoteSection(title: "Launch scope", items: [
            "Ship the beta to 50 design partners\n◦ Start with the three pilot teams", "Keep pricing out of v1",
        ])])
        XCTAssertEqual(notes.decisions, ["Launch date is 14 March"])
        XCTAssertEqual(notes.actions, [ActionItem(text: "Priya: send the partner list by Friday"), ActionItem(text: "Book the launch review")])
        XCTAssertEqual(notes.notes, ["remember the \"beta\" badge", "ask about SSO"])
        XCTAssertEqual(try store.loadTranscript(id: planning), [
            TranscriptSegment(speaker: MeetingSpeaker.you, text: "Shall we start with scope?", chunkIndex: 0),
            TranscriptSegment(speaker: "s1", text: "Yes, scope first.\nThe beta goes to fifty partners.", chunkIndex: 0),
        ])

        // Bold lines as headings, numbered next steps as actions, no labels in the transcript.
        let call = try store.loadNotes(id: customer)
        XCTAssertEqual(call.sections, [NoteSection(title: "Overview", items: ["They want exports."])])
        XCTAssertEqual(call.actions, [ActionItem(text: "Send the API docs")])
        XCTAssertEqual(try store.loadTranscript(id: customer), [
            TranscriptSegment(speaker: GranolaImport.unlabeledSpeaker, text: "Thanks for joining. We mostly use spreadsheets today.", chunkIndex: 0),
        ])

        // Typed notes only: no transcript, and the meeting still exports.
        XCTAssertEqual(try store.loadNotes(id: hiring).notes, ["Candidate pipeline looks healthy"])
        XCTAssertThrowsError(try store.loadTranscript(id: hiring))
        let markdown = try store.markdown(id: hiring, parts: .notes)
        XCTAssertTrue(markdown.contains("Imported from Granola"))
        XCTAssertFalse(markdown.contains("0 seconds"))
    }

    @MainActor
    func testImportedMeetingsSyncAndAreReadableByCodingAgents() async throws {
        _ = try await importFixture()
        XCTAssertEqual(Set(store.pendingUploads()), [planning, hiring, customer])
        XCTAssertEqual(store.synced(id: planning)?.meta.importedFrom, "Granola")

        let agent = try AgentLibrary(history: nil, meetings: store).meeting(planning.uuid.uuidString)
        XCTAssertEqual(agent.meeting.title, "Atlas planning, Q1 ☕")
        XCTAssertEqual(agent.notes?.decisions, ["Launch date is 14 March"])
        XCTAssertEqual(agent.transcript.map(\.speaker), ["You", "Speaker 1"])
    }

    @MainActor
    func testImportingTheSameExportAgainChangesNothing() async throws {
        _ = try await importFixture()
        try store.save(notes: MeetingNotes(title: "Edited here", summary: "Mine", decisions: [], actions: [], notes: []), id: planning)

        let plan = GranolaImport.plan(try GranolaImport.read(try fixture("granola-export")), store: store)
        XCTAssertTrue(plan.new.isEmpty)
        XCTAssertEqual(Set(plan.existing.map(\.id)), [planning, hiring, customer])
        let report = await GranolaImport.run(plan, store: store)
        XCTAssertEqual(report.imported, 0)
        XCTAssertEqual(report.existing, 3)
        XCTAssertEqual(store.list().count, 3)
        XCTAssertEqual(try store.loadNotes(id: planning).summary, "Mine")
    }

    @MainActor
    func testAMeetingDeletedHereIsNotBroughtBack() async throws {
        _ = try await importFixture()
        try store.delete(id: hiring)

        let plan = GranolaImport.plan(try GranolaImport.read(try fixture("granola-export")), store: store)
        XCTAssertTrue(plan.new.isEmpty)
        XCTAssertEqual(plan.skipped.last?.title, "Hiring sync")
        XCTAssertEqual(plan.skipped.last?.reason, "You deleted it in VoiceiQ")
    }

    func testFilesThatAreNotAGranolaExportAreRefusedWithAReason() throws {
        XCTAssertThrowsError(try GranolaImport.read(try fixture("not-granola"))) { error in
            XCTAssertEqual(error as? GranolaImportError, .unreadable("This ZIP has no CSV file in it. Choose the ZIP from Granola's export email."))
        }
        XCTAssertThrowsError(try GranolaImport.read(zip: Data("not a zip at all, just text".utf8))) { error in
            XCTAssertEqual(error as? GranolaImportError, .unreadable("This isn't a ZIP file. Choose the ZIP from Granola's export email."))
        }
        XCTAssertThrowsError(try GranolaImport.csvExport([("other.csv", Data("name,email\nAda,ada@example.test\n".utf8))])) { error in
            XCTAssertEqual((error as? GranolaImportError)?.errorDescription?.hasPrefix("other.csv doesn't have Granola's columns"), true)
        }
    }

    func testADamagedZipIsRefusedRatherThanHalfRead() throws {
        var data = try Data(contentsOf: try fixture("granola-export"))
        // Inside the first CSV's compressed bytes, past its 30-byte local header and name.
        let start = try XCTUnwrap(data.range(of: Data("granola-export/notes-1.csv".utf8))).upperBound
        data[start + 40] ^= 0xFF
        XCTAssertThrowsError(try GranolaImport.read(zip: data)) { error in
            XCTAssertTrue((error as? GranolaImportError)?.errorDescription?.hasPrefix("This ZIP is damaged") == true, "\(error)")
        }
    }

    func testCSVQuotingSurvivesCommasQuotesAndLineBreaks() throws {
        let rows = try GranolaImport.csvRows("\u{FEFF}a,b\r\n\"x, \"\"y\"\"\",\"line 1\nline 2\"\r\n")
        XCTAssertEqual(rows, [["a", "b"], ["x, \"y\"", "line 1\nline 2"]])
        XCTAssertThrowsError(try GranolaImport.csvRows("a,\"never closed\n"))
    }

    func testANonUUIDDocumentIDAlwaysMapsToTheSameMeeting() {
        let id = GranolaImport.meetingID(documentID: "not-a-uuid")
        XCTAssertEqual(id, GranolaImport.meetingID(documentID: "not-a-uuid"))
        XCTAssertNotEqual(id, GranolaImport.meetingID(documentID: "not-a-uuid-2"))
    }
}
