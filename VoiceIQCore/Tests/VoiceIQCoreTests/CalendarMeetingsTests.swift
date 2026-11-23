#if os(macOS)
import XCTest
@testable import VoiceIQCore

final class CalendarMeetingsTests: XCTestCase {
    /// Join goes to the call, not to the first link in the invite.
    func testJoinLinkIsTheCallServiceLink() {
        let notes = """
        Agenda: https://docs.google.com/document/d/abc
        Chat: https://acme.slack.com/archives/C123
        Join: https://acme.zoom.us/j/123456789?pwd=xyz
        Backup: https://meet.google.com/abc-defg-hij
        """
        XCTAssertEqual(CalendarMeetings.joinLink(in: notes),
                       .init(app: "Zoom", url: URL(string: "https://acme.zoom.us/j/123456789?pwd=xyz")!, service: "zoom.us"))
        XCTAssertEqual(CalendarMeetings.joinLink(in: "Room 4 https://teams.microsoft.com/l/meetup-join/19%3a")?.app, "Teams")
        XCTAssertNil(CalendarMeetings.joinLink(in: "https://acme.slack.com/huddle https://notzoom.us/j/1"))
    }

    /// The button turns to Record only when call detection hears this meeting's service.
    func testJoinMatchesOnlyItsOwnServiceCall() throws {
        let zoom = try XCTUnwrap(CalendarMeetings.joinLink(in: "https://acme.zoom.us/j/1"))
        XCTAssertTrue(zoom.matches(.app(bundleID: "us.zoom.xos", name: "Zoom")))
        XCTAssertTrue(zoom.matches(.browser(bundleID: "com.google.Chrome", host: "app.zoom.us")))
        XCTAssertFalse(zoom.matches(.app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")))
        XCTAssertFalse(zoom.matches(.browser(bundleID: "com.google.Chrome", host: "meet.google.com")))
        let meet = try XCTUnwrap(CalendarMeetings.joinLink(in: "https://meet.google.com/abc-defg-hij"))
        XCTAssertTrue(meet.matches(.browser(bundleID: "com.apple.Safari", host: "meet.google.com")))
        XCTAssertFalse(meet.matches(.app(bundleID: "us.zoom.xos", name: "Zoom")))
    }

    func testWhenCountsMinutesForTheFirstHour() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(CalendarMeetings.when(now.addingTimeInterval(-120), now: now), "Now")
        XCTAssertEqual(CalendarMeetings.when(now.addingTimeInterval(30), now: now), "in 1 min")
        XCTAssertEqual(CalendarMeetings.when(now.addingTimeInterval(59 * 60), now: now), "in 59 min")
        XCTAssertFalse(CalendarMeetings.when(now.addingTimeInterval(61 * 60), now: now).hasPrefix("in "))
    }
}
#endif
