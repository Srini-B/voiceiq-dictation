import XCTest
@testable import VoiceIQCore

final class BrowserExtensionInstallsTests: XCTestCase {
    private var support: URL!
    private let id = "gjobkaplebdoedjfopfmogibphjmglaa"

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserExtensionInstallsTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: support) }

    private func write(_ json: Any, _ path: String) throws {
        let url = support.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    private func extensions(_ settings: [String: Any]) -> [String: Any] { ["extensions": ["settings": settings]] }

    func testOnlyProfilesThatStillHaveTheExtensionCount() throws {
        let unpacked: [String: Any] = ["location": 4, "path": "/Users/c/Library/Application Support/VoiceiQ/ChromeExtension", "disable_reasons": []]
        // Profile 4 has it loaded unpacked; Profile 2 has it turned off.
        try write(extensions([id: unpacked]), "Google/Chrome/Profile 4/Secure Preferences")
        try write(extensions([id: ["location": 4, "disable_reasons": [1]]]), "Google/Chrome/Profile 2/Secure Preferences")
        // Default had it and removed it: Chrome left an empty entry behind.
        try write(extensions([id: [String: Any]()]), "Google/Chrome/Default/Preferences")
        try write(extensions(["someotherextensionid": unpacked]), "Google/Chrome/Profile 5/Secure Preferences")
        try write(["profile": ["info_cache": ["Profile 4": ["name": "Work"]]]], "Google/Chrome/Local State")

        let installs = BrowserExtensionInstalls.find(id: id, support: support)

        XCTAssertEqual(installs, [
            BrowserExtensionInstall(browser: "Google/Chrome", profile: "Profile 2", profileName: nil, enabled: false),
            BrowserExtensionInstall(browser: "Google/Chrome", profile: "Profile 4", profileName: "Work", enabled: true),
        ])
    }

    func testRemovedEverywhereFindsNone() throws {
        try write(extensions([id: [String: Any]()]), "Google/Chrome/Profile 4/Preferences")
        try write(extensions([:]), "Google/Chrome/Profile 4/Secure Preferences")

        XCTAssertEqual(BrowserExtensionInstalls.find(id: id, support: support), [])
    }
}
