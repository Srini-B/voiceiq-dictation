import XCTest
@testable import VoiceIQCore

/// Dictations the iPhone keyboard ran by itself reach the app's History
/// through `KeyboardInbox`. A folder lost here is a lost dictation.
final class KeyboardInboxTests: XCTestCase {
    private var inbox: URL!
    private var appRoot: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        inbox = base.appendingPathComponent("inbox")
        appRoot = base.appendingPathComponent("app")
        FileLayout.overrideRoot = appRoot
    }

    override func tearDown() {
        FileLayout.overrideRoot = nil
        try? FileManager.default.removeItem(at: inbox.deletingLastPathComponent())
    }

    private func session(named name: String, status: SessionMeta.Status) throws -> URL {
        let folder = inbox.appendingPathComponent("recordings/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SessionMeta(id: UUID(), startedAt: Date(), status: status).write(to: folder)
        return folder
    }

    func testFinishedSessionMovesToHistoryWithItsUsage() throws {
        let folder = try session(named: "finished-one", status: .inserted)
        let record = UsageRecord(activity: .dictation, stage: .transcribe, model: "m", sessionID: "s", usage: TokenUsage(audioIn: 10))
        KeyboardInbox.finish(folder: folder, usage: [record], root: inbox)

        let (sessions, usage) = KeyboardInbox.collect(from: inbox)

        XCTAssertEqual(sessions.map(\.folder.lastPathComponent), ["finished-one"])
        XCTAssertEqual(sessions.first?.folder.deletingLastPathComponent(), FileLayout.recordingsRoot)
        XCTAssertEqual(sessions.first?.meta.status, .inserted)
        XCTAssertEqual(usage.map(\.id), [record.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions[0].folder.appendingPathComponent("usage.json").path))
        XCTAssertTrue(KeyboardInbox.collect(from: inbox).sessions.isEmpty, "imported twice")
    }

    func testUnfinishedSessionWaitsUntilTheKeyboardAbandonedIt() throws {
        _ = try session(named: "in-flight", status: .transcribing)

        XCTAssertTrue(KeyboardInbox.collect(from: inbox, now: Date()).sessions.isEmpty, "taken while the keyboard works on it")
        let later = Date().addingTimeInterval(KeyboardInbox.abandonedAfter + 1)
        let (sessions, _) = KeyboardInbox.collect(from: inbox, now: later)
        XCTAssertEqual(sessions.map(\.meta.status), [.transcribing])
    }
}
