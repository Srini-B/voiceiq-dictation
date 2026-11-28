import XCTest
import VoiceIQBridge

final class DeliveryRouteTests: XCTestCase {
    private let messages = "com.apple.MobileSMS"
    private let safari = "com.apple.mobilesafari"
    private let made = Date(timeIntervalSince1970: 1_000_000)
    private let hello = Draft.fingerprint(before: "Hello ", after: nil)
    private let other = Draft.fingerprint(before: "Dear Sam", after: nil)

    private func field(_ host: String?, draft: String? = nil, session: UUID = UUID()) -> FieldIdentity {
        FieldIdentity(hostBundleID: host, documentID: session, draft: draft)
    }

    private func route(to destination: FieldIdentity?, in here: FieldIdentity, firstReturn: Bool = false,
                       takesProse: Bool = true, after seconds: TimeInterval = 1) -> Delivery.Route {
        Delivery(text: "On my way", createdAt: made, destination: destination)
            .route(in: here, handledID: nil, firstReturn: firstReturn, takesProse: takesProse,
                   now: made.addingTimeInterval(seconds))
    }

    // MARK: - The keyboard never left

    func testTheSameSessionTypesItWhateverElseDiffers() {
        let session = UUID()
        let stoppedIn = FieldIdentity(hostBundleID: messages, documentID: session, draft: nil)
        // The host failed to resolve this time, and the user typed meanwhile.
        let now = FieldIdentity(hostBundleID: nil, documentID: session, draft: hello)
        XCTAssertEqual(route(to: stoppedIn, in: now), .type(.sameSession))
    }

    // MARK: - Back in a field with text

    func testTheSameDraftInTheSameAppTypesIt() {
        XCTAssertEqual(route(to: field(messages, draft: hello), in: field(messages, draft: hello)), .type(.sameDraft))
    }

    func testAnotherDraftInTheSameAppOnlyOffersIt() {
        XCTAssertEqual(route(to: field(messages, draft: hello), in: field(messages, draft: other), firstReturn: true), .offer)
    }

    func testTheSameDraftInAnotherAppOnlyOffersIt() {
        XCTAssertEqual(route(to: field(messages, draft: hello), in: field(safari, draft: hello), firstReturn: true), .offer)
    }

    func testAnUnresolvedAppOnlyOffersIt() {
        XCTAssertEqual(route(to: field(nil, draft: hello), in: field(nil, draft: hello), firstReturn: true), .offer)
        XCTAssertEqual(route(to: field(messages, draft: hello), in: field(nil, draft: hello), firstReturn: true), .offer)
    }

    func testADraftThatWasThereIsNotMatchedByAnEmptyField() {
        XCTAssertEqual(route(to: field(messages, draft: hello), in: field(messages), firstReturn: true), .offer)
    }

    // MARK: - Back in an empty field

    func testTheFirstEmptyFieldOfTheAppTypesItForTenMinutes() {
        XCTAssertEqual(route(to: field(messages), in: field(messages), firstReturn: true, after: 599), .type(.firstEmptyReturn))
        XCTAssertEqual(route(to: field(messages), in: field(messages), firstReturn: true, after: 600), .offer)
    }

    func testALaterEmptyFieldOfTheAppOnlyOffersIt() {
        XCTAssertEqual(route(to: field(messages), in: field(messages), firstReturn: false), .offer)
    }

    func testAFieldThatGainedTextIsNotTheEmptyOneLeft() {
        XCTAssertEqual(route(to: field(messages), in: field(messages, draft: hello), firstReturn: true), .offer)
    }

    // MARK: - Fields that do not take prose

    func testAnAddressOrNumberFieldIsNeverTakenForTheDestination() {
        XCTAssertEqual(route(to: field(messages, draft: hello), in: field(messages, draft: hello), takesProse: false), .offer)
        XCTAssertEqual(route(to: field(messages), in: field(messages), firstReturn: true, takesProse: false), .offer)
    }

    func testStopTappedInAnAddressFieldStillTypesThere() {
        let session = UUID()
        XCTAssertEqual(route(to: field(messages, session: session), in: field(messages, session: session), takesProse: false),
                       .type(.sameSession))
    }

    // MARK: - First return

    /// Seconds are counted from when the text was ready.
    private func visit(_ host: String?, _ seconds: TimeInterval, session: UUID = UUID()) -> FieldVisit {
        FieldVisit(hostBundleID: host, documentID: session, at: made.addingTimeInterval(seconds))
    }

