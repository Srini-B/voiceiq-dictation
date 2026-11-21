import AVFAudio
import VoiceIQCore
import XCTest

/// The in-keyboard microphone, driven with the page's messages instead of a
/// real capture.
@MainActor
final class WebMicCaptureTests: XCTestCase {
    private func samples(_ count: Int) -> String {
        Data(repeating: 1, count: count * 2).base64EncodedString()
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
    }

    /// A capture started while the last one's stop() still drains keeps its
    /// own file and audio; the old stop() gets the old capture's result, and
    /// the old capture's late chunks are dropped.
    func testAStopStillDrainingNeverFinishesTheNextCapture() async throws {
        let mic = WebMicCapture()
        var scripts: [String] = []
        mic.runScript = { scripts.append($0) }
        mic.handle(["type": "ready"])

        let first = file(), second = file()
        try mic.start(writingTo: first)
        mic.handle(["type": "audio", "data": samples(1_600), "rms": 0.1, "id": 1])
        let firstStop = Task { await mic.stop() }
        await Task.yield()

        try mic.start(writingTo: second)
        mic.handle(["type": "audio", "data": samples(800), "rms": 0.1, "id": 1])
        mic.handle(["type": "audio", "data": samples(3_200), "rms": 0.1, "id": 2])

        let firstResult = await firstStop.value
        XCTAssertEqual(firstResult.framesWritten, 1_600)

        // The second capture is still recording after the first stop() ended.
        mic.handle(["type": "audio", "data": samples(1_600), "rms": 0.1, "id": 2])
        let secondResult = await mic.stop()
        XCTAssertEqual(secondResult.framesWritten, 4_800)
        XCTAssertEqual(try AVAudioFile(forReading: second).length, 4_800)
        XCTAssertTrue(scripts.contains("startCapture(2); 0"))
    }
}
