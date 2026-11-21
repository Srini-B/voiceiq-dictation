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
}
