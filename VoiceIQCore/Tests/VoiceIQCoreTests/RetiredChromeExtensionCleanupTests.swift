#if os(macOS)
import XCTest
@testable import VoiceIQCore

final class RetiredChromeExtensionCleanupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetiredChromeExtensionCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRemovesInstalledExtensionFilesAndManifestsWhileKeepingOtherData() throws {
        let fm = FileManager.default
        let appSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let voiceIQSupport = appSupport.appendingPathComponent("VoiceiQ", isDirectory: true)

        let extensionFolder = voiceIQSupport.appendingPathComponent("ChromeExtension", isDirectory: true)
        let stagingFolder = voiceIQSupport.appendingPathComponent("ChromeExtension.new", isDirectory: true)
        let speakerLogs = voiceIQSupport.appendingPathComponent("browser-speakers", isDirectory: true)
        let meetingsFolder = voiceIQSupport.appendingPathComponent("meetings", isDirectory: true)
        for dir in [extensionFolder, stagingFolder, speakerLogs, meetingsFolder] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: extensionFolder.appendingPathComponent("manifest.json"))
        try Data("{}".utf8).write(to: speakerLogs.appendingPathComponent("2026-11-23.jsonl"))
        let keptMeeting = meetingsFolder.appendingPathComponent("keep.json")
        try Data("{}".utf8).write(to: keptMeeting)

        let chromeHosts = appSupport.appendingPathComponent("Google/Chrome/NativeMessagingHosts", isDirectory: true)
        let testingHosts = appSupport.appendingPathComponent("Google/Chrome for Testing/NativeMessagingHosts", isDirectory: true)
        let arcHosts = appSupport.appendingPathComponent("Arc/User Data/NativeMessagingHosts", isDirectory: true)
        for dir in [chromeHosts, testingHosts, arcHosts] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let chromeManifest = chromeHosts.appendingPathComponent("io.blue.voiceiq.browser.json")
        let testingManifest = testingHosts.appendingPathComponent("io.blue.voiceiq.browser.json")
        let arcManifest = arcHosts.appendingPathComponent("io.blue.voiceiq.browser.json")
        let unrelatedManifest = chromeHosts.appendingPathComponent("com.example.other.json")
        for file in [chromeManifest, testingManifest, arcManifest, unrelatedManifest] {
            try Data("{}".utf8).write(to: file)
        }

        let removed = FileLayout.removeRetiredChromeExtensionFiles(appSupport: appSupport, voiceIQSupport: voiceIQSupport)

        XCTAssertEqual(removed, 6)
        XCTAssertFalse(fm.fileExists(atPath: extensionFolder.path))
        XCTAssertFalse(fm.fileExists(atPath: stagingFolder.path))
        XCTAssertFalse(fm.fileExists(atPath: speakerLogs.path))
        XCTAssertFalse(fm.fileExists(atPath: chromeManifest.path))
        XCTAssertFalse(fm.fileExists(atPath: testingManifest.path))
        XCTAssertFalse(fm.fileExists(atPath: arcManifest.path))
        XCTAssertTrue(fm.fileExists(atPath: keptMeeting.path))
        XCTAssertTrue(fm.fileExists(atPath: unrelatedManifest.path))
        XCTAssertTrue(fm.fileExists(atPath: chromeHosts.path))

        XCTAssertEqual(FileLayout.removeRetiredChromeExtensionFiles(appSupport: appSupport, voiceIQSupport: voiceIQSupport), 0)
    }
}
#endif
