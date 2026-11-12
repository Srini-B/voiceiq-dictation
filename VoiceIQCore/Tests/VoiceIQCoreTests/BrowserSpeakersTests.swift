import XCTest
import VoiceIQSpeech
@testable import VoiceIQCore

final class BrowserSpeakersTests: XCTestCase {
    private var root: URL!
    private let start = Date(timeIntervalSince1970: 1_793_940_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserSpeakersTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// One event a second, as the extension sends them while someone talks.
    private func events(_ id: String?, names: [String]? = nil, from: Int, to: Int, tab: Int = 7,
                        page: String = "meet.google.com/abc-defg-hij") -> [BrowserSpeakerEvent] {
        (from..<to).map {
            BrowserSpeakerEvent(t: (start.timeIntervalSince1970 + Double($0)) * 1000, page: page, tab: tab, active: id.map { [$0] } ?? [], names: names)
        }
    }

    private func word(_ text: String, _ speaker: String, _ at: Double) -> TimedWord {
        TimedWord(text: text, speaker: speaker, start: at, end: at + 0.4)
    }

    private func meeting(_ events: [BrowserSpeakerEvent]) throws -> URL {
        for event in events { try BrowserSpeakerLog.append(event, root: root) }
        let folder = root.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = MeetingMeta(id: MeetingID(), startedAt: start, endedAt: start.addingTimeInterval(20),
                               source: .browser(bundleID: "com.google.Chrome", host: "meet.google.com"))
        BrowserSpeakers.save(meta: meta, folder: folder, logRoot: root)
        return folder
    }

    func testTwoSimilarVoicesTheDiarizerMergedAreSplitByTheirSources() throws {
        let folder = try meeting(events("ssrc:99", from: 0, to: 20, tab: 3, page: "www.youtube.com/watch")
            + events("csrc:11", from: 2, to: 6) + events("csrc:22", from: 6, to: 12) + events(nil, from: 12, to: 13))
        let words = [word("hi", "you", 0.5), word("budget", "s1", 2.5), word("is", "s1", 3.5), word("late", "s1", 4.5),
                     word("no", "s1", 6.5), word("it", "s1", 8.5), word("shipped", "s1", 10.5), word("ok", "you", 13.5)]

        let out = BrowserSpeakers.apply(words, folder: folder).map(\.speaker)

        XCTAssertEqual(out, ["you", "s1", "s1", "s1", "s2", "s2", "s2", "you"])
    }

    func testWordsTheRecognizerTimesPastTheirTurnStillGoToTheirSpeaker() throws {
        // As measured on the Mac mini: a turn's first word timed half a second
        // before its source got loud, its last word stretched over the silence.
        let folder = try meeting(events("csrc:11", from: 2, to: 6) + events(nil, from: 6, to: 8)
            + events("csrc:22", from: 8, to: 12) + events(nil, from: 12, to: 13))
        let words = [TimedWord(text: "good", speaker: "s1", start: 1.2, end: 1.9), word("plan", "s1", 2.5),
                     TimedWord(text: "week", speaker: "s1", start: 5.5, end: 7.9),
                     word("no", "s1", 8.5), word("it", "s1", 9.5), word("slipped", "s1", 10.5), word("again", "s1", 11.5)]

        let out = BrowserSpeakers.apply(words, folder: folder).map(\.speaker)

        XCTAssertEqual(out, ["s1", "s1", "s1", "s2", "s2", "s2", "s2"])
    }

    func testSpeakersAreNamedByTheTilesThePageLitWhileTheyTalked() throws {
        // The page lights a tile about a second after the voice starts, and
        // keeps Priya's lit for the first second of Max's turn.
        let folder = try meeting(events("csrc:11", names: [], from: 0, to: 1)
            + events("csrc:11", names: ["Priya Raman"], from: 1, to: 6) + events(nil, names: [], from: 6, to: 7)
            + events("csrc:22", names: ["Priya Raman"], from: 7, to: 8)
            + events("csrc:22", names: ["Max Woolf"], from: 8, to: 13) + events(nil, names: [], from: 13, to: 16))
        let transcript = [
            TranscriptSegment(speaker: "s1", text: "the budget is late", chunkIndex: 0, start: 0.2, end: 5.8),
            TranscriptSegment(speaker: "you", text: "why", chunkIndex: 0, start: 6.0, end: 6.8),
            TranscriptSegment(speaker: "s2", text: "no it shipped", chunkIndex: 0, start: 7.2, end: 12.8),
            TranscriptSegment(speaker: "s3", text: "bye", chunkIndex: 0, start: 14.0, end: 15.0),
        ]
        let screen = ScreenNames(seen: ["Alvise Bianchi"], speakers: ["s1": .init(name: "Alvise Bianchi", seen: 3, of: 4)])

        let named = try XCTUnwrap(BrowserSpeakers.name(screen, transcript: transcript, folder: folder))

        XCTAssertEqual(named.speakers.mapValues(\.name), ["s1": "Priya Raman", "s2": "Max Woolf"])
        XCTAssertEqual(named.speakers["s1"]?.talkStart, 1)
        XCTAssertEqual(named.speakers["s1"]?.talkSeconds, 6)
        XCTAssertEqual(named.speakers["s2"]?.talkStart, 8)
        XCTAssertEqual(named.speakers["s2"]?.talkSeconds, 5)
        XCTAssertEqual(named.seen, ["Priya Raman", "Max Woolf", "Alvise Bianchi"])
    }

    func testNamesThePageLitSplitOneMixedStream() throws {
        // Zoom web: everyone on one stream, so only the lit names tell Priya from Max.
        let folder = try meeting(events("ssrc:5", names: ["Priya Raman"], from: 0, to: 6)
            + events("ssrc:5", names: ["Max Woolf"], from: 6, to: 12) + events(nil, names: [], from: 12, to: 13))
        let words = (0..<12).map { word("w\($0)", "s1", Double($0) + 0.2) }

        let out = BrowserSpeakers.apply(words, folder: folder).map(\.speaker)

        XCTAssertEqual(out, Array(repeating: "s1", count: 6) + Array(repeating: "s2", count: 6))
    }

    func testAWordWithNoSingleLoudSourceFollowsWhereItsDiarizerSpeakerMostlyWent() throws {
        let folder = try meeting(events("csrc:11", from: 0, to: 5) + events("csrc:22", from: 6, to: 8)
            + [BrowserSpeakerEvent(t: (start.timeIntervalSince1970 + 5) * 1000, page: "meet.google.com/abc-defg-hij", tab: 7, active: ["csrc:11", "csrc:22"])]
            .sorted { $0.t < $1.t })
        let words = [word("a", "s2", 0.5), word("b", "s2", 1.5), word("c", "s2", 2.5), word("d", "s2", 6.5),
                     word("both", "s2", 5.2)]

        let out = BrowserSpeakers.apply(words, folder: folder).map(\.speaker)

        XCTAssertEqual(out, ["s1", "s1", "s1", "s2", "s1"])
    }

    func testATimelineThatMissesTheMeetingLeavesTheWordsAlone() throws {
        let folder = try meeting(events("csrc:22", from: 2, to: 3) + events(nil, from: 3, to: 4)
            + events("csrc:11", from: 17, to: 18) + events("csrc:22", from: 18, to: 19))
        let words = (0..<10).map { word("w\($0)", $0 < 5 ? "s1" : "s2", Double($0)) } + [word("end", "s1", 17.2)]

        XCTAssertEqual(BrowserSpeakers.apply(words, folder: folder), words)
    }

    func testOneMixedStreamDoesNotUndoTheDiarizer() throws {
        // Zoom web, say: every voice arrives on one stream, so one source is loud throughout.
        let folder = try meeting(events("ssrc:5", from: 0, to: 10))
        let words = (0..<10).map { word("w\($0)", $0 < 5 ? "s1" : "s2", Double($0)) }

        XCTAssertEqual(BrowserSpeakers.apply(words, folder: folder), words)
    }

    func testAMixedStreamThatReconnectsUnderANewIdDoesNotUndoTheDiarizer() throws {
        // Both streams loud for two events while the new one takes over.
        let overlap = [5.0, 6.0].map {
            BrowserSpeakerEvent(t: (start.timeIntervalSince1970 + $0) * 1000, page: "meet.google.com/abc-defg-hij", tab: 7, active: ["ssrc:5", "ssrc:6"])
        }
        let folder = try meeting(events("ssrc:5", from: 0, to: 5) + overlap + events("ssrc:6", from: 7, to: 10))
        let words = (0..<10).map { word("w\($0)", $0 % 2 == 0 ? "s1" : "s2", Double($0)) }

        XCTAssertEqual(BrowserSpeakers.apply(words, folder: folder), words)
    }
}
