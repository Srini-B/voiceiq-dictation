import AVFoundation
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

    /// The app marks a failed Translate or Ask failed, not queued, for
    /// History's Retry; a taken-over keyboard job matches that.
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

        let first = try XCTUnwrap(job.claim(root: inbox))
        XCTAssertNil(job.claim(root: inbox), "a second finish while the first runs")
        first.release()
        let stale = try XCTUnwrap(job.claim(root: inbox))

        let later = Date().addingTimeInterval(KeyboardJob.claimLifetime + 1)
        XCTAssertNotNil(job.claim(root: inbox, now: later), "a claim left by a process that ended")
        stale.release()
        XCTAssertNil(job.claim(root: inbox), "the stale owner's release leaves the new claim")
    }

    /// An owner that resumes after its claim expired and was taken commits
    /// nothing: the new owner's job and folder stay as they are.
    func testAnExpiredOwnerCannotCommit() throws {
        let folder = try session(named: "expired", status: .queuedForRetry)
        let job = KeyboardJob(folder: "expired", mode: .dictate, durationSeconds: 3)
        try job.write(root: inbox)
        let expired = try XCTUnwrap(job.claim(root: inbox))
        let later = Date().addingTimeInterval(KeyboardJob.claimLifetime + 1)
        let current = try XCTUnwrap(job.claim(root: inbox, now: later))

        XCTAssertFalse(expired.isHeld)
        XCTAssertFalse(job.takeOver(root: inbox, claim: expired))
        XCTAssertFalse(job.remove(root: inbox, claim: expired))
        expired.release()
        XCTAssertEqual(KeyboardJob.pending(in: inbox).map(\.id), [job.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(current.isHeld, "the old owner's release leaves the new claim")

        XCTAssertTrue(job.takeOver(root: inbox, claim: current))
        XCTAssertTrue(KeyboardJob.pending(in: inbox).isEmpty)
    }

    /// Usage that cannot be written keeps the folder where the keyboard can
    /// hand it over again; the app never collects it without its usage.
    func testAFolderWhoseUsageCannotBeWrittenStays() throws {
        let folder = try session(named: "read-only", status: .recovered)
        let usage = [UsageRecord(activity: .dictation, stage: .transcribe, model: "m", sessionID: "s", usage: TokenUsage(audioIn: 10))]
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertFalse(KeyboardInbox.finish(folder: folder, usage: usage, root: inbox))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "not moved to finished")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("finished/read-only").path))

        XCTAssertTrue(KeyboardInbox.finish(folder: folder, usage: usage, root: inbox))
        XCTAssertEqual(KeyboardInbox.collect(from: inbox).usage.count, 1)
    }

    /// Opening the app takes over only jobs nobody else is sending: not one
    /// the keyboard is still starting (it holds the claim), not one whose
    /// upload runs. The claim is held while the tasks are read.
    /// A folder that could not be moved to `finished` is not reported as
    /// handed over: it stays where the next hand-over finds it.
    func testAFolderThatCannotMoveStaysRetryable() throws {
        let folder = try session(named: "stuck", status: .recorded)
        let finished = inbox.appendingPathComponent("finished", isDirectory: true)
        try FileManager.default.createDirectory(at: finished, withIntermediateDirectories: true)
        try Data().write(to: finished.appendingPathComponent("stuck"))

        XCTAssertFalse(KeyboardInbox.finish(folder: folder, usage: [], root: inbox))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        try FileManager.default.removeItem(at: finished.appendingPathComponent("stuck"))
        XCTAssertTrue(KeyboardInbox.finish(folder: folder, usage: [], root: inbox))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// A folder that cannot move into the app's recordings keeps its usage
    /// for the collection that moves it.
    func testUsageStaysWithAFolderThatCannotMove() throws {
        let folder = try session(named: "blocked", status: .inserted)
        let record = UsageRecord(activity: .dictation, stage: .transcribe, model: "m", sessionID: "s", usage: TokenUsage(audioIn: 10))
        XCTAssertTrue(KeyboardInbox.finish(folder: folder, usage: [record], root: inbox))
        try FileManager.default.createDirectory(at: FileLayout.recordingsRoot, withIntermediateDirectories: true)
        let blocker = FileLayout.recordingsRoot.appendingPathComponent("blocked")
        try Data().write(to: blocker)

        let first = KeyboardInbox.collect(from: inbox)
        XCTAssertTrue(first.sessions.isEmpty)
        XCTAssertTrue(first.usage.isEmpty, "usage taken without its dictation")

        try FileManager.default.removeItem(at: blocker)
        let second = KeyboardInbox.collect(from: inbox)
        XCTAssertEqual(second.sessions.map(\.folder.lastPathComponent), ["blocked"])
        XCTAssertEqual(second.usage.map(\.id), [record.id])
    }

    /// A job whose JSON cannot be deleted is still pending: it keeps its
    /// answer, and the caller is told to try again.
    func testAJobThatCannotBeRemovedKeepsItsFiles() throws {
        let job = KeyboardJob(folder: "stuck-job", mode: .dictate, durationSeconds: 3)
        try job.write(root: inbox)
        let response = try XCTUnwrap(KeyboardJob.responseURL(job.id, root: inbox))
        try Data("answer".utf8).write(to: response)
        let jobs = response.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: jobs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jobs.path) }

        XCTAssertFalse(job.remove(root: inbox))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jobs.path)
        XCTAssertEqual(KeyboardJob.pending(in: inbox).map(\.id), [job.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: response.path))
        XCTAssertTrue(job.remove(root: inbox))
        XCTAssertTrue(KeyboardJob.pending(in: inbox).isEmpty)
    }

    /// A takeover whose folder cannot move keeps the job, released for the
    /// next attempt.
    func testATakeOverWhoseFolderCannotMoveKeepsTheJob() throws {
        let folder = try session(named: "no-room", status: .queuedForRetry)
        let job = KeyboardJob(folder: "no-room", mode: .dictate, durationSeconds: 3)
        try job.write(root: inbox)
        let finished = inbox.appendingPathComponent("finished", isDirectory: true)
        try FileManager.default.createDirectory(at: finished, withIntermediateDirectories: true)
        try Data().write(to: finished.appendingPathComponent("no-room"))
        let claim = try XCTUnwrap(job.claim(root: inbox))

        XCTAssertFalse(job.takeOver(root: inbox, claim: claim))
        XCTAssertEqual(KeyboardJob.pending(in: inbox).map(\.id), [job.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        let next = try XCTUnwrap(job.claim(root: inbox), "the claim was released")

        try FileManager.default.removeItem(at: finished.appendingPathComponent("no-room"))
        XCTAssertTrue(job.takeOver(root: inbox, claim: next))
        XCTAssertTrue(KeyboardJob.pending(in: inbox).isEmpty)
    }

    func testTheAppTakesOverOnlyJobsWithNoUpload() async throws {
        let starting = KeyboardJob(folder: "starting", mode: .dictate, durationSeconds: 3)
        let uploading = KeyboardJob(folder: "uploading", mode: .dictate, durationSeconds: 3)
        let idle = KeyboardJob(folder: "idle", mode: .dictate, durationSeconds: 3)
        for job in [starting, uploading, idle] { try job.write(root: inbox) }
        let keyboard = try XCTUnwrap(starting.claim(root: inbox))

        let root = inbox!
        let taken = await KeyboardJob.takeOverIdle([starting, uploading, idle], root: root) {
            XCTAssertNil(idle.claim(root: root), "claimed before the tasks are read")
            return [uploading.id]
        }

        XCTAssertEqual(taken.map(\.id), [idle.id])
        XCTAssertEqual(Set(KeyboardJob.pending(in: inbox).map(\.id)), [starting.id, uploading.id])
        XCTAssertNotNil(uploading.claim(root: inbox), "a job left waiting is released")
        keyboard.release()
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

    /// A job sent to one provider and answered after the user switched to
    /// the other is read as the first provider's answer.
    /// Only a client that opts in keeps the request it sent, recording and
    /// all: the app's long-lived clients never hold one.
    func testOnlyAnOptedInClientKeepsTheRequestItSent() async {
        let closed = URL(string: "http://127.0.0.1:9")!
        for keeps in [false, true] {
            let client = GeminiClient(apiKey: { "key" }, keepsSentTranscription: keeps)
            _ = try? await client.transcribeInteraction(audio: Data(count: 4_000), model: "m", endpoint: closed,
                                                        mode: .verbatim, customVocabulary: [], deadline: 2)
            XCTAssertEqual(client.sentTranscription != nil, keeps)
            client.forgetSentTranscription()
            XCTAssertNil(client.sentTranscription)
        }
    }

    func testTheAnswerIsReadAsTheProviderTheJobWentTo() async throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let answers: [(ModelEndpoint, ModelProvider, String)] = [
            (.openAI, .gemini, #"{"text":"sent to OpenAI"}"#),
            (.gemini, .openAI, #"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"sent to Gemini"}]}]}"#),
        ]
        for (sentTo, nowSelected, body) in answers {
            try KeyboardJob(folder: "f", mode: .dictate, durationSeconds: 3, transcriber: sentTo).write(root: inbox)
            let job = try XCTUnwrap(KeyboardJob.pending(in: inbox).last)
            XCTAssertEqual(job.transcriber, sentTo)
            let client = GeminiClient(apiKey: { "key" }, openAIKey: { "key" }, provider: { nowSelected })
            let replay = ReplayedResponse(body: Data(body.utf8), status: 200, endpoint: job.transcriber)
            let text = try await GeminiClient.$replayedTranscription.withValue(replay) {
                try await client.transcribeInteraction(audio: Data(), model: "m", endpoint: url, mode: .verbatim,
                                                       customVocabulary: [], deadline: 5)
            }
            XCTAssertEqual(text, "sent to \(sentTo == .openAI ? "OpenAI" : "Gemini")")
            job.remove(root: inbox)
        }
    }

    /// History names the transcriber that answered a replayed job, and the
    /// writing model still follows Settings.
    func testAReplayedJobIsNamedForItsTranscriber() async {
        let settings = SettingsStore()
        let previous = settings.preferredProvider
        settings.setPreferredProvider(.gemini)
        defer { settings.setPreferredProvider(previous) }
        let service = GeminiTranscriptionService(client: GeminiClient(apiKey: { "key" }), settings: settings)
        let replay = ReplayedResponse(body: Data(), status: 200, endpoint: .openAI)
        let (transcriber, elevenLabs) = GeminiClient.$replayedTranscription.withValue(replay) { service.transcriberInUse() }
        XCTAssertEqual(transcriber, .openAI)
        XCTAssertFalse(elevenLabs)
        let names = service.modelNames(transcriber: transcriber, writer: settings.preferredProvider, elevenLabs: elevenLabs)
        XCTAssertEqual(names.transcribe, settings.openAIConfig.transcribeModel)
        XCTAssertEqual(names.writing, settings.geminiConfig.cleanupModel)
        XCTAssertTrue(service.transcriptKeepsFillers(provider: transcriber, elevenLabs: false, policy: settings.formattingPolicy))
    }
}

extension ReplayedResponseTests {
    /// A captured request carries the transcription model and filler mode it
    /// was sent with; its replay is read with those, whatever Settings says
    /// by then, and the writing model still follows Settings.
    func testAReplayIsReadAsItWasSent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("audio.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let tone = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        tone.frameLength = 16_000
        for frame in 0..<16_000 { tone.floatChannelData![0][frame] = 0.5 * sin(Float(frame) * 2 * .pi * 440 / 16_000) }
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: tone)

        let settings = SettingsStore()
        let service = GeminiTranscriptionService(client: GeminiClient(apiKey: { "key" }, openAIKey: { "key" },
                                                                   provider: { settings.preferredProvider },
                                                                   elevenLabsKey: { "key" }), settings: settings)
        var captured: CapturedTranscriptionRequest?
        do {
            _ = try await GeminiClient.$capturesTranscription.withValue(true) {
                try await service.transcribe(audioURL: audio, durationSeconds: 1, context: DictationContext(mode: .dictate))
            }
        } catch let request as CapturedTranscriptionRequest {
            captured = request
        }
        let (transcriber, elevenLabs) = service.transcriberInUse()
        let now = service.modelNames(transcriber: transcriber, writer: settings.preferredProvider, elevenLabs: elevenLabs)
        let keepsFillers = service.transcriptKeepsFillers(provider: transcriber, elevenLabs: elevenLabs, policy: settings.formattingPolicy)
        XCTAssertEqual(captured?.model, now.transcribe)
        XCTAssertEqual(captured?.keepsFillers, keepsFillers)

        let replay = ReplayedResponse(body: Data(), status: 200, transcribeModel: "sent-model/verbatim", keepsFillers: !keepsFillers)
        GeminiClient.$replayedTranscription.withValue(replay) {
            let names = service.modelNames(transcriber: transcriber, writer: settings.preferredProvider, elevenLabs: elevenLabs)
            XCTAssertEqual(names.transcribe, "sent-model/verbatim")
            XCTAssertEqual(names.writing, now.writing)
            XCTAssertEqual(service.transcriptKeepsFillers(provider: transcriber, elevenLabs: elevenLabs,
                                                          policy: settings.formattingPolicy), !keepsFillers)
        }
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

    /// A held result the keyboard typed or pasted is what Paste last pastes;
    /// an Ask answer is not.
    func testATakenHeldResultIsTheLastDelivery() throws {
        let suite = "held-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: defaults)
        store.keyboardDelivery = Delivery(mode: .dictate, text: "older", createdAt: finished, hostBundleID: nil)

        let translated = HeldDictation(text: "hola", mode: .translate, document: field, finishedAt: finished)
        store.heldByApp = translated
        store.markHeldHandled(translated)
        XCTAssertEqual(store.keyboardDelivery?.text, "hola")
        XCTAssertEqual(store.keyboardDelivery?.mode, .translate)

        let answer = HeldDictation(text: "an answer", mode: .ask, document: field, finishedAt: finished)
        store.heldByKeyboard = answer
        store.markHeldHandled(answer)
        XCTAssertEqual(store.keyboardDelivery?.text, "hola")
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
