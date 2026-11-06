import XCTest
@testable import VoiceIQCore

/// A meeting chat is a conversation with no tools, sent through the agent
/// transport on each provider's own API. Each request must replay the earlier
/// turns in order, carry no tool list (hosts reject an empty one), and keep the
/// cache fields that make the second question cheap.
final class MeetingChatTests: XCTestCase {
    private let history = [MeetingChatTurn(question: "Who owns the launch?", answer: "Rohan.",
                                           askedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), model: "m")]
    private var conversation: AgentConversation {
        AgentConversation(system: MeetingChat.system(meeting: "# Launch sync\n\n**Rohan:** I'll own the launch."), tools: [],
                          messages: MeetingChat.messages(history: history, question: "By when?"))
    }

    override func tearDown() {
        StubHost.reset()
        super.tearDown()
    }

    func testClaudeRequestCachesTheMeetingAndTheNewestQuestion() async throws {
        StubHost.reply = #"{"content":[{"type":"text","text":"Friday."}],"usage":{"input_tokens":10,"output_tokens":2}}"#
        let reply = try await transport(.anthropicMessages).send(conversation)

        let body = try StubHost.lastBody()
        XCTAssertNil(body["tools"])
        let system = try XCTUnwrap((body["system"] as? [[String: Any]])?.first)
        XCTAssertTrue((system["text"] as? String ?? "").contains("I'll own the launch."))
        XCTAssertEqual((system["cache_control"] as? [String: Any])?["ttl"] as? String, "1h")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(texts(messages), ["Who owns the launch?", "Rohan.", "By when?"])
        let newest = try XCTUnwrap((messages.last?["content"] as? [[String: Any]])?.last)
        XCTAssertNotNil(newest["cache_control"])
        XCTAssertEqual(reply.text, "Friday.")
    }

    func testOpenAIRequestKeepsOneCacheKeyPerMeeting() async throws {
        StubHost.reply = #"{"id":"resp_1","output":[{"type":"message","content":[{"type":"output_text","text":"Friday."}]}]}"#
        let reply = try await transport(.openAIResponses, model: "gpt-6.1-terra").send(conversation)

        let body = try StubHost.lastBody()
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["prompt_cache_key"] as? String, "voiceiq-meeting-chat-test")
        XCTAssertTrue((body["instructions"] as? String ?? "").contains("I'll own the launch."))
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(texts(input), ["Who owns the launch?", "Rohan.", "By when?"])
        XCTAssertEqual(reply.text, "Friday.")
    }

    func testGeminiRequestSendsNoToolList() async throws {
        StubHost.reply = #"{"candidates":[{"content":{"parts":[{"text":"Friday."}]}}]}"#
        let reply = try await transport(.googleGenerativeAI, model: "gemini-3.8-flash").send(conversation)

        let body = try StubHost.lastBody()
        XCTAssertNil(body["tools"])
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model", "user"])
        XCTAssertEqual(reply.text, "Friday.")
    }

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

    private func transport(_ format: AgentAPIFormat, model: String = "claude-sonnet-5-5") -> AgentTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHost.self]
        let endpoint = AgentEndpoint(baseURL: URL(string: "https://stub.test")!, apiKey: "key", format: format,
                                     modelID: model, label: "stub", isCustom: false)
        return AgentTransport(endpoint: endpoint, stage: .meetingChat, cacheKey: "voiceiq-meeting-chat-test",
                              session: URLSession(configuration: config))
    }

    /// The text of each message, whatever the host calls its parts.
    private func texts(_ messages: [[String: Any]]) -> [String] {
        messages.map { message in
            (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }
    }
}

/// Answers every request with `reply` and keeps the last request body.
private final class StubHost: URLProtocol {
    nonisolated(unsafe) static var reply = "{}"
    nonisolated(unsafe) static var bodies: [Data] = []

    static func reset() { reply = "{}"; bodies = [] }

    static func lastBody() throws -> [String: Any] {
        let data = try XCTUnwrap(bodies.last)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.bodies.append(Self.body(of: request))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
