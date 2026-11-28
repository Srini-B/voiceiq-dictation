import AVFoundation
#if os(macOS)
import CoreAudio
#endif
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
        // Silence: nothing here needs the sound, and the tests shouldn't play a tone aloud.
        buffer.int16ChannelData![0].update(repeating: 0, count: Int(frames))
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
        // One 16 kHz AAC packet is 64 ms; currentTime may land on its start.
        XCTAssertEqual(player.position, 3, accuracy: 0.07)
        player.seek(to: 60)
        XCTAssertLessThan(player.position, player.duration ?? 0, "a seek past the end stays inside the recording")

        player.seek(to: 2)
        player.playPause(audio)
        XCTAssertEqual(player.state, .playing)
        XCTAssertGreaterThanOrEqual(player.position, 1.93)

        player.stop()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.position, 0)
    }

    func testAnInterruptionPausesInsteadOfLeavingPauseShowing() async throws {
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

    /// Waits for the `.m4a` to render and play. Only a machine with no audio
    /// output skips (CI's runners sometimes have none); anything else that keeps
    /// it from playing fails.
    private func started(_ player: RecordingPlayer) async throws {
        try XCTSkipUnless(Self.hasAudioOutput, "this machine has no audio output device")
        for _ in 0..<300 where player.state == .preparing {
            try await Task.sleep(for: .milliseconds(50))
        }
        // An error, not a skip: the test fails.
        guard player.state == .playing else { throw PlaybackDidNotStart(state: player.state) }
    }

    private struct PlaybackDidNotStart: Error { let state: RecordingPlayer.State }

    private static var hasAudioOutput: Bool {
        #if os(macOS)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown
        #else
        return true
        #endif
    }
}
