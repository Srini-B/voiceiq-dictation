import AVFoundation
import XCTest
@testable import VoiceIQCore

/// Play and Download read the `.m4a` these make, so a dictation or meeting
/// whose audio is on disk must come out as an AAC file of the same length.
final class RecordedAudioTests: XCTestCase {
    private var folder: URL!
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// `seconds` of a 440 Hz tone; zero seconds leaves an empty track, as iPhone's system track is.
    private func track(_ name: String, seconds: Double) throws {
        let writer = try CAFWriter(url: folder.appendingPathComponent(name), format: format)
        defer { writer.close() }
        let frames = AVAudioFrameCount(seconds * 16_000)
        guard frames > 0 else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.int16ChannelData![0][index] = Int16(8_000 * sin(2 * .pi * 440 * Double(index) / 16_000))
        }
        try writer.write(buffer)
    }

    private func seconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    func testDictationAudioBecomesAnM4AOfTheSameLength() async throws {
        try track("audio.caf", seconds: 2.5)
        let audio = RecordedAudio.dictation(folder: folder, startedAt: Date())
        XCTAssertTrue(audio.isAvailable)
        let url = try await audio.m4a()
        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertEqual(try seconds(url), 2.5, accuracy: 0.1)
    }

    /// The longer track sets the length; an empty system track still mixes.
    func testMeetingTracksMixIntoOneM4A() async throws {
        try track("mic.caf", seconds: 3)
        try track("system.caf", seconds: 0)
        let audio = RecordedAudio.meeting(folder: folder, name: "Stand-up 12/11 9:30")
        XCTAssertEqual(audio.name, "Stand-up 12-11 9.30")
        let url = try await audio.m4a()
        XCTAssertEqual(url.lastPathComponent, "Stand-up 12-11 9.30.m4a")
        XCTAssertEqual(try seconds(url), 3, accuracy: 0.1)
    }

    func testMissingAudioIsUnavailable() throws {
        XCTAssertFalse(RecordedAudio.dictation(folder: folder, startedAt: Date()).isAvailable)
        try track("mic.caf", seconds: 1)
        XCTAssertFalse(RecordedAudio.meeting(folder: folder, name: "No system track").isAvailable)
        XCTAssertFalse(RecordedAudio.meeting(folder: nil, name: "Recording").isAvailable)
    }
}
