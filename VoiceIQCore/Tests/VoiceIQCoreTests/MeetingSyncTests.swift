import CloudKit
import XCTest
@testable import VoiceIQCore

/// What `MeetingSync` relies on: which meetings go up, how a meeting from
/// iCloud lands on a device that did or did not change it, and which deletes
/// reach iCloud.
final class MeetingSyncTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!
    private let fields = Data("fields".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingSyncTests-\(UUID().uuidString)")
        store = MeetingStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func turn(_ question: String, at seconds: Double) -> MeetingChatTurn {
        MeetingChatTurn(question: question, answer: "a", askedAt: Date(timeIntervalSinceReferenceDate: seconds), model: "m")
    }

    private func finishedMeeting(title: String = "Launch sync") throws -> MeetingID {
        var meta = MeetingMeta(id: MeetingID(), startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        _ = try store.create(meta: meta)
        try store.save(transcript: [TranscriptSegment(speaker: "s1", text: "I'll own the launch.", chunkIndex: 0, start: 4)], id: meta.id)
        try store.save(notes: MeetingNotes(title: title, summary: "s", decisions: [], actions: [], notes: []), id: meta.id)
        meta.status = .done; meta.title = title
        try store.save(meta: meta)
        return meta.id
    }

    func testOnlyFinishedMeetingsThatChangedSinceTheLastSyncGoUp() throws {
        let recording = MeetingMeta(id: MeetingID(), startedAt: Date())
        _ = try store.create(meta: recording)
        let id = try finishedMeeting()
        XCTAssertEqual(store.pendingUploads(), [id])

        // Through a record and back, as CloudKit carries it.
        let record = try XCTUnwrap(MeetingSync.record(for: try XCTUnwrap(store.synced(id: id)), systemFields: nil))
        XCTAssertEqual(record.recordID.recordName, id.uuid.uuidString)
        let sent = try XCTUnwrap(MeetingSync.meeting(from: record))
        store.markSent(sent, systemFields: MeetingSync.systemFields(of: record))
        XCTAssertEqual(store.pendingUploads(), [])
        let again = try XCTUnwrap(MeetingSync.record(for: sent, systemFields: store.loadCloudState(id: id)?.systemFields))
        XCTAssertEqual(again.recordID, record.recordID)

        try store.renameSpeaker(id: id, label: "s1", name: "Rohan")
        XCTAssertEqual(store.pendingUploads(), [id])
    }

    func testAnUnchangedCopyTakesTheCloudVersionAndAChangedOneKeepsItsOwnWithBothDevicesQuestions() throws {
        let id = try finishedMeeting()
        var remote = try XCTUnwrap(store.synced(id: id))
        store.markSent(remote, systemFields: fields)

        remote.notes?.title = "Launch sync, redone on the Mac"
        remote.chat = [turn("Who owns it?", at: 10)]
        XCTAssertFalse(store.applyFromCloud(remote, systemFields: fields))
        XCTAssertEqual(try store.loadNotes(id: id).title, "Launch sync, redone on the Mac")
        XCTAssertEqual(store.loadChat(id: id).map(\.question), ["Who owns it?"])
        XCTAssertFalse(store.needsUpload(id: id))

        // Both devices change it before either hears from the other.
        try store.renameSpeaker(id: id, label: "s1", name: "Rohan")
        try store.save(chat: store.loadChat(id: id) + [turn("By when?", at: 30)], id: id)
        remote.notes?.title = "Redone again on the Mac"
        remote.chat.append(turn("What else?", at: 20))

        XCTAssertTrue(store.applyFromCloud(remote, systemFields: fields))
        XCTAssertEqual(try store.loadNotes(id: id).title, "Launch sync, redone on the Mac")
        XCTAssertEqual(store.list().first?.speakerNames, ["s1": "Rohan"])
        XCTAssertEqual(store.loadChat(id: id).map(\.question), ["Who owns it?", "What else?", "By when?"])
        XCTAssertTrue(store.needsUpload(id: id))
    }

    func testMeetingsFromAnotherDeviceGoWithTheAccountAndDeletesOfMeetingsThatMayBeInICloudReachIt() throws {
        let own = try finishedMeeting()
        store.markSent(try XCTUnwrap(store.synced(id: own)), systemFields: fields)
        let unfinished = MeetingMeta(id: MeetingID(), startedAt: Date())
        _ = try store.create(meta: unfinished)
        // Finished but not sent yet: its first upload may be on its way.
        let uploading = try finishedMeeting()
        var arriving = try XCTUnwrap(store.synced(id: own))
        arriving.meta.id = MeetingID()
        XCTAssertFalse(store.applyFromCloud(arriving, systemFields: fields))
        XCTAssertEqual(store.synced(id: arriving.meta.id), arriving)

        // The last change posted for each meeting: its delete.
        nonisolated(unsafe) var deletes: [String: Bool] = [:]
        let observer = NotificationCenter.default.addObserver(forName: .gtMeetingsDidChange, object: nil, queue: nil) { note in
            guard let id = note.userInfo?[MeetingStore.idKey] as? String else { return }
            deletes[id] = note.userInfo?[MeetingStore.deletedFromCloudKey] as? Bool
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try store.delete(id: unfinished.id)
        XCTAssertEqual(deletes[unfinished.id.uuid.uuidString], false)
        try store.delete(id: uploading)
        XCTAssertEqual(deletes[uploading.uuid.uuidString], true)

        store.forgetCloud()
        XCTAssertEqual(store.list().map(\.id), [own])
        XCTAssertNil(store.loadCloudState(id: own))

        let synced = try finishedMeeting()
        let copy = try XCTUnwrap(store.synced(id: synced))
        store.markSent(copy, systemFields: fields)
        try store.delete(id: synced)
        XCTAssertEqual(deletes[synced.uuid.uuidString], true)
        // Its copy fetched before iCloud confirms the delete does not bring it back.
        XCTAssertFalse(store.applyFromCloud(copy, systemFields: fields))
        XCTAssertNil(store.folder(for: synced))
    }
}
