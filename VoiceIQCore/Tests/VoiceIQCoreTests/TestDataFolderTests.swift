#if os(macOS)
import XCTest
@testable import VoiceIQCore

/// A test copy of the Mac app (another bundle ID, no iCloud) keeps its data
/// in its own folder; written to the real folder, its meetings would be
/// uploaded by the real app at its next launch.
final class TestDataFolderTests: XCTestCase {
    func testOnlyAnAbsolutePathIsATestDataFolder() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TestDataFolderTests-\(UUID().uuidString)"))
        XCTAssertNil(FileLayout.testDataFolder(in: defaults))
        defaults.set("probe-data", forKey: "DebugDataFolder")
        XCTAssertNil(FileLayout.testDataFolder(in: defaults))
        defaults.set("/Users/Shared/probe-data", forKey: "DebugDataFolder")
        XCTAssertEqual(FileLayout.testDataFolder(in: defaults)?.path, "/Users/Shared/probe-data")
    }

    func testAMeetingSavedInATestCopyLandsInItsFolderAndNotTheRealOne() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TestDataFolderTests-\(UUID().uuidString)")
        let savedOverride = FileLayout.overrideRoot, savedFolder = FileLayout.testDataFolder
        FileLayout.overrideRoot = nil
        FileLayout.testDataFolder = folder
        defer {
            FileLayout.overrideRoot = savedOverride
            FileLayout.testDataFolder = savedFolder
            try? FileManager.default.removeItem(at: folder)
        }

        let meta = MeetingMeta(id: MeetingID(), startedAt: Date())
        let saved = try MeetingStore().create(meta: meta)

        XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL, folder.appendingPathComponent("meetings").standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("meta.json").path))
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceiQ/meetings/\(saved.lastPathComponent)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.path))
    }
}
#endif
