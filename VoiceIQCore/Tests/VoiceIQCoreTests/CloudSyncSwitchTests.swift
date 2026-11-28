import XCTest
@testable import VoiceIQCore

@MainActor
final class CloudSyncSwitchTests: XCTestCase {
    /// The key-value syncs need no entitlement to start, so without the switch
    /// they would start here and push the Dictionary, writing rules and meeting
    /// folders. The CloudKit syncs (meetings, History) check the switch first
    /// too, but in `swift test` they also stop at the missing entitlement.
    func testNothingSyncsWhileTheTestSwitchIsSet() {
        let saved = CloudSync.isDisabledForTests
        CloudSync.isDisabledForTests = true
        defer { CloudSync.isDisabledForTests = saved }

        DictionarySync.shared.start()
        WritingRulesSync.shared.start()
        MeetingFolderSync.shared.start()

        XCTAssertFalse(DictionarySync.shared.started)
        XCTAssertFalse(WritingRulesSync.shared.started)
        XCTAssertFalse(MeetingFolderSync.shared.started)
    }
}
