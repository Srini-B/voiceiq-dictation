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
        let imported = try XCTUnwrap(sessions.first)
        XCTAssertEqual(imported.folder.deletingLastPathComponent(), FileLayout.recordingsRoot)
        XCTAssertEqual(sessions.first?.meta.status, .inserted)
        XCTAssertEqual(usage.map(\.id), [record.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.folder.appendingPathComponent("usage.json").path))
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
        let imported = try XCTUnwrap(sessions.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: FileLayout.audioFLAC(in: imported.folder).path), "audio needed for the retry")
    }

    /// The app's retry queue transcribes as Dictate and the app marks a
    /// failed Translate or Ask failed, not queued; a taken-over keyboard
    /// job matches that instead of coming back as a plain dictation.
    func testTakenOverTranslateJobIsFailedNotQueuedAsDictation() throws {
        _ = try session(named: "translate-one", status: .queuedForRetry)
        let job = KeyboardJob(folder: "translate-one", mode: .translate, translationTargets: ["es"], durationSeconds: 3)
        try job.write(root: inbox)

        job.takeOver(root: inbox)

        let (sessions, _) = KeyboardInbox.collect(from: inbox)
        XCTAssertEqual(sessions.map(\.meta.status), [.failed])
        XCTAssertEqual(sessions.first?.meta.errorCode, "mode_transform")
    }

    /// The app and the keyboard can both hold a job's answer: one finishes it.
    func testOneClaimPerJobAcrossProcesses() throws {
        let job = KeyboardJob(folder: "claimed", mode: .dictate, durationSeconds: 3)
        try job.write(root: inbox)

        XCTAssertTrue(job.claim(root: inbox))
        XCTAssertFalse(job.claim(root: inbox), "a second finish while the first runs")
        job.releaseClaim(root: inbox)
        XCTAssertTrue(job.claim(root: inbox))

        let later = Date().addingTimeInterval(KeyboardJob.claimLifetime + 1)
        XCTAssertTrue(job.claim(root: inbox, now: later), "a claim left by a process that ended")
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

/// The background session's answer, replayed through the normal service.
final class ReplayedResponseTests: XCTestCase {
    private let url = URL(string: "https://example.com/transcribe")!

    func testOnlyASuccessfulAnswerCountsAsTranscribed() {
        let refused = ReplayedResponse(body: Data(), status: 429)
        XCTAssertNotNil(refused.take(url: url))
        XCTAssertFalse(refused.transcribed, "a quota refusal must stay queued for the retry")

        let answered = ReplayedResponse(body: Data(), status: 200)
        XCTAssertFalse(answered.transcribed, "not used yet")
        XCTAssertNotNil(answered.take(url: url))
        XCTAssertTrue(answered.transcribed)
        XCTAssertNil(answered.take(url: url), "handed out once")
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

        // Many later keyboard results, each taken, never bring the app's back.
        for index in 0..<10 {
            let later = HeldDictation(text: "later \(index)", mode: .dictate, document: field,
                                      finishedAt: finished.addingTimeInterval(Double(10 + index)))
            store.heldByKeyboard = later
            store.markHeldHandled(later)
        }
        XCTAssertNil(store.heldDictation)
    }

    /// A field either side could not name is never typed into by itself.
    func testUnnamedFieldIsOfferedUnlessTheAppAndTextMatch() {
        let unnamed = HeldDictation(text: "hi", mode: .dictate, document: nil, host: "com.apple.MobileSMS",
                                    textBefore: "Dear Sam, ", finishedAt: finished)
        XCTAssertEqual(unnamed.delivery(in: field, host: "com.apple.mobilesafari", textBefore: "Dear Sam, ",
                                        at: finished.addingTimeInterval(5)), .offer, "another app")
        XCTAssertEqual(held().delivery(in: nil, host: "com.apple.mobilesafari", at: finished.addingTimeInterval(5)), .offer)
        XCTAssertEqual(unnamed.delivery(in: nil, host: "com.apple.MobileSMS", textBefore: "Dear Sam, ",
                                        at: finished.addingTimeInterval(5)), .insert)
    }

    /// Empty text before the cursor does not tell two empty fields apart.
    func testEmptyFieldsInTheSameAppAreOffered() {
        let empty = HeldDictation(text: "hi", mode: .dictate, document: field, host: "com.apple.MobileSMS",
                                  textBefore: "", finishedAt: finished)
        XCTAssertEqual(empty.delivery(in: UUID(), host: "com.apple.MobileSMS", textBefore: "",
                                      at: finished.addingTimeInterval(5)), .offer)
        XCTAssertEqual(empty.delivery(in: field, host: "com.apple.MobileSMS", textBefore: "",
                                      at: finished.addingTimeInterval(5)), .insert, "same named field")
    }

    /// iOS names the field anew when its app comes back to the front.
    func testRenamedFieldInTheSameAppWithTheSameTextIsTyped() {
        XCTAssertEqual(held().delivery(in: UUID(), host: "com.apple.MobileSMS", textBefore: "Dear Sam, ",
                                       at: finished.addingTimeInterval(10)), .insert)
        XCTAssertEqual(held().delivery(in: UUID(), host: "com.apple.mobilesafari", textBefore: "Dear Sam, ",
                                       at: finished.addingTimeInterval(10)), .offer)
    }
}
