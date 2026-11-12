import XCTest
@testable import VoiceIQCore

/// Recovered dictations: the queue hands the app their text (so it can copy
/// it), the History row is still written, and the pill names where the text is.
@MainActor
final class RecoveryClipboardTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryClipboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: "copyRecoveredToClipboard")
    }

    /// Transcribes each recording to the text written next to its audio.
    private struct FolderTranscription: TranscriptionServicing {
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
            let text = try String(contentsOf: audioURL.deletingLastPathComponent().appendingPathComponent("expected.txt"), encoding: .utf8)
            return TranscriptionResult(rawTranscript: "um " + text, cleanedTranscript: text, modelID: "fake")
        }
    }

    private struct OfflineTranscription: TranscriptionServicing {
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
            throw TranscriptionError.offline
        }
    }

    @discardableResult
    private func queuedSession(_ text: String, secondsAgo: TimeInterval, rawTranscript: String? = nil) throws -> SessionMeta {
        var meta = SessionMeta(id: UUID(), startedAt: Date().addingTimeInterval(-secondsAgo), status: .queuedForRetry)
        meta.errorCode = "offline"
        meta.audioDurationSeconds = 3
        meta.rawTranscript = rawTranscript
        let folder = root.appendingPathComponent(meta.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0]).write(to: FileLayout.audioCAF(in: folder))
        try text.write(to: folder.appendingPathComponent("expected.txt"), atomically: true, encoding: .utf8)
        meta.write(to: folder)
        store.upsert(meta: meta, folder: folder)
        return meta
    }

    func testDrainHandsOverRecoveredTextOldestFirstAndKeepsHistory() async throws {
        let older = try queuedSession("First one.", secondsAgo: 60)
        let newer = try queuedSession("Second one.", secondsAgo: 10)
        let queue = RetryQueue(store: store, transcription: FolderTranscription())
        var delivered: [[String]] = []
        queue.onDrained = { delivered.append($0) }

        await queue.drain()

        XCTAssertEqual(delivered, [["First one.", "Second one."]])
        for (meta, text) in [(older, "First one."), (newer, "Second one.")] {
            let record = try XCTUnwrap(store.record(id: meta.id.uuidString))
            XCTAssertEqual(record.status, SessionMeta.Status.recovered.rawValue)
            XCTAssertEqual(record.cleanedTranscript, text)
        }
    }

    func testDrainHandsOverTextThatWasAlreadyTranscribed() async throws {
        try queuedSession("unused", secondsAgo: 5, rawTranscript: "Saved before the crash.")
        let queue = RetryQueue(store: store, transcription: OfflineTranscription())
        var delivered: [String] = []
        queue.onDrained = { delivered = $0 }

        await queue.drain()

        XCTAssertEqual(delivered, ["Saved before the crash."])
    }

    func testOfflineDrainHandsOverNothing() async throws {
        let meta = try queuedSession("Never reached.", secondsAgo: 5)
        let queue = RetryQueue(store: store, transcription: OfflineTranscription())
        var called = false
        queue.onDrained = { _ in called = true }

        await queue.drain()

        XCTAssertFalse(called)
        XCTAssertEqual(store.record(id: meta.id.uuidString)?.status, SessionMeta.Status.queuedForRetry.rawValue)
    }

    func testManualRetryReturnsTheNewText() async throws {
        let meta = try queuedSession("Retried text.", secondsAgo: 5)
        let queue = RetryQueue(store: store, transcription: FolderTranscription())
        let record = try XCTUnwrap(store.record(id: meta.id.uuidString))

        guard case .recovered(let text) = await queue.retrySingle(record) else {
            return XCTFail("expected a recovered outcome")
        }
        XCTAssertEqual(text, "Retried text.")
        XCTAssertEqual(store.record(id: meta.id.uuidString)?.cleanedTranscript, "Retried text.")
    }

    /// Retry is offered only when it can do something: a recording to
    /// transcribe again, or the words of an unfinished dictation. A finished
    /// one whose audio is gone would only fail.
    func testRetryIsOfferedOnlyWithSomethingToRetry() throws {
        func offered(_ meta: SessionMeta) throws -> Bool {
            RetryQueue.canRetry(try XCTUnwrap(store.record(id: meta.id.uuidString)))
        }
        func dropAudio(_ meta: SessionMeta) throws {
            try FileManager.default.removeItem(at: FileLayout.audioCAF(in: root.appendingPathComponent(meta.id.uuidString)))
        }
        let withAudio = try queuedSession("a", secondsAgo: 5)
        XCTAssertTrue(try offered(withAudio))

        var finished = try queuedSession("b", secondsAgo: 4, rawTranscript: "b")
        finished.status = .inserted
        let folder = root.appendingPathComponent(finished.id.uuidString, isDirectory: true)
        finished.write(to: folder); store.upsert(meta: finished, folder: folder)
        try dropAudio(finished)
        XCTAssertFalse(try offered(finished))

        let unfinished = try queuedSession("c", secondsAgo: 3, rawTranscript: "c")
        try dropAudio(unfinished)
        XCTAssertTrue(try offered(unfinished))

        let nothing = try queuedSession("d", secondsAgo: 2)
        try dropAudio(nothing)
        XCTAssertFalse(try offered(nothing))
    }

    func testPillNamesTheClipboardOnlyWhenCopied() {
        XCTAssertEqual(RecoveryNotice.message(for: .queue(count: 1), copied: true),
                       "Your queued dictation is ready — copied to the clipboard")
        XCTAssertEqual(RecoveryNotice.message(for: .queue(count: 1), copied: false),
                       "Your queued dictation is ready — it's in History")
        XCTAssertEqual(RecoveryNotice.message(for: .queue(count: 3), copied: true),
                       "3 queued dictations are ready — copied to the clipboard")
        XCTAssertEqual(RecoveryNotice.message(for: .queue(count: 3), copied: false),
                       "3 queued dictations are ready — they're in History")
        XCTAssertEqual(RecoveryNotice.message(for: .retry, copied: true),
                       "Transcribed again — copied to the clipboard")
        XCTAssertEqual(RecoveryNotice.message(for: .retry, copied: false),
                       "Transcribed again — the new text is in History")
        XCTAssertEqual(RecoveryNotice.message(for: .relaunch, copied: true),
                       "Recovered your last dictation — copied to the clipboard")
        XCTAssertEqual(RecoveryNotice.message(for: .relaunch, copied: false),
                       "Recovered your last dictation — it's in History")
    }

    func testClipboardTextKeepsOrderAndSkipsEmpty() {
        XCTAssertEqual(RecoveryNotice.clipboardText([" First. ", "", "Second.\n"]), "First.\n\nSecond.")
        XCTAssertNil(RecoveryNotice.clipboardText(["", "  \n"]))
        XCTAssertNil(RecoveryNotice.clipboardText([]))
    }

    func testCopySettingIsOnByDefaultAndKeepsAnExplicitOff() {
        let settings = SettingsStore()
        UserDefaults.standard.removeObject(forKey: "copyRecoveredToClipboard")
        XCTAssertTrue(settings.copyRecoveredToClipboard, "no stored choice means the default, On")

        let posted = expectation(description: "setting change posted")
        let observer = NotificationCenter.default.addObserver(forName: .gtSettingDidChange, object: nil, queue: nil) { note in
            if note.object as? String == "copyRecoveredToClipboard" { posted.fulfill() }
        }
        settings.setCopyRecoveredToClipboard(false)
        wait(for: [posted], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
        XCTAssertFalse(settings.copyRecoveredToClipboard, "an explicit Off is kept")
    }
}