    private func firstReturn(to back: FieldVisit, visits: [FieldVisit], destinationHost: String? = "com.apple.MobileSMS",
                             stopped seconds: TimeInterval? = -10) -> Bool {
        Delivery(text: "x", createdAt: made, destination: field(destinationHost),
                 stoppedAt: seconds.map(made.addingTimeInterval))
            .isFirstReturn(to: field(back.hostBundleID, session: back.documentID), visits: visits)
    }

    func testOtherAppsSinceTheStopDoNotCount() {
        let back = visit(messages, 90)
        XCTAssertTrue(firstReturn(to: back, visits: [visit(messages, -30), visit(safari, -5), visit(safari, 20), back]))
    }

    func testAnotherFieldOfTheAppSinceTheTextWasReadyCounts() {
        let back = visit(messages, 90)
        XCTAssertFalse(firstReturn(to: back, visits: [visit(messages, -30), visit(messages, 20), back]))
    }

    /// Stop in one chat, then another chat's field while the text is still
    /// being written: the text is not typed into a field opened after that.
    func testAnotherFieldOfTheAppWhileTheTextWasWrittenCounts() {
        let back = visit(messages, 90)
        XCTAssertFalse(firstReturn(to: back, visits: [visit(messages, -30), visit(messages, -5), back]))
    }

    /// A start that opens the app puts the keyboard back in the field under a
    /// new session while the dictation records.
    func testSessionsOfTheAppBeforeTheStopDoNotCount() {
        let back = visit(messages, 90)
        XCTAssertTrue(firstReturn(to: back, visits: [visit(messages, -30), visit(messages, -28), visit(messages, -12), back]))
    }

    /// A call ended the dictation, or the launch recovery wrote it: nobody
    /// tapped Stop, so sessions count from when the text was ready.
    func testWithoutAStopSessionsCountFromWhenTheTextWasReady() {
        let back = visit(messages, 90)
        XCTAssertTrue(firstReturn(to: back, visits: [visit(messages, -5), back], stopped: nil))
        XCTAssertFalse(firstReturn(to: back, visits: [visit(messages, 5), back], stopped: nil))
    }

    /// The limit of the guess: the first field of the app after the stop is
    /// taken for the one left, whichever field it really is.
    func testTheFirstFieldOfTheAppAfterTheStopIsTakenForTheOneLeft() {
        let anotherChat = visit(messages, -5)
        XCTAssertTrue(firstReturn(to: anotherChat, visits: [visit(messages, -30), anotherChat]))
    }

    func testASessionInAnAppThatCouldNotBeNamedCounts() {
        let back = visit(messages, 90)
        XCTAssertFalse(firstReturn(to: back, visits: [visit(nil, 20), back]))
    }

    func testAListTooShortToReachBackIsNotAFirstReturn() {
        let back = visit(messages, 90)
        let elsewhere = (1..<SharedStore.fieldVisitLimit).map { visit(safari, TimeInterval($0)) }
        XCTAssertFalse(firstReturn(to: back, visits: elsewhere + [back]))
        XCTAssertTrue(firstReturn(to: back, visits: [visit(safari, -11)] + elsewhere.dropFirst() + [back]))
    }

    func testWithoutADestinationAppNothingIsAFirstReturn() {
        let back = visit(messages, 90)
        XCTAssertFalse(firstReturn(to: back, visits: [back], destinationHost: nil))
        XCTAssertFalse(Delivery(text: "x", createdAt: made, destination: nil)
            .isFirstReturn(to: field(messages, session: back.documentID), visits: [back]))
    }

    // MARK: - Handled, old, unaddressed

    func testAHandledResultIsLeftAlone() {
        let session = UUID()
        let here = field(messages, session: session)
        let result = Delivery(text: "x", createdAt: made, destination: here)
        XCTAssertEqual(result.route(in: here, handledID: result.id, firstReturn: true, now: made), .leave)
        XCTAssertEqual(result.route(in: here, handledID: UUID(), firstReturn: true, now: made), .type(.sameSession))
        XCTAssertFalse(result.isPending(handledID: result.id, now: made))
    }

    func testItWaitsForAnHour() {
        let destination = field(messages, draft: hello)
        XCTAssertEqual(route(to: destination, in: field(messages, draft: hello), after: 3599), .type(.sameDraft))
        XCTAssertEqual(route(to: destination, in: field(safari), after: 3599), .offer)
        XCTAssertEqual(route(to: destination, in: field(messages, draft: hello), after: 3600), .leave)
        XCTAssertEqual(route(to: destination, in: field(safari), after: 3600), .leave)
        let result = Delivery(text: "x", createdAt: made, destination: destination)
        XCTAssertTrue(result.isPending(handledID: nil, now: made.addingTimeInterval(3599)))
        XCTAssertFalse(result.isPending(handledID: nil, now: made.addingTimeInterval(3600)))
    }

