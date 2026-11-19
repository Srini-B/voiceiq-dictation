import XCTest
@testable import VoiceIQCore

final class HistoryStoreTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("recordings", isDirectory: true),
            withIntermediateDirectories: true
        )
        store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(status: SessionMeta.Status, transcript: String?, onDisk: Bool) throws -> SessionMeta {
        var meta = SessionMeta(id: UUID(), startedAt: Date(), status: status)
        meta.rawTranscript = transcript
        let folder = root
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(meta.id.uuidString, isDirectory: true)
        if onDisk {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            meta.write(to: folder)
        }
        store.upsert(meta: meta, folder: folder)
        return meta
    }

    /// Rows whose folders vanished must be pruned even when the visibility
    /// filter hides them (silent / short-cancelled) — otherwise they linger as
    /// invisible ghosts forever and the DB stops mirroring the disk.
    func testReindexPrunesInvisibleOrphans() throws {
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        _ = try makeSession(status: .silent, transcript: nil, onDisk: false)
        _ = try makeSession(status: .cancelled, transcript: nil, onDisk: false)
        let keptVisible = try makeSession(status: .inserted, transcript: "hello there", onDisk: true)
        let keptInvisible = try makeSession(status: .silent, transcript: nil, onDisk: true)

        store.reindex(recordingsRoot: recordings)

        let remaining = Set(store.allIDsForTesting())
        XCTAssertEqual(remaining, [keptVisible.id.uuidString, keptInvisible.id.uuidString])
    }

    func testReindexKeepsRowsWithFolders() throws {
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let kept = try makeSession(status: .inserted, transcript: "still here", onDisk: true)
        store.reindex(recordingsRoot: recordings)
        XCTAssertEqual(store.allIDsForTesting(), [kept.id.uuidString])
    }

    /// History reads a dictation's step times back from the database, so
    /// the detail view can show them after a relaunch.
    func testStepTimesSurviveTheDatabase() throws {
        var meta = SessionMeta(id: UUID(), startedAt: Date(), status: .inserted)
        meta.rawTranscript = "hello"
        let steps = DictationSteps(finishRecording: 0.1, transcription: 0.34, live: true, writing: 2.31, insert: 0.15)
        meta.steps = steps
        store.upsert(meta: meta, folder: root.appendingPathComponent("recordings/\(meta.id.uuidString)"))
        XCTAssertEqual(store.record(id: meta.id.uuidString)?.steps, steps)
        XCTAssertEqual(steps.rows.map(\.label), ["Finish recording", "Transcription (live)", "Writing model", "Insert"])
        XCTAssertEqual(steps.rows.map(\.value), ["0.10s", "0.34s", "2.31s", "0.15s"])
    }
}
