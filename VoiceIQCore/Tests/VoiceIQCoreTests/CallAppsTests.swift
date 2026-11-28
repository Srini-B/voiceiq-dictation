#if os(macOS)
import XCTest
@testable import VoiceIQCore

final class CallAppsTests: XCTestCase {
    /// The offer shows the site, not the pattern that matched it.
    func testMeetingPageIsNamedByItsHost() {
        let meet = ["Meet - abc-defg-hij", "https://meet.google.com/abc-defg-hij"]
        XCTAssertEqual(CallApps.meetingName(match: "meet.google.com/", in: meet), "meet.google.com")
        XCTAssertEqual(CallApps.meetingName(match: "webex.com", in: ["https://www.webex.com/meet/pr123"]), "webex.com")
        XCTAssertEqual(CallApps.meetingName(match: "vc.larksuite.com", in: ["https://vc.larksuite.com/j/123456789"]), "vc.larksuite.com")
        // Window titles come first; one that names the site must not hide the address's host.
        XCTAssertEqual(CallApps.meetingName(match: "webex.com", in: ["Weekly sync - tenant.webex.com", "https://tenant.webex.com/meet/alice"]),
                       "tenant.webex.com")
    }

    /// A page found only by its window title gets the meeting's name.
    func testTitleOnlyMatchIsNamedByTheService() {
        XCTAssertEqual(CallApps.meetingName(match: "Meet - ", in: ["Meet - abc-defg-hij"]), "Google Meet")
        XCTAssertEqual(CallApps.meetingName(match: "| Microsoft Teams", in: ["Weekly sync | Microsoft Teams"]), "Microsoft Teams")
    }

    /// Sound alone is a call only in a joined room: not on a site's home
    /// page, nor on a chat site that plays voice messages (Codex on #138).
    func testOnlyAJoinedCallRoomCountsOnSoundAlone() {
        for room in ["https://meet.google.com/abc-defg-hij", "Meet - abc-defg-hij", "https://app.zoom.us/wc/81234567890/join",
                     "https://vdo.ninja/?room=probe42&label=Owner", "https://meet.jit.si/WeeklySync"] {
            XCTAssertTrue(CallApps.isCallRoom([room]), room)
        }
        for page in ["https://meet.google.com/", "https://meet.google.com/landing", "https://vdo.ninja/", "https://meet.jit.si/",
                     "https://web.whatsapp.com/", "https://web.telegram.org/k/", "https://www.messenger.com/t/123",
                     "https://teams.microsoft.com/v2/", "https://discord.com/channels/1/2", "Google Meet"] {
            XCTAssertFalse(CallApps.isCallRoom([page]), page)
        }
    }

    /// Granola's helper stands for Granola, so the offer never names the helper.
    func testHelperBelongsToTheOutermostApp() {
        XCTAssertEqual(CallDetector.containingBundle("/Applications/Granola.app/Contents/Frameworks/Granola Helper (MacOSMicAppsWithDevices).app"),
                       "/Applications/Granola.app")
        XCTAssertEqual(CallDetector.containingBundle("/Applications/Zoom.app/Contents/Frameworks/cpthost.app/Contents/Helpers/x.app"),
                       "/Applications/Zoom.app")
        XCTAssertNil(CallDetector.containingBundle("/Applications/Granola.app"))
    }

    /// A voice-note entry or title name for something the lists do not match would never apply.
    func testListsAgree() {
        XCTAssertTrue(CallApps.voiceNoteApps.isSubset(of: Set(CallApps.known.keys)))
        XCTAssertTrue(Set(CallApps.meetingTitles.keys).isSubset(of: Set(CallApps.meetingPages)))
    }
}
#endif
