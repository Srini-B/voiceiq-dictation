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

    /// Two overlapping meetings: the call's own service decides, else the one
    /// under way, else none rather than the later one.
    func testOverlappingMeetingsMatchByCallServiceOrNotAtAll() {
        typealias E = (name: String, start: Date, text: String)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let standup: E = ("standup", now.addingTimeInterval(-1800), "https://meet.google.com/abc-defg-hij")
        let vendor: E = ("vendor", now.addingTimeInterval(-120), "Join https://acme.zoom.us/j/1")
        let soon: E = ("soon", now.addingTimeInterval(300), "Room 4")
        func pick(_ events: [E], _ source: CallSource?) -> String? {
            CalendarMeetings.pick(events, at: now, services: source.map(CalendarMeetings.services(of:)) ?? [], start: \.start, text: \.text)?.name
        }
        let meet = CallSource.browser(bundleID: "com.google.Chrome", host: "meet.google.com")
        let zoom = CallSource.app(bundleID: "us.zoom.xos", name: "Zoom")
        XCTAssertEqual(pick([standup, vendor], meet), "standup")
        XCTAssertEqual(pick([standup, vendor], zoom), "vendor")
        XCTAssertNil(pick([standup, vendor], nil))
        XCTAssertNil(pick([standup, vendor], .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")))
        XCTAssertEqual(pick([standup, soon], nil), "standup")
        XCTAssertEqual(pick([soon], zoom), "soon")
        let teamsLive: E = ("teams", now.addingTimeInterval(-600), "https://teams.live.com/meet/123")
        XCTAssertEqual(pick([vendor, teamsLive], .app(bundleID: "com.microsoft.teams2", name: "Microsoft Teams")), "teams")
        // Two under way and one about to start: none, not the one about to start (Neon).
        XCTAssertNil(pick([standup, vendor, soon], nil))
        XCTAssertNil(pick([(name: "fake", start: now, text: "https://notzoom.us/j/1"), standup], zoom))
    }

    func testWhenCountsMinutesForTheFirstHour() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(CalendarMeetings.when(now.addingTimeInterval(-120), now: now), "Now")
        XCTAssertEqual(CalendarMeetings.when(now.addingTimeInterval(30), now: now), "in 1 min")
        XCTAssertEqual(CalendarMeetings.when(now.addingTimeInterval(59 * 60), now: now), "in 59 min")
        XCTAssertFalse(CalendarMeetings.when(now.addingTimeInterval(61 * 60), now: now).hasPrefix("in "))
    }

    /// A Keychain save posts a settings change from a background task; the
    /// model built on the main actor must take it there, not trap (a fresh
    /// Mac crashed opening Settings › Advanced, 2026-11-28).
    @MainActor
    func testNextMeetingModelTakesSettingChangesFromBackgroundThreads() async {
        let model = NextMeetingModel()
        await Task.detached {
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "calendarForMeetings")
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "apiKey")
            NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        }.value
        try? await Task.sleep(for: .milliseconds(200))
        _ = model.next
    }
}
#endif
