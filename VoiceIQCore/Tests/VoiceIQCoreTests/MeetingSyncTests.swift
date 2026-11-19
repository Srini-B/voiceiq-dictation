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

    func testAMeetingThatCouldNotBeWrittenIsNeverSentHalfWrittenAndIsTakenWholeOnRetry() throws {
        var arriving = try XCTUnwrap(store.synced(id: try finishedMeeting()))
        arriving.meta.id = MeetingID()
        // The meetings folder cannot take a new meeting, as on a full disk.
        try FileManager.default.createDirectory(at: store.syncFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        XCTAssertFalse(store.applyFromCloud(arriving, systemFields: fields))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertNil(store.folder(for: arriving.meta.id))
        XCTAssertEqual(store.failedImports, [arriving.meta.id.uuid.uuidString])

        XCTAssertFalse(store.applyFromCloud(arriving, systemFields: fields))
        XCTAssertEqual(store.synced(id: arriving.meta.id), arriving)
        XCTAssertEqual(store.failedImports, [])

        // An update that cannot be written is not sent as a local edit, and is taken whole on retry.
        var update = arriving
        update.notes?.title = "Redone on the Mac"
        update.chat = [turn("Who owns it?", at: 10)]
        let folder = try XCTUnwrap(store.folder(for: arriving.meta.id))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertFalse(store.applyFromCloud(update, systemFields: fields))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertEqual(store.failedImports, [arriving.meta.id.uuid.uuidString])
        try store.renameSpeaker(id: arriving.meta.id, label: "s1", name: "Rohan")
        XCTAssertFalse(store.needsUpload(id: arriving.meta.id))

        XCTAssertFalse(store.applyFromCloud(update, systemFields: fields))
        XCTAssertEqual(store.synced(id: arriving.meta.id), update)
        XCTAssertEqual(store.failedImports, [])
        XCTAssertFalse(store.needsUpload(id: arriving.meta.id))
        // Deleted on the other device before a retry came back: the retry is dropped.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        var other = update
        other.meta.id = MeetingID()
        XCTAssertFalse(store.applyFromCloud(other, systemFields: fields))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        store.deleteFromCloud(id: other.meta.id)
        XCTAssertFalse(store.failedImports.contains(other.meta.id.uuid.uuidString))
    }

    func testAMeetingWhoseCopyWasNotFoundWaitsForAFetchBeforeItGoesUpAgain() throws {
        let kept = try finishedMeeting(), deleted = try finishedMeeting()
        for id in [kept, deleted] { store.markSent(try XCTUnwrap(store.synced(id: id)), systemFields: fields) }
        let heldAt = Date(timeIntervalSinceReferenceDate: 1_000)
        store.hold(id: kept, at: heldAt)
        store.hold(id: deleted, at: heldAt)
        XCTAssertNil(store.loadCloudState(id: kept)?.systemFields)

        // Edited, or the app relaunched, before the fetch: still held.
        try store.renameSpeaker(id: kept, label: "s1", name: "Rohan")
        XCTAssertEqual(store.pendingUploads(), [])
        // A save queued before the hold is not built either; a relaunch reads the hold from disk.
        XCTAssertNil(store.outgoing(id: kept))
        XCTAssertNil(MeetingStore(root: root).outgoing(id: kept))
        // A fetch that started before the hold proves nothing.
        XCTAssertEqual(store.releaseHeld(before: heldAt.addingTimeInterval(-1)), [])

        // The next whole fetch brought a delete for one; the other's zone was made again.
        store.deleteFromCloud(id: deleted)
        XCTAssertEqual(store.releaseHeld(before: heldAt.addingTimeInterval(1)), [kept])
        XCTAssertEqual(store.pendingUploads(), [kept])
        XCTAssertNil(store.folder(for: deleted))
    }

    func testMeetingsFromAnotherDeviceGoWithTheAccountAndEveryDeleteReachesICloud() throws {
        let own = try finishedMeeting()
        store.markSent(try XCTUnwrap(store.synced(id: own)), systemFields: fields)
        // Finished, its first upload on its way, and unfinished again for a redo.
        let redoing = try finishedMeeting()
        var meta = try XCTUnwrap(store.list().first { $0.id == redoing })
        meta.status = .summarizing
        try store.save(meta: meta)
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
        try store.delete(id: redoing)
        XCTAssertEqual(deletes[redoing.uuid.uuidString], true)
        XCTAssertTrue(store.pendingDeletes.contains(redoing.uuid.uuidString))

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
