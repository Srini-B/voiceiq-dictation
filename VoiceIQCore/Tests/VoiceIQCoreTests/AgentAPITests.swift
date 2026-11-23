import XCTest
@testable import VoiceIQCore

/// The local API and MCP server coding agents read History and meetings through.
final class AgentAPITests: XCTestCase {
    private var root: URL!
    private var api: AgentAPI!
    private let key = "viq_test-key"
    private let older = MeetingID(), newer = MeetingID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentAPITests-\(UUID().uuidString)")
        let history = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"))
        for (text, daysAgo) in [("Ship the beta on Friday", 10.0), ("Call the dentist", 1.0)] {
            var meta = SessionMeta(id: UUID(), startedAt: Date().addingTimeInterval(-daysAgo * 86_400), status: .inserted)
            meta.rawTranscript = text
            meta.targetAppName = "Slack"
            history.upsert(meta: meta, folder: root.appendingPathComponent(meta.id.uuidString))
        }

        let meetings = MeetingStore(root: root.appendingPathComponent("meetings"))
        var first = MeetingMeta(id: older, startedAt: Date(timeIntervalSinceNow: -7200), durationSeconds: 600, status: .done)
        first.speakerNames = ["s1": "Priya"]
        _ = try meetings.create(meta: first)
        try meetings.save(transcript: [
            TranscriptSegment(speaker: "you", text: "Where are we on pricing?", chunkIndex: 0, start: 3, end: 5),
            TranscriptSegment(speaker: "s1", text: "Pricing ships after the budget review.", chunkIndex: 0, start: 75, end: 80),
        ], id: older)
        try meetings.save(notes: MeetingNotes(title: "Pricing sync", summary: "Pricing waits for budget.", decisions: [],
                                              actions: [ActionItem(text: "Send the deck", owner: "Priya")], notes: []), id: older)
        try meetings.save(chat: [MeetingChatTurn(question: "Who sends the deck?", answer: "Priya.", model: "m")], id: older)
        _ = try meetings.create(meta: MeetingMeta(id: newer, startedAt: Date(timeIntervalSinceNow: -60), status: .recording))

        api = AgentAPI(key: key, library: AgentLibrary(history: history, meetings: meetings), version: "1.0")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func get(_ path: String, query: [String: String] = [:], headers: [String: String]? = nil) -> AgentAPI.Response {
        api.respond(to: .init(method: "GET", path: path, query: query,
                              headers: headers ?? ["host": "127.0.0.1:47823", "authorization": "Bearer \(key)"], body: Data()))
    }

