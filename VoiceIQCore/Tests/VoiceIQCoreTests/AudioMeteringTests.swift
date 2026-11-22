import AVFoundation
import XCTest
@testable import VoiceIQCore

/// The metering read `floatChannelData?[0]` and SILENTLY RETURNED for anything
/// else. Because that same measurement fed the discard gate, a format change —
/// voice processing above all — would have left every peak at 0 and destroyed
/// every recording as "silence", with no error anywhere. These are the first
/// tests `AudioCaptureEngine` has ever had, and this is why they exist.
final class AudioMeteringTests: XCTestCase {

    private func buffer(
        format: AVAudioCommonFormat,
        sampleRate: Double = 16_000,
        channels: AVAudioChannelCount = 1,
        interleaved: Bool = false,
        fill: (AVAudioPCMBuffer) -> Void
    ) -> AVAudioPCMBuffer {
        // Above 2 channels the convenience initializer returns nil — it has no
        // layout to infer. Voice processing produces exactly such a buffer, so
        // the test has to build the layout explicitly.
        let fmt: AVAudioFormat
        if channels > 2 {
            let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
            )!
            fmt = AVAudioFormat(
                commonFormat: format, sampleRate: sampleRate,
                interleaved: interleaved, channelLayout: layout
            )
        } else {
            fmt = AVAudioFormat(
                commonFormat: format, sampleRate: sampleRate,
                channels: channels, interleaved: interleaved
            )!
        }
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512)!
        buf.frameLength = 512
        fill(buf)
        return buf
    }

    /// Full-scale square wave: RMS is 1.0 in float and 1.0 in Int16 — the two
    /// paths must agree, or the written peak and the tap peak would disagree and
    /// the migration comparison would be meaningless.
    func testFloatAndInt16AgreeOnTheSameSignal() {
        let floats = buffer(format: .pcmFormatFloat32) { buf in
            for index in 0..<Int(buf.frameLength) {
                buf.floatChannelData![0][index] = index % 2 == 0 ? 0.5 : -0.5
            }
        }
        let ints = buffer(format: .pcmFormatInt16, interleaved: true) { buf in
            for index in 0..<Int(buf.frameLength) {
                buf.int16ChannelData![0][index] = index % 2 == 0 ? 16_384 : -16_384
            }
        }
        let floatRMS = try! XCTUnwrap(AudioCaptureEngine.meanSquareRoot(of: floats))
        let intRMS = try! XCTUnwrap(AudioCaptureEngine.meanSquareRoot(of: ints))
        XCTAssertEqual(floatRMS, 0.5, accuracy: 0.01)
        XCTAssertEqual(intRMS, floatRMS, accuracy: 0.01,
                       "the tap peak and the written peak must measure the same thing")
    }

    /// The exact case that used to blind the meter: an Int16 tap buffer.
    /// It must produce a real level, not a silent zero.
    func testInt16BufferIsMeasuredNotSkipped() {
        let ints = buffer(format: .pcmFormatInt16, interleaved: true) { buf in
            for index in 0..<Int(buf.frameLength) {
                buf.int16ChannelData![0][index] = 8_000
            }
        }
        let rms = try! XCTUnwrap(AudioCaptureEngine.meanSquareRoot(of: ints))
        XCTAssertGreaterThan(AudioLevelCurve.level(fromRMS: rms), DictationCoordinator.silencePeakThreshold,
                             "this used to read as silence and discard the recording")
    }

    /// Digital silence really is silence — the safety fix must not invent energy.
    func testTrueSilenceMeasuresZero() {
        let quiet = buffer(format: .pcmFormatFloat32) { _ in }
        XCTAssertEqual(try! XCTUnwrap(AudioCaptureEngine.meanSquareRoot(of: quiet)), 0, accuracy: 0.0001)
    }

    /// A multi-channel buffer — the shape voice processing produces — is measured
    /// from channel 0 rather than refused.
    func testMultiChannelBufferMeasuresChannelZero() {
        let multi = buffer(format: .pcmFormatFloat32, channels: 3) { buf in
            for index in 0..<Int(buf.frameLength) {
                buf.floatChannelData![0][index] = 0.25
                buf.floatChannelData![1][index] = 0
                buf.floatChannelData![2][index] = 0
            }
        }
        XCTAssertEqual(try! XCTUnwrap(AudioCaptureEngine.meanSquareRoot(of: multi)), 0.25, accuracy: 0.01)
    }

    /// Ten ~10 ms sink buffers must read as the one 100 ms tap buffer they
    /// replace: the discard gate and the noise floor were tuned on 100 ms RMS.
    /// A loud 10 ms click followed by quiet must not read as a loud window.
    func testSmallBuffersAddUpToOneHundredMillisecondWindow() {
        var window = RMSWindow()
        var levels: [Float] = []
        for index in 0..<10 {
            let rms: Float = index == 0 ? 0.5 : 0.05
            if let level = window.add(rms: rms, frames: 480, windowFrames: 4_800) { levels.append(level) }
        }
        let expected = ((0.5 * 0.5 + 9 * 0.05 * 0.05) / 10 as Float).squareRoot()
        XCTAssertEqual(levels.count, 1)
        XCTAssertEqual(levels[0], expected, accuracy: 0.0001)
        XCTAssertNil(window.flush(), "the window empties once it reports")
    }

    /// A partial window of at least half a window still reports at the end,
    /// so a short word counts; a 10 ms click on its own does not.
    func testPartialWindowFlushesOnlyWhenLongEnough() {
        var window = RMSWindow()
        for _ in 0..<5 { XCTAssertNil(window.add(rms: 0.4, frames: 480, windowFrames: 4_800)) }
        XCTAssertEqual(try XCTUnwrap(window.flush(minimumFrames: 2_400)), 0.4, accuracy: 0.0001)
        XCTAssertNil(window.add(rms: 0.9, frames: 480, windowFrames: 4_800))
        XCTAssertNil(window.flush(minimumFrames: 2_400))
    }

    /// Dropouts between 50 and 250 ms are filled with exactly the missing
    /// audio; anything shorter is jitter and anything longer is left alone.
    func testOnlyShortDropoutsArePadded() {
        let ms: UInt64 = 1_000_000
        let base: UInt64 = 5_000_000_000
        XCTAssertEqual(AudioCaptureEngine.paddingFrames(expected: base, actual: base + 49 * ms, sampleRate: 16_000), 0)
        XCTAssertEqual(AudioCaptureEngine.paddingFrames(expected: base, actual: base + 140 * ms, sampleRate: 16_000), 2_240)
        XCTAssertEqual(AudioCaptureEngine.paddingFrames(expected: base, actual: base + 250 * ms, sampleRate: 16_000), 4_000)
        XCTAssertEqual(AudioCaptureEngine.paddingFrames(expected: base, actual: base + 251 * ms, sampleRate: 16_000), 0)
        XCTAssertEqual(AudioCaptureEngine.paddingFrames(expected: base + 10 * ms, actual: base, sampleRate: 16_000), 0)
    }
}
