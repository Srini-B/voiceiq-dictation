import XCTest
@testable import VoiceIQCore

final class ScreenSpeakerNamesTests: XCTestCase {
    /// A snapshot every 3 s for 60 s, each showing the same names.
    private func samples(_ names: [String], single: [String]? = nil, count: Int? = nil) -> [ScreenNameSample] {
        stride(from: 0.0, to: 60, by: 3).map { ScreenNameSample(time: $0, names: names, single: single, count: count) }
    }

    /// The owner talks first, then one far-side speaker for the rest.
    private let twoPeople = [TranscriptSegment(speaker: "you", text: "how is it going", chunkIndex: 0, start: 0, end: 10),
                             TranscriptSegment(speaker: "s1", text: "fine, the build is green", chunkIndex: 0, start: 10, end: 60)]

    func testOneOtherPersonAlwaysOnScreenNamesTheOnlyFarSideSpeaker() {
        let names = ScreenSpeakerNames.match(samples: samples(["Priya Raman", "Google Meet"]), transcript: twoPeople)

        XCTAssertEqual(names?.speakers["s1"]?.name, "Priya Raman")
        XCTAssertNil(names?.probablyMerged)
    }

    func testMorePeopleThanFarSideSpeakersIsMarkedMergedAndNamesNobody() {
        let names = ScreenSpeakerNames.match(samples: samples(["Priya Raman"], count: 3), transcript: twoPeople)

        XCTAssertNil(names?.speakers["s1"])
        XCTAssertEqual(names?.remote, 2)
        XCTAssertEqual(names?.probablyMerged, true)
    }

    func testASingleWordNameSteadyOnScreenIsSeenAndUIWordsAreNot() {
        XCTAssertEqual(ScreenSpeakerNames.singleNames(in: ["Nihal", "Meet", "Chat", "Present now", "nihal_k", "Muhammed Hafeed"]), ["Nihal"])

        let names = ScreenSpeakerNames.match(samples: samples(["Muhammed Hafeed"], single: ["Nihal", "Muhammed"]), transcript: twoPeople)

        XCTAssertTrue(names?.seen.contains("Nihal") == true)
        // A first name standing beside its full name is the same person.
        XCTAssertFalse(names?.seen.contains("Muhammed") == true)
        // Two people on screen, one far-side speaker: neither name is given.
        XCTAssertNil(names?.speakers["s1"])
    }

    func testTheParticipantCountIsReadFromItsButton() {
        XCTAssertEqual(ScreenSpeakerNames.participantCount(in: ["Participants (3)"]), 3)
        XCTAssertEqual(ScreenSpeakerNames.participantCount(in: ["Show everyone", "People 4"]), 4)
        XCTAssertEqual(ScreenSpeakerNames.participantCount(in: ["5 participants"]), 5)
        XCTAssertNil(ScreenSpeakerNames.participantCount(in: ["Q3 budget", "People"]))
    }

    func testACountReadInOneSnapshotIsAMisread() {
        var all = samples(["Priya Raman"], count: 2)
        all[4].count = 9

        XCTAssertEqual(ScreenSpeakerNames.expectedRemote(samples: all), 1)
    }

    func testSavedScreenNamesWithRetiredExtensionFieldsStillDecode() throws {
        let legacyJSON = """
        {
            "seen": ["Priya Raman"],
            "speakers": {
                "s1": {
                    "name": "Priya Raman",
                    "seen": 12,
                    "of": 15,
                    "talkStart": 1.0,
                    "talkSeconds": 12.0
                }
            }
        }
        """
        let decoded = try JSONDecoder().decode(ScreenNames.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.speakers["s1"], ScreenNames.Match(name: "Priya Raman", seen: 12, of: 15))
    }

    func testTheLastUnnamedVoiceGetsTheLastInviteeOnlyWhenTheInviteAccountsForEveryone() {
        let call = [TranscriptSegment(speaker: "you", text: "let us start", chunkIndex: 0, start: 0, end: 3),
                    TranscriptSegment(speaker: "s1", text: "hi this is Dana from finance with the quote", chunkIndex: 0, start: 3, end: 9),
                    TranscriptSegment(speaker: "s2", text: "our usage went down after we moved the logs to cold storage", chunkIndex: 0, start: 9, end: 15)]
        let invited = ["Dana Whitfield", "Kenji Watanabe"]

        let named = ScreenSpeakerNames.byElimination(nil, transcript: call, named: ["s1": "Dana"], invited: invited)
        XCTAssertEqual(named?.speakers["s2"]?.name, "Kenji Watanabe")
        XCTAssertNotNil(named?.speakers["s2"]?.reason)

        // A third invitee nobody heard: the voice could be either of two people.
        XCTAssertNil(ScreenSpeakerNames.byElimination(nil, transcript: call, named: ["s1": "Dana"],
                                                      invited: invited + ["Lee Park"])?.speakers["s2"])
        // Two voices unnamed: nothing to eliminate.
        XCTAssertNil(ScreenSpeakerNames.byElimination(nil, transcript: call, named: [:], invited: invited)?.speakers["s2"])
        // The last voice said almost nothing: likely echo or a sound, not a person.
        let blip = Array(call.prefix(2)) + [TranscriptSegment(speaker: "s2", text: "mm", chunkIndex: 0, start: 9, end: 10)]
        XCTAssertNil(ScreenSpeakerNames.byElimination(nil, transcript: blip, named: ["s1": "Dana"], invited: invited)?.speakers["s2"])
    }
}