    private func rpc(_ method: String, _ params: [String: Any] = [:], id: Any? = 1) throws -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { message["id"] = id }
        let response = api.respond(to: .init(method: "POST", path: "/mcp", query: [:],
                                             headers: ["host": "localhost:47823", "authorization": "Bearer \(key)"],
                                             body: try JSONSerialization.data(withJSONObject: message)))
        XCTAssertEqual(response.status, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func toolText(_ name: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let result = try XCTUnwrap(try rpc("tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (try XCTUnwrap(content.first?["text"] as? String), result["isError"] as? Bool ?? false)
    }

    func testOnlyKeyedLoopbackNonBrowserRequestsAreAnswered() {
        let good = ["host": "127.0.0.1:47823", "authorization": "Bearer \(key)"]
        XCTAssertEqual(get("/v1/health", headers: good).status, 200)
        XCTAssertEqual(get("/v1/health", headers: ["host": "127.0.0.1:47823"]).status, 401)
        XCTAssertEqual(get("/v1/health", headers: ["host": "127.0.0.1:47823", "authorization": "Bearer viq_test-kez"]).status, 401)
        // A page on a rebound host name, or any page at all, carries a foreign Host or an Origin.
        XCTAssertEqual(get("/v1/health", headers: good.merging(["host": "attacker.example:47823"]) { $1 }).status, 403)
        XCTAssertEqual(get("/v1/health", headers: good.merging(["origin": "http://127.0.0.1:47823"]) { $1 }).status, 403)
    }

    func testRESTListsDictationsSinceADayAndAMeetingAsMarkdown() throws {
        let day = Date().addingTimeInterval(-3 * 86_400).formatted(.iso8601.year().month().day())
        let dictations = try JSONSerialization.jsonObject(with: get("/v1/dictations", query: ["since": day]).body) as? [[String: Any]]
        XCTAssertEqual(dictations?.map { $0["text"] as? String }, ["Call the dentist"])
        XCTAssertEqual(get("/v1/dictations", query: ["since": "last week"]).status, 400)

        let markdown = String(decoding: get("/v1/meetings/\(older.uuid.uuidString.lowercased())", query: ["format": "markdown"]).body, as: UTF8.self)
        XCTAssertTrue(markdown.contains("[01:15] **Priya:** Pricing ships after the budget review."), markdown)
        XCTAssertTrue(markdown.contains("**Q:** Who sends the deck?"), markdown)
        XCTAssertEqual(get("/v1/meetings/\(UUID().uuidString)").status, 404)
    }

    func testMCPHandshakeAndToolList() throws {
        let initialize = try XCTUnwrap(try rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]])["result"] as? [String: Any])
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((initialize["capabilities"] as? [String: Any])?["tools"])

        let notification = api.respond(to: .init(method: "POST", path: "/mcp", query: [:],
                                                 headers: ["host": "127.0.0.1:47823", "authorization": "Bearer \(key)"],
                                                 body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        XCTAssertEqual(notification.status, 202)
        XCTAssertTrue(notification.body.isEmpty)

        let tools = try XCTUnwrap((try rpc("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["list_dictations", "list_meetings", "get_meeting"])
        XCTAssertEqual((try rpc("no/such")["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testMCPToolsSearchAndReadMeetings() throws {
        let all = try JSONSerialization.jsonObject(with: Data(try toolText("list_meetings", [:]).text.utf8)) as? [[String: Any]]
        XCTAssertEqual(all?.compactMap { $0["id"] as? String }, [newer.uuid.uuidString, older.uuid.uuidString])

        let hits = try JSONSerialization.jsonObject(with: Data(try toolText("list_meetings", ["query": "BUDGET"]).text.utf8)) as? [[String: Any]]
        XCTAssertEqual(hits?.count, 1)
        XCTAssertEqual(hits?.first?["title"] as? String, "Pricing sync")
        XCTAssertEqual(hits?.first?["speakers"] as? [String], ["You", "Priya"])
        XCTAssertEqual(hits?.first?["matches"] as? [String], ["[01:15] Priya: Pricing ships after the budget review."])

        let json = try toolText("get_meeting", ["id": older.uuid.uuidString, "format": "json"]).text
        let meeting = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let turns = try XCTUnwrap(meeting["transcript"] as? [[String: Any]])
        XCTAssertEqual(turns.map { $0["speaker"] as? String }, ["You", "Priya"])
        XCTAssertEqual(turns.last?["start"] as? Double, 75)
        XCTAssertEqual((meeting["chat"] as? [[String: Any]])?.first?["answer"] as? String, "Priya.")

        // Reading never changes the store, even a chat that no longer decodes.
        let chat = try XCTUnwrap(MeetingStore(root: root.appendingPathComponent("meetings")).folder(for: newer)).appendingPathComponent("chat.json")
        try Data("{".utf8).write(to: chat)
        let latest = try toolText("get_meeting", ["id": "latest"])
        XCTAssertTrue(latest.text.hasPrefix("Meeting id: \(newer.uuid.uuidString)"), latest.text)
        XCTAssertFalse(try toolText("get_meeting", ["id": "latest", "format": "json"]).isError)
        XCTAssertEqual(try String(contentsOf: chat, encoding: .utf8), "{")
        XCTAssertTrue(try toolText("get_meeting", ["id": "nope"]).isError)
    }

    func testMeetingsShowTheirFoldersAndFilterByOne() throws {
        let meetings = MeetingStore(root: root.appendingPathComponent("meetings"))
        let clients = try meetings.createFolder(named: "Clients"), sales = try meetings.createFolder(named: "Sales")
        let gone = try meetings.createFolder(named: "Old")
        try meetings.setFolderIDs([sales.id, gone.id, clients.id], for: older)
        try meetings.setFolderIDs([clients.id], for: newer)
        try meetings.deleteFolder(gone.id)

        func ids(_ arguments: [String: Any]) throws -> [String]? {
            let list = try JSONSerialization.jsonObject(with: Data(try toolText("list_meetings", arguments).text.utf8)) as? [[String: Any]]
            return list?.compactMap { $0["id"] as? String }
        }
        XCTAssertEqual(try ids(["folder": "sales"]), [older.uuid.uuidString])
        XCTAssertEqual(try ids(["folder": clients.id.uuidString]), [newer.uuid.uuidString, older.uuid.uuidString])
        XCTAssertEqual(try ids(["folder": "Clients", "query": "budget"]), [older.uuid.uuidString])
        let unknown = try toolText("list_meetings", ["folder": "Old"])
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.text.contains("Clients, Sales"), unknown.text)
        // An id wins over a folder whose name is that id.
        try meetings.createFolder(named: sales.id.uuidString)
        XCTAssertEqual(try ids(["folder": sales.id.uuidString]), [older.uuid.uuidString])

        // A deleted folder no longer shows; the rest show by name.
        let json = try toolText("get_meeting", ["id": older.uuid.uuidString, "format": "json"]).text
        let meeting = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((meeting["meeting"] as? [String: Any])?["folders"] as? [String], ["Clients", "Sales"])
        XCTAssertTrue(try toolText("get_meeting", ["id": older.uuid.uuidString]).text.contains("Folders: Clients, Sales\n"))

        let rest = try JSONSerialization.jsonObject(with: get("/v1/meetings", query: ["folder": "SALES"]).body) as? [[String: Any]]
        XCTAssertEqual(rest?.compactMap { $0["id"] as? String }, [older.uuid.uuidString])
        XCTAssertEqual(get("/v1/meetings", query: ["folder": "nope"]).status, 404)
    }

    func testParseWaitsForTheWholeBody() {
        let head = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:47823\r\nContent-Length: 4\r\n\r\n"
        XCTAssertEqual(AgentAPI.parse(Data((head + "ab").utf8)), .incomplete)
        guard case .complete(let request) = AgentAPI.parse(Data((head + "abcd").utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.query, ["x": "1"])
        XCTAssertEqual(request.headers["host"], "127.0.0.1:47823")
        XCTAssertEqual(request.body, Data("abcd".utf8))
        guard case .invalid(let chunked) = AgentAPI.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) else {
            return XCTFail("chunked accepted")
        }
        XCTAssertEqual(chunked.status, 411)
    }
}
