import AVFoundation
import XCTest
@testable import VoiceIQCore

/// The request sent at a pause is used only for the speech key-up would send:
/// the range found in the recording so far must equal the range
/// `AudioChunker` trims from the finished file, and must differ once more
/// speech follows.
final class SendOnPauseTests: XCTestCase {
    private func tone(_ seconds: Double, amplitude: Double = 8_000) -> [Int16] {
        (0..<Int(seconds * 16_000)).map { Int16(amplitude * sin(Double($0) * 2 * .pi * 220 / 16_000)) }
    }

    private func silence(_ seconds: Double) -> [Int16] { Array(repeating: 0, count: Int(seconds * 16_000)) }

    private func recorded(_ samples: [Int16]) -> RecordedSpeech {
        var speech = RecordedSpeech()
        // Uneven buffers, as the engine writes them.
        var offset = 0
        while offset < samples.count {
            let count = min(1_377, samples.count - offset)
            samples[offset..<(offset + count)].withUnsafeBufferPointer { speech.append($0) }
            offset += count
        }
        return speech
    }

    private func keyUpRange(_ samples: [Int16]) throws -> Range<AVAudioFramePosition> {
        let url = try caf(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        let (ranges, _) = try AudioChunker.ranges(cafURL: url)
        return try XCTUnwrap(ranges.first)
    }

    private func caf(_ samples: [Int16]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pause-\(UUID()).caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
        return url
    }

    func testSilenceShorterThanThePauseSendsNothing() {
        let speech = recorded(silence(0.5) + tone(2) + silence(0.6))
        XCTAssertNil(speech.pausedSpeech(after: 0.8, minimumSpeech: 1))
    }

    func testPausedRangeIsWhatKeyUpSendsWhenNoSpeechFollows() throws {
        let spoken = silence(0.5) + tone(1.2) + silence(0.3) + tone(0.4, amplitude: 3_000)
        let speech = recorded(spoken + silence(0.9))
        let paused = try XCTUnwrap(speech.pausedSpeech(after: 0.8, minimumSpeech: 1))
        XCTAssertEqual(paused, try keyUpRange(spoken + silence(2.5)))
        XCTAssertEqual(speech.samples(in: paused), Array((spoken + silence(0.9))[Int(paused.lowerBound)..<Int(paused.upperBound)]))
    }

    func testSpeechAfterThePauseChangesTheRange() throws {
        let spoken = silence(0.5) + tone(1.2)
        let paused = try XCTUnwrap(recorded(spoken + silence(0.9)).pausedSpeech(after: 0.8, minimumSpeech: 1))
        XCTAssertNotEqual(paused, try keyUpRange(spoken + silence(0.9) + tone(0.5) + silence(1)))
    }

    /// The service answers from the early request when it covers the speech
    /// key-up sends, and drops it otherwise. Without a key every request it
    /// sends itself fails, so an answer proves the early one was used.
    func testTheServiceUsesTheEarlyAnswerOnlyForTheSameSpeech() async throws {
        let service = GeminiTranscriptionService(client: GeminiClient(apiKey: { nil }))
        let context = DictationContext()
        let spoken = silence(0.5) + tone(1.2)
        let paused = try XCTUnwrap(recorded(spoken + silence(0.9)).pausedSpeech(after: 0.8, minimumSpeech: 1))
        func early() -> SpeculativeDictation {
            SpeculativeDictation(range: paused, prompt: service.dictationPrompt(context: context),
                                 sentAt: ContinuousClock().now) { _ in "Sent at the pause." }
        }

        let same = try caf(spoken + silence(2))
        defer { try? FileManager.default.removeItem(at: same) }
        let result = try await service.transcribe(audioURL: same, durationSeconds: 3.7, context: context,
                                                  speculation: early())
        XCTAssertEqual(result.rawTranscript, "Sent at the pause.")

        let more = try caf(spoken + silence(0.9) + tone(0.5) + silence(1))
        defer { try? FileManager.default.removeItem(at: more) }
        let dropped = early()
        do {
            _ = try await service.transcribe(audioURL: more, durationSeconds: 4.1, context: context, speculation: dropped)
            XCTFail("speech after the pause must not take the early answer")
        } catch {
            XCTAssertTrue(dropped.answer.isCancelled)
        }
    }

    /// Gemini bills a stream from its first chunk, so a request cancelled
    /// after part of its answer arrived counts as billed, and one cancelled
    /// before does not.
    func testAnEarlyRequestIsBilledOnceItsAnswerStartsToArrive() async {
        func early(streaming: Bool) -> SpeculativeDictation {
            SpeculativeDictation(range: 0..<1, prompt: "p", sentAt: ContinuousClock().now) { onFirstChunk in
                if streaming { onFirstChunk() }
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return "never"
            }
        }
        let waiting = early(streaming: false)
        let streaming = early(streaming: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        waiting.cancel()
        streaming.cancel()
        _ = await waiting.answer.result
        _ = await streaming.answer.result
        XCTAssertFalse(waiting.isBilled)
        XCTAssertTrue(streaming.isBilled)
        XCTAssertNil(streaming.answeredAt)
    }

    func testAPauseAfterTooLittleSpeechSendsNothing() {
        XCTAssertNil(recorded(silence(0.5) + tone(0.6) + silence(1.5)).pausedSpeech(after: 0.8, minimumSpeech: 1))
    }

    func testARecordingPastTheCapIsNeverSentEarly() {
        let speech = recorded(tone(RecordedSpeech.maxSeconds) + silence(1))
        XCTAssertNil(speech.pausedSpeech(after: 0.8, minimumSpeech: 1))
    }
}