    func testWithNoDestinationTheFirstKeyboardTypesItForTwoMinutes() {
        XCTAssertEqual(route(to: nil, in: field(safari), after: 119), .type(.unaddressed))
        XCTAssertEqual(route(to: nil, in: field(safari), after: 120), .leave)
        XCTAssertFalse(Delivery(text: "x", createdAt: made, destination: nil)
            .isPending(handledID: nil, now: made.addingTimeInterval(120)))
    }

    // MARK: - Drafts and commands

    func testADraftFingerprintIsTheTextNotWhereTheCursorIs() {
        XCTAssertNil(Draft.fingerprint(before: nil, after: nil))
        XCTAssertNil(Draft.fingerprint(before: "", after: ""))
        XCTAssertEqual(Draft.fingerprint(before: "Hello ", after: "there"), Draft.fingerprint(before: "Hel", after: "lo there"))
        XCTAssertNotEqual(Draft.fingerprint(before: "Hello", after: nil), Draft.fingerprint(before: "Hello ", after: nil))
        // FNV-1a's published 64-bit vector for "a": the keyboard and the app
        // must compute the same value in separate processes.
        XCTAssertEqual(Draft.fingerprint(before: "a", after: nil), "af63dc4c8601ec8c")
    }

    func testACommandCarriesItsFieldOnlyWhenItKnowsOne() throws {
        XCTAssertNil(KeyboardCommand(action: .start).field)
        let here = field("com.apple.reminders", draft: hello)
        let sent = try JSONDecoder().decode(KeyboardCommand.self,
                                            from: JSONEncoder().encode(KeyboardCommand(action: .stop, field: here)))
        XCTAssertEqual(sent.field, here)
        XCTAssertEqual(sent.hostBundleID, "com.apple.reminders")
    }

    func testAHandledResultForgetsWhatItsFieldHeld() {
        let result = Delivery(text: "On my way", createdAt: made, destination: field(messages, draft: hello),
                              stoppedAt: made)
        let kept = result.forgettingDraft()
        XCTAssertNil(kept.destination?.draft)
        XCTAssertEqual(kept.destination?.hostBundleID, messages)
        XCTAssertEqual(kept.destination?.documentID, result.destination?.documentID)
        XCTAssertEqual(kept.id, result.id)
        XCTAssertEqual(kept.text, result.text)
        XCTAssertEqual(kept.stoppedAt, made)
        XCTAssertEqual(kept.forgettingDraft(), kept)
    }

    /// A snapshot written by a build before destinations still decodes, and
    /// its result has none.
    func testASnapshotFromAnOlderBuildDecodes() throws {
        let json = """
        {"phase":"warm","meetingActive":false,
         "delivery":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"Hello",
                     "createdAt":1000000,"hostBundleID":"com.apple.MobileSMS"}}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.delivery?.text, "Hello")
        XCTAssertNil(snapshot.delivery?.destination)
        XCTAssertNil(snapshot.delivery?.stoppedAt)
        XCTAssertNil(snapshot.field)
        XCTAssertNil(snapshot.draft)
        XCTAssertNil(snapshot.delivery?.replacesDraft)
    }

    // MARK: - Drafts

    /// The draft and the written text that names it reach the keyboard as
    /// the app wrote them, and a handled result still names its draft.
    func testADraftAndTheTextReplacingItRoundTrip() throws {
        let destination = field(messages, draft: hello)
        let draft = Delivery(text: "see you at noon", createdAt: made, destination: destination)
        let written = Delivery(text: "See you at noon.", createdAt: made, destination: destination,
                               stoppedAt: made, replacesDraft: draft.id)
        let sent = SessionSnapshot(phase: .processing, delivery: written, draft: draft)
        let read = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(read, sent)
        XCTAssertEqual(read.delivery?.replacesDraft, draft.id)
        XCTAssertEqual(written.forgettingDraft().replacesDraft, draft.id)
    }

    /// A keyboard types a draft only while it is fresh, so it never types
    /// one after the app stopped waiting and sent the written text alone.
    func testADraftIsTypedOnlyWithinItsWindowWhichEndsBeforeTheAppStopsWaiting() {
        let draft = Delivery(text: "see you", createdAt: made, destination: field(messages))
        XCTAssertTrue(draft.isFreshDraft(now: made.addingTimeInterval(0.1)))
        XCTAssertFalse(draft.isFreshDraft(now: made.addingTimeInterval(Delivery.draftWindow)))
        XCTAssertFalse(draft.isFreshDraft(now: made.addingTimeInterval(-1)), "a clock that went back")
        XCTAssertLessThan(Delivery.draftWindow, Delivery.draftWait)
    }
}
