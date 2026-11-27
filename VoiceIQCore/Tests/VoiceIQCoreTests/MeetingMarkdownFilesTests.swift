#if os(macOS)
import XCTest
@testable import VoiceIQCore

/// Each finished meeting saved as Markdown in the user's folder, never over the user's own edits.
final class MeetingMarkdownFilesTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!
    private var files: MeetingMarkdownFiles!
    private let id = MeetingID()
    private let startedAt = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingMarkdownFilesTests-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = MeetingStore(root: root.appendingPathComponent("meetings"))
        files = MeetingMarkdownFiles(store: store, folder: folder, ledgerURL: root.appendingPathComponent("ledger.json"))
        _ = try store.create(meta: MeetingMeta(id: id, startedAt: startedAt, durationSeconds: 600, status: .summarizing))
        try store.save(transcript: [TranscriptSegment(speaker: "you", text: "Pricing ships in May.", chunkIndex: 0, start: 3, end: 5)], id: id)
        try store.save(notes: notes("Pricing sync", summary: "Pricing ships in May."), id: id)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func notes(_ title: String, summary: String) -> MeetingNotes {
        MeetingNotes(title: title, summary: summary, decisions: [], actions: [], notes: [])
    }

    private func finish() throws {
        var meta = try XCTUnwrap(store.list().first { $0.id == id })
        meta.status = .done
        try store.save(meta: meta)
    }

    private func expectedName(_ title: String, _ suffix: String = "") -> String {
        "\(MeetingMarkdownFiles.name(title: title, startedAt: startedAt))\(suffix).md"
    }

    func testFirstWriteIsTheExportMarkdownOnceTheMeetingIsDone() throws {
        XCTAssertEqual(try files.save(id), .notReady)
        try finish()
        guard case .wrote(let url) = try files.save(id) else { return XCTFail("not written") }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(url.lastPathComponent, "Pricing sync \(day.string(from: startedAt)).md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), try store.markdown(id: id, parts: .both))
        XCTAssertEqual(try files.save(id), .unchanged(url))
    }

    func testAnUnchangedFileFollowsRedoneNotesAndARename() throws {
        try finish()
        guard case .wrote(let first) = try files.save(id) else { return XCTFail("not written") }

        try store.save(notes: notes("Pricing sync", summary: "Pricing ships in June."), id: id)
        XCTAssertEqual(try files.save(id), .wrote(first))
        XCTAssertTrue(try String(contentsOf: first, encoding: .utf8).contains("Pricing ships in June."))

        try store.renameMeeting(id: id, title: "Q3 pricing")
        guard case .wrote(let renamed) = try files.save(id) else { return XCTFail("not rewritten") }
        XCTAssertEqual(renamed.lastPathComponent, expectedName("Q3 pricing"))
        XCTAssertTrue(try String(contentsOf: renamed, encoding: .utf8).hasPrefix("# Q3 pricing\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testAFileTheUserEditedIsLeftAlone() throws {
        try finish()
        guard case .wrote(let url) = try files.save(id) else { return XCTFail("not written") }
        let edited = try String(contentsOf: url, encoding: .utf8) + "\nMy own note.\n"
        try edited.write(to: url, atomically: true, encoding: .utf8)

        try store.save(notes: notes("Pricing sync", summary: "Pricing ships in June."), id: id)
        XCTAssertEqual(try files.save(id), .leftAlone(url))
        try store.renameMeeting(id: id, title: "Q3 pricing")
        XCTAssertEqual(try files.save(id), .leftAlone(url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(expectedName("Q3 pricing")).path))
    }

    func testATakenNameGetsANumber() throws {
        try finish()
        let folder = files.folder
        try "Someone else's file".write(to: folder.appendingPathComponent(expectedName("Pricing sync")), atomically: true, encoding: .utf8)
        try "And another".write(to: folder.appendingPathComponent(expectedName("Pricing sync", " 2")), atomically: true, encoding: .utf8)
        guard case .wrote(let url) = try files.save(id) else { return XCTFail("not written") }
        XCTAssertEqual(url.lastPathComponent, expectedName("Pricing sync", " 3"))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(expectedName("Pricing sync")), encoding: .utf8), "Someone else's file")
    }

    func testTitlesBecomeSafeFileNames() {
        XCTAssertTrue(MeetingMarkdownFiles.name(title: "Q3/Q4: plan", startedAt: startedAt).hasPrefix("Q3-Q4- plan "))
        XCTAssertTrue(MeetingMarkdownFiles.name(title: "...", startedAt: startedAt).hasPrefix("Meeting "))
    }
    /// A long title in a script of 3-byte characters still fits a 255-byte filename.
    func testALongNonASCIITitleFitsAFilename() {
        let name = MeetingMarkdownFiles.name(title: String(repeating: "会", count: 110), startedAt: Date())
        XCTAssertLessThanOrEqual((name + " 99.md").utf8.count, 255)
        XCTAssertTrue(name.hasPrefix("会"))
    }

}
#endif
