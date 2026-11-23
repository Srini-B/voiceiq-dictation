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
                       .init(app: "Zoom", url: URL(string: "https://acme.zoom.us/j/123456789?pwd=xyz")!, bundleIDs: ["us.zoom.xos"]))
        XCTAssertEqual(CalendarMeetings.joinLink(in: "Room 4 https://teams.microsoft.com/l/meetup-join/19%3a")?.app, "Teams")
        XCTAssertNil(CalendarMeetings.joinLink(in: "https://acme.slack.com/huddle https://notzoom.us/j/1"))
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
