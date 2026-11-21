#if os(macOS)
import XCTest
@testable import VoiceIQCore

final class TypingInserterTests: XCTestCase {
    private func bundle(frameworks: [String: [String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Browser.app")
        for (framework, versions) in frameworks {
            for version in versions {
                let path = root.appendingPathComponent("Contents/Frameworks/\(framework)/Versions/\(version)")
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }

    func testChromiumWithTheClipboardRaceIsTyped() throws {
        let chrome156 = try bundle(frameworks: ["Google Chrome Framework.framework": ["156.0.7311.12", "Current"]])
        XCTAssertEqual(TypingInserter.mode(bundleID: "com.google.Chrome", bundleURL: chrome156), .burst)
        // An update to 157 staged next to the running 155 still counts.
        let staged = try bundle(frameworks: ["Brave Browser Framework.framework": ["157.1.2.3", "155.0.1.2"]])
        XCTAssertEqual(TypingInserter.mode(bundleID: "com.brave.Browser", bundleURL: staged), .burst)
    }

    func testFixedChromiumAndElectronArePasted() throws {
        let chrome157 = try bundle(frameworks: ["Google Chrome Framework.framework": ["157.0.1.2"]])
        XCTAssertNil(TypingInserter.mode(bundleID: "com.google.Chrome", bundleURL: chrome157))
        let electron = try bundle(frameworks: ["Electron Framework.framework": ["A"], "Squirrel.framework": ["155.0.0.1"]])
        XCTAssertNil(TypingInserter.mode(bundleID: "com.tinyspeck.slackmacgap", bundleURL: electron))
    }

    func testRemoteDesktopIsTypedOneKeyAtATime() {
        XCTAssertEqual(TypingInserter.mode(bundleID: "com.microsoft.rdc.macos", bundleURL: nil), .paced)
        XCTAssertEqual(TypingInserter.mode(bundleID: "com.microsoft.WindowsApp", bundleURL: nil), .paced)
        XCTAssertNil(TypingInserter.mode(bundleID: "com.apple.TextEdit", bundleURL: nil))
    }

    func testStrokesKeepSurrogatePairsAndTurnLineBreaksIntoReturns() {
        let text = String(repeating: "a", count: 19) + "😀b\r\nc"
        let strokes = TypingInserter.strokes(text, maxUnits: 20)
        XCTAssertEqual(strokes, [
            .text(Array(String(repeating: "a", count: 19).utf16)),
            .text(Array("😀b".utf16)),
            .lineBreak,
            .text(Array("c".utf16)),
        ])
        XCTAssertEqual(TypingInserter.strokes("ab", maxUnits: 1), [.text(Array("a".utf16)), .text(Array("b".utf16))])
    }
}
#endif
