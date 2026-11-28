import AVFoundation
import XCTest
@testable import VoiceIQCore

/// The meeting playback bar's controls: play from where you seeked, pause and
/// resume in place, seek while paused, and stop back to the start.
@MainActor
final class RecordingPlayerTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let writer = try CAFWriter(url: FileLayout.audioCAF(in: folder), format: format)
        defer { writer.close() }
        let frames = AVAudioFrameCount(4 * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.int16ChannelData![0][index] = Int16(4_000 * sin(2 * .pi * 440 * Double(index) / 16_000))
        }
        try writer.write(buffer)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSeekBeforePlayIsKeptAndStopGoesBackToTheStart() {
        let player = RecordingPlayer()
        player.seek(to: -3)
        XCTAssertEqual(player.position, 0)
        player.seek(to: 2.5)
        XCTAssertEqual(player.position, 2.5)
        XCTAssertNil(player.duration)
        player.stop()
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.state, .idle)
    }

    func testPauseHoldsThePlaceAndPlayResumesFromIt() async throws {
        let player = RecordingPlayer()
        let audio = RecordedAudio.dictation(folder: folder, startedAt: Date())
        player.seek(to: 1)
        player.playPause(audio)
        try await started(player)
        XCTAssertEqual(player.duration ?? 0, 4, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(player.position, 0.95, "starts where the seek parked it")

        player.playPause(audio)
        XCTAssertEqual(player.state, .paused)
        let held = player.position
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(player.position, held, accuracy: 0.01, "paused does not move")

        player.seek(to: 3)
        XCTAssertEqual(player.position, 3, accuracy: 0.01)
        player.seek(to: 60)
        XCTAssertLessThan(player.position, 4, "a seek past the end stays inside the recording")

        player.seek(to: 2)
        player.playPause(audio)
        XCTAssertEqual(player.state, .playing)
        XCTAssertGreaterThanOrEqual(player.position, 1.99)

        player.stop()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.position, 0)
    }

    func testAnInterruptionPausesInsteadOfLeavingPlayShowing() async throws {
        let player = RecordingPlayer()
        let audio = RecordedAudio.dictation(folder: folder, startedAt: Date())
        player.playPause(audio)
        try await started(player)
        player.interruptionBegan()
        XCTAssertEqual(player.state, .paused)
        player.interruptionBegan()
        XCTAssertEqual(player.state, .paused, "a second interruption changes nothing")
        player.stop()
    }

    /// Waits for the `.m4a` to render and play; a machine with no audio output skips.
    private func started(_ player: RecordingPlayer) async throws {
        for _ in 0..<100 where player.state == .preparing {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard player.state == .playing else { throw XCTSkip("this machine could not start audio playback") }
    }
}
