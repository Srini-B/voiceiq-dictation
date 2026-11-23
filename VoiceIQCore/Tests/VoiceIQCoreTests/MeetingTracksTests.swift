import XCTest
import VoiceIQSpeech
@testable import VoiceIQCore

/// Speaker ids on a call with two tracks: synthetic tones stand in for speech.
final class MeetingTracksTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingTracksTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A 16 kHz track: a 300 Hz tone where `loud`, faint noise elsewhere.
    private func track(_ name: String, duration: Double, loud: [ClosedRange<Double>]) throws -> TrackAudio {
        let url = root.appendingPathComponent(name)
        try LocalMeetingTranscriber.writeMix(duration: duration, samples: { range in
            let first = Int(range.lowerBound * TrackAudio.sampleRate), last = Int(range.upperBound * TrackAudio.sampleRate)
            return (first..<last).map { index in
                let time = Double(index) / TrackAudio.sampleRate
                guard loud.contains(where: { $0.contains(time) }) else { return Int16(index % 7 - 3) }
                return Int16(9_000 * sin(2 * .pi * 300 * time))
            }
        }, to: url)
        return try TrackAudio(url: url)
    }

    private func call(mic: [ClosedRange<Double>], system: [ClosedRange<Double>]) throws -> CallAudio {
        CallAudio(mic: try track("mic.caf", duration: 12, loud: mic), system: try track("system.caf", duration: 12, loud: system),
                  micIsEchoFree: true, detectedCall: true)
    }

    private func word(_ text: String, _ speaker: String, _ at: Double) -> TimedWord {
        TimedWord(text: text, speaker: speaker, start: at, end: at + 0.5)
    }

    func testANewFarSideVoiceIsNotFoldedIntoTheOnlyKnownOneWhenTheCallShowedTwoOtherPeople() throws {
        let audio = try call(mic: [], system: [0...10])
        var request = AssembledAudio()
        try request.appendBody([0...10]) { range in [Int16](repeating: 0, count: Int((range.upperBound - range.lowerBound) * TrackAudio.sampleRate)) }
        let raw = (1...8).map { DiarizedWord(text: "word\($0)", speaker: "B", start: Double($0), end: Double($0) + 0.5) }
        let known = [TimedWord(text: "earlier", speaker: "s1", start: 0.2, end: 0.6)]

        let alone = MeetingTranscriber.place(raw, audio: request, call: audio, known: known, mapping: [:], remote: 1)
        let twoOthers = MeetingTranscriber.place(raw, audio: request, call: audio, known: known, mapping: [:], remote: 2)

        XCTAssertEqual(Set(alone.map(\.speaker)), ["s1"])
        XCTAssertEqual(Set(twoOthers.map(\.speaker)), ["s2"])
    }

    func testWordsGoToTheTrackTheyWereHeardOn() throws {
        let audio = try call(mic: [0...4], system: [4.2...11])
        let words = [word("hello", "s1", 1), word("me", "you", 2), word("yes", "you", 6), word("budget", "s2", 8)]

        let out = MeetingTranscriber.byTrack(words, audio: audio).map(\.speaker)

        // "hello" was only on the mic; "yes" only on the far side, nearest "budget".
        XCTAssertEqual(out, ["you", "you", "s2", "s2"])
    }

    func testAWordMovedToTheOwnerLendsNoIdToFarSideWords() throws {
        let audio = try call(mic: [0...1], system: [1.2...11])
        let words = [word("ok", "s1", 0.2), word("so", "you", 2), word("then", "s2", 8)]

        XCTAssertEqual(MeetingTranscriber.byTrack(words, audio: audio).map(\.speaker), ["you", "s2", "s2"])
    }

    func testFarSideWordsWithNoFarSpeakerNearbyStayOnePerson() throws {
        let audio = try call(mic: [0...1], system: [5...11])
        let words = [word("hi", "you", 0.2), word("so", "you", 6), word("the", "you", 7), word("plan", "you", 8)]

        XCTAssertEqual(MeetingTranscriber.byTrack(words, audio: audio).map(\.speaker), ["you", "s1", "s1", "s1"])
    }

    func testTheFarSideIsSplitByTheVoicesOnTheSystemTrack() {
        let words = [word("hi", "you", 0.2), word("we", "s1", 1), word("shipped", "s1", 2), word("then", "s1", 6), word("Hafeez", "s1", 7)]
        let segments = [LocalMeetingResult.Segment(speaker: 0, start: 0.5, end: 3), LocalMeetingResult.Segment(speaker: 1, start: 5, end: 8)]

        XCTAssertEqual(MeetingTranscriber.split(words, segments: segments).map(\.speaker), ["you", "s1", "s1", "s2", "s2"])
    }
}
