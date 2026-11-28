import XCTest
#if os(macOS)
import CoreAudio
#endif
@testable import VoiceIQCore

final class MeetingCaptureTests: XCTestCase {
    /// A recording of nothing, or a call before anyone talks, is exact zeros and no stalled tap.
    func testSilenceNeverFiresBeforeTheTrackCarriedSound() {
        var silence = SystemTapWatch.Silence()
        XCTAssertFalse(silence.hear(seconds: 60, exactZero: true))
        XCTAssertFalse(silence.armed)
    }

    func testSilenceFiresAfterFifteenSecondsOfExactZerosAndAgainAfterAnother() {
        var silence = SystemTapWatch.Silence()
        XCTAssertFalse(silence.hear(seconds: 1, exactZero: false))
        XCTAssertFalse(silence.hear(seconds: 14.5, exactZero: true))
        XCTAssertTrue(silence.hear(seconds: 0.5, exactZero: true))
        // Output was idle the first time: the watch asks again after another stretch.
        XCTAssertFalse(silence.hear(seconds: 14.5, exactZero: true))
        XCTAssertTrue(silence.hear(seconds: 0.5, exactZero: true))
    }

    func testSoundRestartsTheZeroCount() {
        var silence = SystemTapWatch.Silence()
        _ = silence.hear(seconds: 1, exactZero: false)
        XCTAssertFalse(silence.hear(seconds: 14, exactZero: true))
        XCTAssertFalse(silence.hear(seconds: 0.01, exactZero: false))
        XCTAssertFalse(silence.hear(seconds: 14, exactZero: true))
        XCTAssertTrue(silence.hear(seconds: 1, exactZero: true))
    }

    /// A replacement tap that also delivers only zeros is caught again, each
    /// time after a longer wait (15, 60, 240 s), and sound resets the wait.
    func testRebuildsBackOffUntilSoundReturns() {
        var silence = SystemTapWatch.Silence()
        _ = silence.hear(seconds: 1, exactZero: false)
        XCTAssertTrue(silence.hear(seconds: 15, exactZero: true))
        silence.rebuilt()
        XCTAssertFalse(silence.hear(seconds: 59, exactZero: true))
        XCTAssertTrue(silence.hear(seconds: 1, exactZero: true))
        silence.rebuilt()
        XCTAssertFalse(silence.hear(seconds: 239, exactZero: true))
        XCTAssertTrue(silence.hear(seconds: 1, exactZero: true))
        silence.rebuilt()
        XCTAssertFalse(silence.hear(seconds: 239, exactZero: true))
        XCTAssertTrue(silence.hear(seconds: 1, exactZero: true))
        XCTAssertFalse(silence.hear(seconds: 0.01, exactZero: false))
        XCTAssertTrue(silence.hear(seconds: 15, exactZero: true))
    }

    /// Headphones flipping the output twice must not push the next stall check to 240 s.
    func testAnOutputMoveRebuildDoesNotBackOff() {
        var silence = SystemTapWatch.Silence()
        _ = silence.hear(seconds: 1, exactZero: false)
        silence.rebuilt(backingOff: false)
        silence.rebuilt(backingOff: false)
        XCTAssertFalse(silence.hear(seconds: 14, exactZero: true))
        XCTAssertTrue(silence.hear(seconds: 1, exactZero: true))
    }

    func testOnlyAMoveToAnotherReadableOutputRebuilds() {
        XCTAssertFalse(SystemTapWatch.outputMoved(from: 73, to: 73))
        XCTAssertTrue(SystemTapWatch.outputMoved(from: 91, to: 73))
        XCTAssertFalse(SystemTapWatch.outputMoved(from: 91, to: 0))
        XCTAssertFalse(SystemTapWatch.outputMoved(from: 0, to: 73))
    }

    /// The time between the old tap's last buffer and the new tap's first is
    /// written as silence, so the system track stays on the mic's clock.
    func testTheGapAcrossARebuildIsPaddedAndJitterIsNot() {
        XCTAssertEqual(SystemTapWatch.gapFrames(lastBufferAt: 100, now: 101.51, bufferSeconds: 0.01, sampleRate: 16_000), 24_000)
        XCTAssertEqual(SystemTapWatch.gapFrames(lastBufferAt: 100, now: 100.03, bufferSeconds: 0.01, sampleRate: 16_000), 0)
        XCTAssertEqual(SystemTapWatch.gapFrames(lastBufferAt: 100, now: 99.9, bufferSeconds: 0.01, sampleRate: 16_000), 0)
    }

    #if os(macOS)
    /// A call app can list the built-in speakers among its devices; the mic never follows them.
    func testTheCallMicIsTheFirstDeviceWithInputChannels() {
        let channels: [AudioDeviceID: UInt32] = [41: 0, 52: 1, 63: 2]
        XCTAssertEqual(CallDetector.firstInput([41, 52, 63], inputChannels: { channels[$0] ?? 0 }), 52)
        XCTAssertNil(CallDetector.firstInput([41], inputChannels: { channels[$0] ?? 0 }))
        XCTAssertNil(CallDetector.firstInput([], inputChannels: { channels[$0] ?? 0 }))
    }

    /// Locked, a browser that only keeps its output open has ended its call; a call app has not.
    func testALockedMacStopsOnlyABrowsersPlaybackCounting() {
        let playing = CallProcesses(objects: [1], inputDevice: nil, isRunningAudio: true, isRunningInput: false)
        XCTAssertFalse(playing.isLive(locked: true, browser: true))
        XCTAssertTrue(playing.isLive(locked: true, browser: false))
        XCTAssertTrue(playing.isLive(locked: false, browser: true))
        let capturing = CallProcesses(objects: [1], inputDevice: nil, isRunningAudio: true, isRunningInput: true)
        XCTAssertTrue(capturing.isLive(locked: true, browser: true))
    }
    #endif

    /// Only Gemini being out of reach makes a meeting wait to be sent again;
    /// a rejected key or a refusal would fail the same way on every retry.
    func testOnlyUnreachableGeminiMakesAMeetingWait() {
        XCTAssertTrue(MeetingFailure.waitsForService(MeetingFailure.noKey))
        XCTAssertTrue(MeetingFailure.waitsForService(TranscriptionError.offline))
        XCTAssertTrue(MeetingFailure.waitsForService(TranscriptionError.network("-1004")))
        XCTAssertTrue(MeetingFailure.waitsForService(TranscriptionError.network("http_503")))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.network("interactions_unavailable_403")))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.network("bad_url")))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.rateLimitedDaily))
        XCTAssertTrue(MeetingFailure.waitsForService(TranscriptionError.rateLimitedTransient(retryAfter: 30)))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.auth))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.safetyBlocked))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.badRequest("bad")))
        XCTAssertFalse(MeetingFailure.waitsForService(CancellationError()))
    }
}
