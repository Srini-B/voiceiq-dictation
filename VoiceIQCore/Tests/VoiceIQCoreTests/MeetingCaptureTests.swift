import XCTest
#if os(macOS)
import CoreAudio
#endif
@testable import VoiceIQCore

final class MeetingCaptureTests: XCTestCase {
    /// A call never heard from the start is caught after 15 s: m2 and m3 of the live-call probe.
    func testSilenceFiresOnATrackThatWasQuietFromTheStart() {
        var silence = SystemTapWatch.Silence()
        XCTAssertFalse(silence.hear(seconds: 14.5, quiet: true))
        XCTAssertTrue(silence.hear(seconds: 0.5, quiet: true))
        // Output was idle the first time: the watch asks again after another stretch.
        XCTAssertFalse(silence.hear(seconds: 14.5, quiet: true))
        XCTAssertTrue(silence.hear(seconds: 0.5, quiet: true))
    }

    /// Noise near −84 dBFS is quiet; a Meet call's speech near −60 dBFS is not.
    func testQuietIsBelowAboutSeventyTwoDecibelsUnderFullScale() {
        XCTAssertTrue(([2, -3, 1, 8, -8] as [Int16]).withUnsafeBufferPointer(SystemTapWatch.isQuiet))
        XCTAssertFalse(([2, -3, 1, 9] as [Int16]).withUnsafeBufferPointer(SystemTapWatch.isQuiet))
        XCTAssertFalse(([Int16(-9)]).withUnsafeBufferPointer(SystemTapWatch.isQuiet))
        XCTAssertFalse(([Int16(32)]).withUnsafeBufferPointer(SystemTapWatch.isQuiet))
    }

    /// Once the far side was heard, a quiet stretch is waited out for 60 s,
    /// so the owner's long turn does not rebuild the tap (Neon on #137).
    func testAfterSoundTheWatchWaitsSixtySeconds() {
        var silence = SystemTapWatch.Silence()
        XCTAssertFalse(silence.hear(seconds: 1, quiet: false))
        XCTAssertFalse(silence.hear(seconds: 59.5, quiet: true))
        XCTAssertTrue(silence.hear(seconds: 0.5, quiet: true))
    }

    func testSoundRestartsTheQuietCount() {
        var silence = SystemTapWatch.Silence()
        _ = silence.hear(seconds: 1, quiet: false)
        XCTAssertFalse(silence.hear(seconds: 50, quiet: true))
        XCTAssertFalse(silence.hear(seconds: 0.01, quiet: false))
        XCTAssertFalse(silence.hear(seconds: 50, quiet: true))
        XCTAssertTrue(silence.hear(seconds: 10, quiet: true))
    }

    /// A replacement tap that also delivers only quiet is caught again, each
    /// time after a longer wait, and sound resets the wait.
    func testRebuildsBackOffUntilSoundReturns() {
        var silence = SystemTapWatch.Silence()
        XCTAssertTrue(silence.hear(seconds: 15, quiet: true))
        silence.rebuilt()
        XCTAssertFalse(silence.hear(seconds: 59, quiet: true))
        XCTAssertTrue(silence.hear(seconds: 1, quiet: true))
        silence.rebuilt()
        XCTAssertFalse(silence.hear(seconds: 239, quiet: true))
        XCTAssertTrue(silence.hear(seconds: 1, quiet: true))
        silence.rebuilt()
        XCTAssertFalse(silence.hear(seconds: 239, quiet: true))
        XCTAssertTrue(silence.hear(seconds: 1, quiet: true))
        XCTAssertFalse(silence.hear(seconds: 0.01, quiet: false))
        XCTAssertFalse(silence.hear(seconds: 59, quiet: true))
        XCTAssertTrue(silence.hear(seconds: 1, quiet: true))
    }

    /// Headphones flipping the output twice must not push the next stall check out.
    func testAnOutputMoveRebuildDoesNotBackOff() {
        var silence = SystemTapWatch.Silence()
        silence.rebuilt(backingOff: false)
        silence.rebuilt(backingOff: false)
        XCTAssertFalse(silence.hear(seconds: 14, quiet: true))
        XCTAssertTrue(silence.hear(seconds: 1, quiet: true))
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

    /// Only AssemblyAI being out of reach makes a meeting wait to be sent again;
    /// a rejected key or a refusal would fail the same way on every retry.
    func testOnlyAnUnreachableServiceMakesAMeetingWait() {
        XCTAssertTrue(MeetingFailure.waitsForService(MeetingFailure.noKey))
        XCTAssertTrue(MeetingFailure.waitsForService(TranscriptionError.offline))
        XCTAssertTrue(MeetingFailure.waitsForService(TranscriptionError.network("-1004")))
        XCTAssertTrue(MeetingFailure.waitsForService(TranscriptionError.network("http_503")))
        XCTAssertTrue(MeetingFailure.waitsForService(TranscriptionError.network("transcript_server_error")))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.network("unparseable_response")))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.network("bad_url")))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.rateLimitedDaily))
        XCTAssertTrue(MeetingFailure.waitsForService(TranscriptionError.rateLimitedTransient(retryAfter: 30)))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.auth))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.safetyBlocked))
        XCTAssertFalse(MeetingFailure.waitsForService(TranscriptionError.badRequest("bad")))
        XCTAssertFalse(MeetingFailure.waitsForService(CancellationError()))
    }
}
