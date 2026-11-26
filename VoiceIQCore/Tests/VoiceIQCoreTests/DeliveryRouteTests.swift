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
                       after seconds: TimeInterval = 1) -> Delivery.Route {
        Delivery(text: "On my way", createdAt: made, destination: destination)
            .route(in: here, handledID: nil, firstReturn: firstReturn, now: made.addingTimeInterval(seconds))
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

    // MARK: - First return

    private func visit(_ host: String?, _ seconds: TimeInterval, session: UUID = UUID()) -> FieldVisit {
        FieldVisit(hostBundleID: host, documentID: session, at: made.addingTimeInterval(seconds))
    }

    private func firstReturn(to back: FieldVisit, visits: [FieldVisit], destinationHost: String? = "com.apple.MobileSMS") -> Bool {
        Delivery(text: "x", createdAt: made, destination: field(destinationHost))
            .isFirstReturn(to: field(back.hostBundleID, session: back.documentID), visits: visits)
    }

    func testOtherAppsSinceTheTextWasReadyDoNotCount() {
        let back = visit(messages, 90)
        XCTAssertTrue(firstReturn(to: back, visits: [visit(messages, -30), visit(safari, 20), back]))
    }

    func testAnotherFieldOfTheAppSinceTheTextWasReadyCounts() {
        let back = visit(messages, 90)
        XCTAssertFalse(firstReturn(to: back, visits: [visit(messages, -30), visit(messages, 20), back]))
    }

    /// A start that opens the app puts the keyboard back in the field under a
    /// new session while the dictation records. Stopped from the Dynamic
    /// Island, the text still goes back there.
    func testSessionsOfTheAppBeforeTheTextWasReadyDoNotCount() {
        let back = visit(messages, 90)
        XCTAssertTrue(firstReturn(to: back, visits: [visit(messages, -30), visit(messages, -28), visit(messages, -5), back]))
    }

    /// The limit of the guess: the first field of the app after the text is
    /// ready is taken for the one left, whichever field it really is.
    func testTheFirstFieldOfTheAppIsTakenForTheOneLeft() {
        let anotherChat = visit(messages, 90)
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
        XCTAssertTrue(firstReturn(to: back, visits: [visit(safari, -1)] + elsewhere.dropFirst() + [back]))
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
        XCTAssertNil(snapshot.field)
    }
}
