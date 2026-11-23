import XCTest
@testable import VoiceIQCore

/// Meeting folders: the list each device keeps and merges with iCloud's, and
/// the folders a meeting is filed in, which travel with the meeting.
final class MeetingFoldersTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingFoldersTests-\(UUID().uuidString)")
        store = MeetingStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func time(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds) }

    private func finishedMeeting() throws -> MeetingID {
        var meta = MeetingMeta(id: MeetingID(), startedAt: time(0))
        _ = try store.create(meta: meta)
        try store.save(transcript: [TranscriptSegment(speaker: "s1", text: "Hi", chunkIndex: 0)], id: meta.id)
        meta.status = .done
        try store.save(meta: meta)
        return meta.id
    }

    func testCreatingANameThatExistsReturnsThatFolder() throws {
        let clients = try store.createFolder(named: "  Clients ")
        XCTAssertEqual(clients.name, "Clients")
        XCTAssertEqual(try store.createFolder(named: "clients"), clients)
        try store.createFolder(named: "acme")
        XCTAssertEqual(store.folders().map(\.name), ["acme", "Clients"])
        XCTAssertThrowsError(try store.createFolder(named: " "))
        XCTAssertThrowsError(try store.renameFolder(clients.id, to: ""))

        // A list that cannot be read is never saved over.
        try Data("{".utf8).write(to: store.foldersURL)
        XCTAssertThrowsError(try store.createFolder(named: "New"))
        XCTAssertEqual(try String(contentsOf: store.foldersURL, encoding: .utf8), "{")
    }

    func testMergeKeepsNewerEditsAndDeletesWhateverTheOrder() {
        let kept = MeetingFolder(name: "Clients", createdAt: time(0))
        var renamed = kept
        renamed.name = "Customers"; renamed.updatedAt = time(10)
        let deletedLater = MeetingFolder(name: "Old", createdAt: time(0))
        let renamedAfterDelete = MeetingFolder(name: "Revived", createdAt: time(0), updatedAt: time(30))
        let fresh = MeetingFolder(name: "Clients", createdAt: time(5))
        let twin = MeetingFolder(name: "CLIENTS", createdAt: time(7))

        let mac = MeetingFoldersSnapshot(folders: [kept, deletedLater, renamedAfterDelete, twin],
                                         tombstones: [:])
        let phone = MeetingFoldersSnapshot(folders: [renamed, fresh],
                                           tombstones: [deletedLater.id.uuidString: time(20),
                                                        renamedAfterDelete.id.uuidString: time(20)])
        let now = time(40)
        let merged = MeetingFoldersSnapshot.merge(mac, phone, now: now)
        XCTAssertEqual(merged, MeetingFoldersSnapshot.merge(phone, mac, now: now))
        // The rename wins over the older copy; a delete wins over an older copy and loses to a later
        // rename; the same name made apart on each device becomes the older folder, and meetings
        // filed in the newer one count as filed in it.
        XCTAssertEqual(merged.folders.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       [kept.id, fresh.id, renamedAfterDelete.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(merged.folders.first { $0.id == kept.id }?.name, "Customers")
        XCTAssertEqual(merged.tombstones.count, 2)
        XCTAssertEqual(merged.resolve([twin.id, kept.id, fresh.id, deletedLater.id]), [fresh.id, kept.id])

        // Deletions are forgotten once older than the lifetime.
        let later = time(20 + MeetingFoldersSnapshot.tombstoneLifetime + 1)
        XCTAssertTrue(MeetingFoldersSnapshot.merge(merged, MeetingFoldersSnapshot(), now: later).tombstones.isEmpty)
    }

    func testDeletingAFolderLeavesItsMeetingsAndHidesIt() throws {
        let id = try finishedMeeting()
        let a = try store.createFolder(named: "A"), b = try store.createFolder(named: "B")
        try store.setFolderIDs([b.id, a.id, b.id], for: id)
        XCTAssertEqual(store.folderIDs(of: id), [b.id, a.id])
        try store.deleteFolder(b.id)
        XCTAssertEqual(store.list().map(\.id), [id])
        XCTAssertEqual(store.folderIDs(of: id), [a.id])
        XCTAssertEqual(store.foldersSnapshot().tombstones.keys.sorted(), [b.id.uuidString])
        try store.setMeeting(id, inFolder: a.id, false)
        XCTAssertEqual(store.folderIDs(of: id), [])

        // A folder that has not synced here yet stays on the meeting while another is toggled.
        let notYetHere = UUID()
        try store.setFolderIDs([notYetHere], for: id)
        try store.setMeeting(id, inFolder: a.id, true)
        try store.setMeeting(id, inFolder: a.id, false)
        XCTAssertEqual(store.storedFolderIDs(of: id), [notYetHere])
        try store.setFolderIDs([], for: id)

        // Renamed to another folder's name, the two become one, with the meetings of both.
        let c = try store.createFolder(named: "C")
        try store.setFolderIDs([c.id], for: id)
        try store.renameFolder(a.id, to: "c")
        XCTAssertEqual(store.folders().map(\.id), [a.id])
        XCTAssertEqual(store.folderIDs(of: id), [a.id])

        // A membership file that cannot be read is never saved over by a toggle.
        let url = try XCTUnwrap(store.folder(for: id)).appendingPathComponent(MeetingStore.folderIDsFile)
        try Data("[".utf8).write(to: url)
        XCTAssertThrowsError(try store.setMeeting(id, inFolder: a.id, false))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[")
    }

    func testAMeetingStaysFiledThroughAnyNumberOfMerges() {
        // Each folder merged into the next, ten times: the first id still leads to the last.
        let ids = (0..<11).map { _ in UUID() }
        let aliases = Dictionary(uniqueKeysWithValues: zip(ids.dropLast(), ids.dropFirst()).map { ($0.uuidString, $1) })
        let last = MeetingFolder(id: ids[10], name: "Last", createdAt: time(0))
        XCTAssertEqual(MeetingFoldersSnapshot(folders: [last], aliases: aliases).resolve([ids[0]]), [ids[10]])
        // A loop, which a merge cannot make but a bad file could, ends instead of hanging.
        let loop = [ids[0].uuidString: ids[1], ids[1].uuidString: ids[0]]
        XCTAssertEqual(MeetingFoldersSnapshot(folders: [], aliases: loop).resolve([ids[0]]), [])
    }

    func testFoldersTravelWithTheMeetingAndNoneLeavesItAsBefore() throws {
        let id = try finishedMeeting()
        let before = try XCTUnwrap(store.synced(id: id))
        let json = String(decoding: try JSONEncoder().encode(before), as: UTF8.self)
        XCTAssertFalse(json.contains("folderIDs"), "a meeting in no folder must keep the digest it had before folders")
        store.markSent(before, systemFields: Data("f".utf8))
        XCTAssertEqual(store.pendingUploads(), [])

        let folder = try store.createFolder(named: "Clients")
        try store.setMeeting(id, inFolder: folder.id, true)
        XCTAssertEqual(store.pendingUploads(), [id])
        let filed = try XCTUnwrap(store.synced(id: id))
        XCTAssertEqual(filed.folderIDs, [folder.id])
        store.markSent(filed, systemFields: Data("f".utf8))

        // Another device took it out of the folder; this one changed nothing.
        XCTAssertFalse(store.applyFromCloud(before, systemFields: Data("g".utf8)))
        XCTAssertEqual(store.folderIDs(of: id), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.folder(for: id))
            .appendingPathComponent(MeetingStore.folderIDsFile).path))

        // And a new device gets the folders with the meeting.
        let other = MeetingStore(root: root.appendingPathComponent("other"))
        try other.saveFolders(store.foldersSnapshot())
        other.applyFromCloud(filed, systemFields: Data("f".utf8))
        XCTAssertEqual(other.folderIDs(of: id), [folder.id])
        XCTAssertEqual(other.pendingUploads(), [])

        // A membership file that cannot be read never goes up as no folders.
        try Data("[".utf8).write(to: try XCTUnwrap(other.folder(for: id)).appendingPathComponent(MeetingStore.folderIDsFile))
        XCTAssertNil(other.synced(id: id))
    }
}
