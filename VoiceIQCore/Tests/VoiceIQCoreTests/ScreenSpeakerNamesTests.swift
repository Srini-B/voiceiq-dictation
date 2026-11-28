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
        // A mic-only recording: no owner track, so the unnamed voice may be the owner.
        let room = Array(call.dropFirst())
        XCTAssertNil(ScreenSpeakerNames.byElimination(nil, transcript: room, named: ["s1": "Dana"], invited: invited)?.speakers["s2"])
    }

    /// s3-four-people's opening: Sara and Rahul answer when addressed. "Thanks
    /// Alex." and "Fair point Grace." address the speaker before, so they name
    /// nobody, and Grace waits for elimination after the notes.
    func testAVoiceAnsweringItsNameIsNamed() {
        let turns: [(String, String)] = [
            ("you", "Morning everyone. Let's go round. Sara, you first."),
            ("s1", "Thanks Alex. Signups were up eight percent last week."),
            ("you", "Nice. Rahul, how did the onboarding email test go?"),
            ("s2", "The shorter email won. Activation went from thirty one to thirty six percent."),
            ("s3", "Before we do, can we check it with the Spanish users first?"),
            ("s2", "Fair point Grace. I can run it on the Spanish segment for one more week."),
        ]
        let call = turns.enumerated().map { index, turn in
            TranscriptSegment(speaker: turn.0, text: turn.1, chunkIndex: 0, start: Double(index * 5), end: Double(index * 5 + 4))
        }
        let invited = ["Sara Lindqvist", "Rahul Mehta", "Grace O'Neill"]
        let named = ScreenSpeakerNames.byAddress(nil, transcript: call, invited: invited)
        XCTAssertEqual(named?.speakers["s1"]?.name, "Sara Lindqvist")
        XCTAssertEqual(named?.speakers["s2"]?.name, "Rahul Mehta")
        XCTAssertNil(named?.speakers["s3"])

        // An interjection during the address is not the answer.
        let interjected = [TranscriptSegment(speaker: "you", text: "Lots to cover. Sara, can you give the update?", chunkIndex: 0, start: 0, end: 20),
                           TranscriptSegment(speaker: "s2", text: "Sorry, one second.", chunkIndex: 0, start: 2, end: 4),
                           TranscriptSegment(speaker: "s1", text: "Signups were up eight percent.", chunkIndex: 0, start: 21, end: 24)]
        XCTAssertNil(ScreenSpeakerNames.byAddress(nil, transcript: interjected, invited: invited))

        // Addressed by first name only, against a two-word invitee; a name on
        // screen already given to another voice is not given again.
        let short = [TranscriptSegment(speaker: "you", text: "Muhammed, where are we with the screenshots?", chunkIndex: 0, start: 0, end: 3),
                     TranscriptSegment(speaker: "s1", text: "I have four of the six done.", chunkIndex: 0, start: 3, end: 6)]
        XCTAssertEqual(ScreenSpeakerNames.byAddress(nil, transcript: short, invited: ["Nihal", "Muhammed Hafeed"])?.speakers["s1"]?.name,
                       "Muhammed Hafeed")
        // A gallery showing the invitees too is still one person per name.
        let gallery = ScreenNames(seen: ["Muhammed Hafeed", "Nihal", "Google Meet"], speakers: [:])
        XCTAssertEqual(ScreenSpeakerNames.byAddress(gallery, transcript: short, invited: ["Nihal", "Muhammed Hafeed"])?.speakers["s1"]?.name,
                       "Muhammed Hafeed")
        let screen = ScreenNames(seen: [], speakers: ["s2": .init(name: "Muhammed Hafeed", seen: 9, of: 10)])
        XCTAssertNil(ScreenSpeakerNames.byAddress(screen, transcript: short, invited: ["Nihal", "Muhammed Hafeed"])?.speakers["s1"])

        // One voice answering two names keeps neither.
        let both = short + [TranscriptSegment(speaker: "you", text: "Nihal, anything else?", chunkIndex: 0, start: 6, end: 8),
                            TranscriptSegment(speaker: "s1", text: "No, that is all from me.", chunkIndex: 0, start: 8, end: 10)]
        XCTAssertNil(ScreenSpeakerNames.byAddress(nil, transcript: both, invited: ["Nihal", "Muhammed Hafeed", "Lee Park"])?.speakers["s1"])
        // A name another voice also answered is nobody's, even when the first
        // voice answered two names (Codex on #129).
        let crossed = both + [TranscriptSegment(speaker: "you", text: "Nihal, and you?", chunkIndex: 0, start: 10, end: 12),
                              TranscriptSegment(speaker: "s2", text: "Fine here.", chunkIndex: 0, start: 12, end: 14)]
        XCTAssertNil(ScreenSpeakerNames.byAddress(nil, transcript: crossed, invited: ["Nihal", "Muhammed Hafeed", "Lee Park"])?.speakers["s2"])
        // A turn addressing two people hands over to neither.
        let handover = [TranscriptSegment(speaker: "you", text: "Sara, thanks for yesterday. Rahul, can you give the update?", chunkIndex: 0, start: 0, end: 4),
                        TranscriptSegment(speaker: "s1", text: "The shorter email won.", chunkIndex: 0, start: 4, end: 6)]
        XCTAssertNil(ScreenSpeakerNames.byAddress(nil, transcript: handover, invited: ["Sara Lindqvist", "Rahul Mehta", "Lee Park"])?.speakers["s1"])
        // Two Saras invited and one already on screen: "Sara," is still ambiguous.
        let saras = ScreenNames(seen: [], speakers: ["s2": .init(name: "Sara Jones", seen: 9, of: 10)])
        let ask = [TranscriptSegment(speaker: "you", text: "Sara, status?", chunkIndex: 0, start: 0, end: 2),
                   TranscriptSegment(speaker: "s1", text: "All green.", chunkIndex: 0, start: 2, end: 4)]
        XCTAssertNil(ScreenSpeakerNames.byAddress(saras, transcript: ask, invited: ["Sara Jones", "Sara Smith", "Lee Park"])?.speakers["s1"])
        // Someone covering for the person addressed is not named after them.
        let covering = [TranscriptSegment(speaker: "you", text: "Sara, can you give the update?", chunkIndex: 0, start: 0, end: 2),
                        TranscriptSegment(speaker: "s1", text: "She is out today. I'm Rahul, covering for her.", chunkIndex: 0, start: 2, end: 5)]
        XCTAssertNil(ScreenSpeakerNames.byAddress(nil, transcript: covering, invited: ["Sara Lindqvist", "Lee Park"]))
        let mentioned = [covering[0], TranscriptSegment(speaker: "s1", text: "Sara is out, I can cover.", chunkIndex: 0, start: 2, end: 5)]
        XCTAssertNil(ScreenSpeakerNames.byAddress(nil, transcript: mentioned, invited: ["Sara Lindqvist", "Lee Park"]))
        // The addresser going on before anyone answers leaves the address unanswered.
        let movedOn = [covering[0], TranscriptSegment(speaker: "you", text: "Never mind, let us move on to the budget.", chunkIndex: 0, start: 2, end: 5),
                       TranscriptSegment(speaker: "s1", text: "The budget is on track.", chunkIndex: 0, start: 5, end: 7)]
        XCTAssertNil(ScreenSpeakerNames.byAddress(nil, transcript: movedOn, invited: ["Sara Lindqvist", "Lee Park"]))
        // "Sara" and "Sara Smith" invited, in either order, are two people.
        XCTAssertNil(ScreenSpeakerNames.byAddress(nil, transcript: ask, invited: ["Sara", "Sara Smith", "Lee Park"])?.speakers["s1"])
        XCTAssertNil(ScreenSpeakerNames.byAddress(nil, transcript: ask, invited: ["Sara Smith", "Sara", "Lee Park"])?.speakers["s1"])
    }
}
