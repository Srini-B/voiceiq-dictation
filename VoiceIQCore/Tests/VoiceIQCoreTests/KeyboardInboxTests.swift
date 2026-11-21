import XCTest
@testable import VoiceIQCore
import VoiceIQBridge

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

    /// A dictation sent to the keyboard's background session stays in the
    /// keyboard's folder until the app takes it over when it opens; then
    /// History gets it.
    func testOfflineJobIsImportedWhenTheAppTakesItOver() throws {
        let folder = try session(named: "offline-one", status: .queuedForRetry)
        try Data("audio".utf8).write(to: FileLayout.audioFLAC(in: folder))
        let job = KeyboardJob(folder: "offline-one", mode: .dictate, durationSeconds: 3)
        try job.write(root: inbox)
        let long = Date().addingTimeInterval(KeyboardInbox.abandonedAfter + 1)

        XCTAssertTrue(KeyboardInbox.collect(from: inbox, now: long).sessions.isEmpty, "taken while its transfer is pending")
        XCTAssertEqual(KeyboardJob.pending(in: inbox).map(\.id), [job.id])

        job.takeOver(root: inbox)

        XCTAssertTrue(KeyboardJob.pending(in: inbox).isEmpty)
        let (sessions, _) = KeyboardInbox.collect(from: inbox)
        XCTAssertEqual(sessions.map(\.meta.status), [.queuedForRetry])
        XCTAssertTrue(FileManager.default.fileExists(atPath: FileLayout.audioFLAC(in: sessions[0].folder).path), "audio needed for the retry")
    }

    func testNeverKeepAudioDropsTheRecordingOnceItHasWords() throws {
        let folder = try session(named: "never-keep", status: .transcribing)
        let audio = [FileLayout.audioCAF(in: folder), FileLayout.audioFLAC(in: folder)]
        for url in audio { try Data("audio".utf8).write(to: url) }
        var meta = SessionMeta(id: UUID(), startedAt: Date(), status: .transcribing)

        RetentionPolicy.dropAudioIfNeverKept(meta, folder: folder, audioRetentionDays: -1)
        XCTAssertTrue(audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "dropped before the words arrived")

        meta.rawTranscript = "hello"
        RetentionPolicy.dropAudioIfNeverKept(meta, folder: folder, audioRetentionDays: 7)
        XCTAssertTrue(audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "dropped while kept for 7 days")

        RetentionPolicy.dropAudioIfNeverKept(meta, folder: folder, audioRetentionDays: -1)
        XCTAssertFalse(audio.contains { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: FileLayout.metaJSON(in: folder).path), "the dictation itself stays")
    }
}

/// The result of a keyboard dictation whose keyboard hid (anomalyco/hex #2163).
final class HeldDictationTests: XCTestCase {
    private let field = UUID()
    private let finished = Date(timeIntervalSince1970: 1_000_000)

    private func held() -> HeldDictation {
        HeldDictation(text: "hi", mode: .dictate, document: field, host: "com.apple.MobileSMS",
                      textBefore: "Dear Sam, ", finishedAt: finished)
    }

    func testSameFieldWithinThirtySecondsIsTyped() {
        XCTAssertEqual(held().delivery(in: field, at: finished.addingTimeInterval(29)), .insert)
        XCTAssertEqual(held().delivery(in: field, at: finished.addingTimeInterval(31)), .offer)
    }

    func testAnotherFieldIsOfferedUntilTenMinutes() {
        XCTAssertEqual(held().delivery(in: UUID(), host: "com.apple.MobileSMS", textBefore: "Other", at: finished.addingTimeInterval(5)), .offer)
        XCTAssertEqual(held().delivery(in: UUID(), at: finished.addingTimeInterval(599)), .offer)
        XCTAssertEqual(held().delivery(in: UUID(), at: finished.addingTimeInterval(601)), .expired)
    }

    /// One result from the keyboard and one from the app: taking either
    /// never brings the other back once it was taken too.
    func testEachHeldResultIsTakenOnce() throws {
        let suite = "held-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: defaults)
        let fromKeyboard = HeldDictation(text: "keyboard", mode: .dictate, document: field, finishedAt: finished)
        let fromApp = HeldDictation(text: "app", mode: .dictate, document: field, finishedAt: finished.addingTimeInterval(5))
        store.heldByKeyboard = fromKeyboard
        store.heldByApp = fromApp

        XCTAssertEqual(store.heldDictation?.text, "app", "the newer one first")
        store.markHeldHandled(fromApp)
        XCTAssertEqual(store.heldDictation?.text, "keyboard")
        store.markHeldHandled(fromKeyboard)
        XCTAssertNil(store.heldDictation, "the app's result came back after the keyboard's was taken")
    }

    /// iOS names the field anew when its app comes back to the front.
    func testRenamedFieldInTheSameAppWithTheSameTextIsTyped() {
        XCTAssertEqual(held().delivery(in: UUID(), host: "com.apple.MobileSMS", textBefore: "Dear Sam, ",
                                       at: finished.addingTimeInterval(10)), .insert)
        XCTAssertEqual(held().delivery(in: UUID(), host: "com.apple.mobilesafari", textBefore: "Dear Sam, ",
                                       at: finished.addingTimeInterval(10)), .offer)
    }
}
