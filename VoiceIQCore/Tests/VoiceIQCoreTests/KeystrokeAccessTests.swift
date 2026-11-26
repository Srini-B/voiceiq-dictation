#if os(macOS)
import XCTest
@testable import VoiceIQCore

final class KeystrokeAccessTests: XCTestCase {
    private func macOS(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    func testFrom27Point3PostingNeedsItsOwnGrant() {
        XCTAssertFalse(KeystrokeAccess.mayPost(on: macOS(27, 3), postEventAccess: false))
        XCTAssertTrue(KeystrokeAccess.mayPost(on: macOS(27, 3), postEventAccess: true))
        XCTAssertFalse(KeystrokeAccess.mayPost(on: macOS(28, 0), postEventAccess: false))
    }

    func testBefore27Point3AccessibilityCoversPosting() {
        // A false preflight there must never block a paste.
        XCTAssertTrue(KeystrokeAccess.mayPost(on: macOS(27, 2), postEventAccess: false))
        XCTAssertTrue(KeystrokeAccess.mayPost(on: macOS(15, 6), postEventAccess: false))
    }

    func testTheListIsNamedForTheRunningVersion() {
        XCTAssertEqual(KeystrokeAccess.listName(on: macOS(15, 6)), "Accessibility")
        XCTAssertEqual(KeystrokeAccess.listName(on: macOS(27, 0)), "Device Control and Data Access")
        XCTAssertEqual(KeystrokeAccess.listName(on: macOS(27, 2)), "Device Control and Data Access")
        XCTAssertEqual(KeystrokeAccess.listName(on: macOS(27, 3)), "System & App Protection Override")
        XCTAssertEqual(KeystrokeAccess.listName(on: macOS(28, 0)), "System & App Protection Override")
    }
}
#endif
