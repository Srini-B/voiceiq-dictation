import AVFoundation
import VoiceIQBridge
@testable import VoiceIQCore
import XCTest

/// Finishing a keyboard dictation from the answer its background transfer left.
final class KeyboardTransfersTests: XCTestCase {
    /// iOS's completion handler runs whether the session's events finish
    /// before or after the app registers it.
    func testTheCompletionHandlerRunsInEitherOrder() {
        for eventsFirst in [true, false] {
            let transfers = KeyboardTransfers(root: nil) { _ in }
            let called = expectation(description: "completion")
            if eventsFirst { transfers.urlSessionDidFinishEvents(forBackgroundURLSession: .shared) }
            transfers.setEventsDone { called.fulfill() }
            if !eventsFirst { transfers.urlSessionDidFinishEvents(forBackgroundURLSession: .shared) }
            wait(for: [called], timeout: 2)
        }
    }

    /// A 200 whose body was cut off waits for a retry instead of failing.
    @MainActor
    func testAnInterruptedSuccessfulAnswerWaitsForARetry() async throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let job = KeyboardJob(folder: "cut-off", mode: .dictate, durationSeconds: 3)
        let folder = try XCTUnwrap(job.folderURL(root: inbox))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SessionMeta(id: job.id, startedAt: Date(), status: .transcribing).write(to: folder)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        silence.frameLength = 1_600
        try AVAudioFile(forWriting: FileLayout.audioCAF(in: folder), settings: format.settings).write(from: silence)
        try job.write(root: inbox)
        try Data(#"{"te"#.utf8).write(to: XCTUnwrap(KeyboardJob.responseURL(job.id, root: inbox)))
        KeyboardJob.record(KeyboardJob.Answer(status: 200, error: "The network connection was lost."), for: job.id, root: inbox)
        let client = GeminiClient(apiKey: { "key" }, openAIKey: { "key" }, provider: { .gemini })

        let (outcome, claim) = await KeyboardTransfers.finish(job, service: GeminiTranscriptionService(client: client), root: inbox)
        claim?.release()

        guard case .waiting = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNotEqual(SessionMeta.read(from: folder)?.status, .failed)
    }

    /// An answer that could not be written in full is no answer: the job
    /// waits for the app's retry, as a cut-off one does.
    func testAnAnswerThatCannotBeSavedIsNoAnswer() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let job = KeyboardJob(folder: "unsaved", mode: .dictate, durationSeconds: 3)
        try job.write(root: inbox)
        // A directory where the answer goes: every write to it fails.
        try FileManager.default.createDirectory(at: XCTUnwrap(KeyboardJob.responseURL(job.id, root: inbox)),
                                                withIntermediateDirectories: true)
        let transfers = KeyboardTransfers(root: inbox) { _ in }
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.com")!)
        task.taskDescription = job.id.uuidString

        transfers.urlSession(.shared, dataTask: task, didReceive: Data(#"{"text":"hi"}"#.utf8))
        transfers.urlSession(.shared, task: task, didCompleteWithError: nil)

        XCTAssertNotNil(job.answer(root: inbox)?.error)
    }

    /// A replayed job whose words meta.json cannot take stays pending, with
    /// its saved answer and its audio, even set never to keep audio; the next
    /// try replays that answer and names the model it was sent to.
    @MainActor
    func testAReplayKeepsItsModelAndItsAudioUntilTheWordsAreSaved() async throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let defaults = UserDefaults.standard
        let kept = ["audioRetentionDays", "skipShortDictationCleanup"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in kept { defaults.set(value, forKey: key) } }
        SettingsStore().setAudioRetentionDays(-1)
        SettingsStore().setSkipShortDictationCleanup(true)

        var job = KeyboardJob(folder: "never-keep", mode: .dictate, durationSeconds: 1, transcriber: .gemini)
        job.transcribeModel = "sent-model/verbatim"
        let folder = try XCTUnwrap(job.folderURL(root: inbox))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let tone = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        tone.frameLength = 16_000
        for frame in 0..<16_000 { tone.floatChannelData![0][frame] = 0.5 * sin(Float(frame) * 2 * .pi * 440 / 16_000) }
        try AVAudioFile(forWriting: FileLayout.audioCAF(in: folder), settings: format.settings).write(from: tone)
        // A directory where meta.json goes: writing it fails.
        try FileManager.default.createDirectory(at: FileLayout.metaJSON(in: folder), withIntermediateDirectories: true)
        try job.write(root: inbox)
        let body = #"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"hello there"}]}]}"#
        try Data(body.utf8).write(to: XCTUnwrap(KeyboardJob.responseURL(job.id, root: inbox)))
        KeyboardJob.record(KeyboardJob.Answer(status: 200, error: nil), for: job.id, root: inbox)
        let client = GeminiClient(apiKey: { "key" }, openAIKey: { "key" }, provider: { .gemini })

        let service = GeminiTranscriptionService(client: client)

        let (failed, held) = await KeyboardTransfers.finish(job, service: service, root: inbox)
        guard case .busy = failed else { return XCTFail("finished without its words saved: \(failed)") }
        XCTAssertNil(held)
        XCTAssertNotNil(KeyboardJob.read(job.id, root: inbox), "job dropped")
        XCTAssertNotNil(job.answer(root: inbox), "saved answer dropped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: FileLayout.audioCAF(in: folder).path), "audio dropped before its words were saved")

        // The disk recovers: the next import replays the saved answer.
        try FileManager.default.removeItem(at: FileLayout.metaJSON(in: folder))
        let (outcome, claim) = await KeyboardTransfers.finish(job, service: service, root: inbox)
        claim?.release()
        guard case .finished(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.modelID, "sent-model/verbatim")
        XCTAssertEqual(SessionMeta.read(from: folder)?.rawTranscript, "hello there")
    }
}
