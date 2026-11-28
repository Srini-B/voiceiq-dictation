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
        try FarSideSpeakers.writeMix(duration: duration, samples: { range in
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

    /// The owner's voice leaking into the far track comes back as a far-side
    /// speaker repeating the owner; that run goes. A far-side "yeah, okay"
    /// over the owner and a far-side sentence of its own stay, even when one
    /// of its words is also the owner's, and so does a reply the same far
    /// voice starts right after the leak.
    func testTheOwnersVoiceOnTheFarTrackIsDropped() {
        let you = MeetingSpeaker.you
        let owner = ["hello", "everybody", "I'm", "Sarah", "the", "project", "manager"].enumerated()
            .map { word($0.element, you, 10 + Double($0.offset) * 0.6) }
        // The leak, slightly late and one word misheard ("Sara").
        let leak = ["Hello", "everybody.", "I'm", "Sara,", "the", "project", "manager."].enumerated()
            .map { word($0.element, "spk:2", 10.2 + Double($0.offset) * 0.6) }
        let backchannel = [word("Yeah,", "spk:1", 11.0), word("okay.", "spk:1", 11.4)]
        let own = ["the", "budget", "is", "twelve", "euros"].enumerated()
            .map { word($0.element, "spk:1", 20 + Double($0.offset) * 0.6) }
        // Under the leak's label, less than a second after it.
        let reply = ["I'll", "send", "the", "deck", "Friday."].enumerated()
            .map { word($0.element, "spk:2", 14.5 + Double($0.offset) * 0.6) }
        let kept = MeetingTranscriber.droppingOwnerEcho(leak + reply + backchannel + own, owner: owner)
        XCTAssertEqual(kept.map(\.text), ["Yeah,", "okay.", "I'll", "send", "the", "deck", "Friday.",
                                          "the", "budget", "is", "twelve", "euros"])

        // Crosstalk: two of the owner's words land on the same words of a far
        // sentence. Two stray matches are not an echo; the sentence stays whole.
        let crosstalk = [word("the", you, 31.2), word("to", you, 32.4)]
        let sentence = ["we", "should", "not", "cut", "the", "budget", "to", "zero"].enumerated()
            .map { word($0.element, "spk:1", 29 + Double($0.offset) * 0.6) }
        XCTAssertEqual(MeetingTranscriber.droppingOwnerEcho(sentence, owner: crosstalk).map(\.text),
                       sentence.map(\.text))
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

    func testALongTurnBreaksAtASentenceEndIntoParagraphs() {
        let words = (0..<30).map { index in
            TimedWord(text: index % 10 == 9 ? "end." : "word", speaker: "s1", start: Double(index), end: Double(index) + 0.8)
        }
        let turns = SpeakerLinker.overlappingTurns(words, paragraph: 15)
        XCTAssertEqual(turns.map(\.start), [0, 20])
        XCTAssertEqual(SpeakerLinker.overlappingTurns(words).count, 1)
    }

    func testAVoiceHeardUnderOnePercentOfTheMeetingGivesItsWordsToTheNearestOtherVoice() {
        // 1000 s meeting: "far a" talks at the start, "far b" at the end;
        // "far c" says "yeah" near b for 0.5 s, "far d" talks 12 s and stays.
        var words = (0..<200).map { TimedWord(text: "a", speaker: "far a", start: Double($0), end: Double($0) + 0.9) }
        words += (0..<200).map { TimedWord(text: "b", speaker: "far b", start: 800 + Double($0), end: 800.9 + Double($0)) }
        words += [TimedWord(text: "yeah", speaker: "far c", start: 850.2, end: 850.7)]
        words += (0..<15).map { TimedWord(text: "d", speaker: "far d", start: 400 + Double($0), end: 400.8 + Double($0)) }
        words += [TimedWord(text: "me", speaker: MeetingSpeaker.you, start: 851, end: 851.1)]
        let out = MeetingTranscriber.foldingStrayVoices(words)
        XCTAssertEqual(out.count, words.count)
        XCTAssertEqual(out.first { $0.text == "yeah" }?.speaker, "far b")
        XCTAssertEqual(Set(out.map(\.speaker)), ["far a", "far b", "far d", MeetingSpeaker.you])

        // An hour-long call: 30 s of speech is under 1% but a participant.
        var hour = (0..<3600).map { TimedWord(text: "a", speaker: "far a", start: Double($0), end: Double($0) + 0.9) }
        hour += (0..<30).map { TimedWord(text: "e", speaker: "far e", start: 1800 + Double($0), end: 1801 + Double($0)) }
        XCTAssertTrue(MeetingTranscriber.foldingStrayVoices(hour).contains { $0.speaker == "far e" })
    }

    /// Core ML's failed prediction is tried again, the last time on the CPU;
    /// any other error is not. A model that still fails marks the meeting and
    /// keeps AssemblyAI's voices.
    func testAFailedSpeakerModelPredictionIsRetriedThenMarked() async throws {
        let audio = try call(mic: [0...0.5], system: [0.5...8])
        let words = [word("hi", "you", 0.2), word("we", "s1", 1), word("shipped", "s1", 2), word("then", "s1", 6), word("Hafeez", "s1", 7)]
        let segments = [LocalMeetingResult.Segment(speaker: 0, start: 0.5, end: 3), LocalMeetingResult.Segment(speaker: 1, start: 5, end: 8)]
        let prediction = NSError(domain: "com.apple.CoreML", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Unable to compute the asynchronous prediction using ML Program."])
        final class Calls: @unchecked Sendable { var cpuOnly: [Bool] = [] }

        func transcriber(failures: Int, error: Error, calls: Calls) -> MeetingTranscriber {
            MeetingTranscriber(client: AssemblyAIClient(apiKey: { "test" }), diarizeFarSide: { _ in
                try await FarSideSpeakers.retrying(delays: [0, 0], sleep: { _ in }) { cpuOnly in
                    calls.cpuOnly.append(cpuOnly)
                    if calls.cpuOnly.count <= failures { throw error }
                    return segments
                }
            })
        }

        let recovered = Calls()
        let split = try await transcriber(failures: 2, error: prediction, calls: recovered).splitFarSide(words, audio: audio, folder: root)
        XCTAssertEqual(recovered.cpuOnly, [false, false, true])
        XCTAssertEqual(split.map(\.speaker), ["you", "s1", "s1", "s2", "s2"])
        XCTAssertFalse(MeetingTranscriber.farSideFailed(folder: root))

        try FileManager.default.removeItem(at: root.appendingPathComponent(MeetingTranscriber.farSpeakersCacheName))
        let failing = Calls()
        let kept = try await transcriber(failures: 3, error: prediction, calls: failing).splitFarSide(words, audio: audio, folder: root)
        XCTAssertEqual(failing.cpuOnly.count, 3)
        XCTAssertEqual(kept.map(\.speaker), words.map(\.speaker))
        XCTAssertTrue(MeetingTranscriber.farSideFailed(folder: root))

        #if os(macOS)
        // On the Mac the helper reports the failure as text, whatever wraps Core ML's error.
        XCTAssertTrue(FarSideSpeakers.failedPrediction(LocalMeetingHelper.Failure.helper("processingFailed(\"segmentation\")")))
        XCTAssertFalse(FarSideSpeakers.failedPrediction(LocalMeetingHelper.Failure.timedOut))
        #endif
        let other = Calls()
        _ = try await transcriber(failures: 1, error: CocoaError(.fileReadCorruptFile), calls: other).splitFarSide(words, audio: audio, folder: root)
        XCTAssertEqual(other.cpuOnly, [false])
        XCTAssertTrue(MeetingTranscriber.farSideFailed(folder: root))
    }
}
