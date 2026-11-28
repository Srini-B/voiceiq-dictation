import XCTest
@testable import VoiceIQCore

/// Meeting chat is saved with its meeting.
final class MeetingChatTests: XCTestCase {
    private let history = [MeetingChatTurn(question: "Who owns the launch?", answer: "Rohan.",
                                           askedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), model: "m")]

    func testChatSurvivesReopeningTheMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingChatTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = MeetingID()
        _ = try store.create(meta: MeetingMeta(id: id, startedAt: Date()))
        XCTAssertEqual(store.loadChat(id: id), [])

        try store.save(chat: history, id: id)
        XCTAssertEqual(MeetingStore(root: root).loadChat(id: id), history)
    }

    func testUnreadableChatIsKeptWhenTheNextAnswerIsSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingChatTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = MeetingID()
        let folder = try store.create(meta: MeetingMeta(id: id, startedAt: Date()))
        let damaged = Data(#"[{"question":"Who owns the launch?"}]"#.utf8)
        try damaged.write(to: folder.appendingPathComponent("chat.json"))

        XCTAssertEqual(store.loadChat(id: id), [])
        try store.save(chat: history, id: id)

        XCTAssertEqual(store.loadChat(id: id), history)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("chat-unreadable-") })
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(aside)), damaged)
    }
}
