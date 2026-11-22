import XCTest
@testable import VoiceIQCore

/// VoiceiQ adding itself to Claude Code, Codex and Amp's own config files.
final class AgentClientsTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentClientsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, to path: String) throws -> URL {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func json(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    func testClaudeCodeKeepsEverythingElseAndFollowsTheKey() throws {
        let original = #"{"numStartups": 5, "mcpServers": {"github": {"type": "stdio", "command": "gh"}}}"#
        let file = try write(original, to: ".claude.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let claude = AgentClient.claudeCode
        XCTAssertEqual(claude.status(key: "a", home: home), .notSetUp)

        try claude.install(key: "a", home: home)
        XCTAssertEqual(claude.status(key: "a", home: home), .setUp)
        let root = try json(file)
        XCTAssertEqual(root["numStartups"] as? Int, 5)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["github"] as? [String: Any])?["command"] as? String, "gh")
        let ours = try XCTUnwrap(servers["voiceiq"] as? [String: Any])
        XCTAssertEqual(ours["type"] as? String, "http")
        XCTAssertEqual(ours["url"] as? String, "http://127.0.0.1:47823/mcp")
        XCTAssertEqual((ours["headers"] as? [String: String])?["Authorization"], "Bearer a")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude.json.voiceiq-backup"), encoding: .utf8), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)

        XCTAssertEqual(claude.status(key: "b", home: home), .needsUpdate)
        try claude.install(key: "b", home: home)
        XCTAssertEqual(claude.status(key: "b", home: home), .setUp)

        try claude.remove(home: home)
        XCTAssertEqual(claude.status(key: "b", home: home), .notSetUp)
        XCTAssertEqual(try json(file)["mcpServers"] as? [String: [String: String]], ["github": ["type": "stdio", "command": "gh"]])
    }

    func testCodexReplacesOnlyItsOwnTables() throws {
        let file = try write("""
        model = "o4"

        [mcp_servers.github]
        command = "gh"

        [mcp_servers.voiceiq]
        url = "http://127.0.0.1:47823/mcp"
        http_headers = { Authorization = "Bearer old" }

        [mcp_servers.voiceiq.tools.get_meeting]
        approval_mode = "approve"

        [mcp_servers."voiceiq.backup"]
        url = "https://example.com/mcp"

        [profiles.fast]
        model = "mini"
        """, to: ".codex/config.toml")
        let codex = AgentClient.codex
        XCTAssertEqual(codex.status(key: "new", home: home), .needsUpdate)

        try codex.install(key: "new", home: home)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(codex.status(key: "new", home: home), .setUp)
        XCTAssertEqual(text.components(separatedBy: "[mcp_servers.voiceiq]").count, 2, text)
        XCTAssertFalse(text.contains("old") || text.contains("approval_mode"), text)
        XCTAssertTrue(text.hasPrefix("model = \"o4\"\n\n[mcp_servers.github]\ncommand = \"gh\"\n"), text)
        XCTAssertTrue(text.contains("[mcp_servers.\"voiceiq.backup\"]\nurl = \"https://example.com/mcp\"\n\n[profiles.fast]\nmodel = \"mini\"\n"), text)

        try codex.remove(home: home)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "model = \"o4\"\n\n[mcp_servers.github]\ncommand = \"gh\"\n\n"
                       + "[mcp_servers.\"voiceiq.backup\"]\nurl = \"https://example.com/mcp\"\n\n[profiles.fast]\nmodel = \"mini\"\n")
    }

    func testCodexQuotedTablesAndSharedFilePermissions() throws {
        let file = try write("""
        [mcp_servers.'voiceiq']
        url = "http://127.0.0.1:47823/mcp"
        http_headers = { Authorization = "Bearer old" }
        """, to: ".codex/config.toml")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try AgentClient.codex.install(key: "new", home: home)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "voiceiq").count, 2, text)
        XCTAssertEqual(AgentClient.codex.status(key: "new", home: home), .setUp)
        // The key must not stay readable by other accounts, nor the old one in the backup.
        let backup = home.appendingPathComponent(".codex/config.toml.voiceiq-backup")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)

        // A form it can't edit as a table is left alone rather than duplicated.
        let dotted = "[mcp_servers]\nvoiceiq = { url = \"http://127.0.0.1:47823/mcp\" }\n"
        try dotted.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentClient.codex.status(key: "new", home: home), .unreadable)
        try AgentClient.codex.install(key: "new", home: home)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), dotted)

        let inline = "mcp_servers = { other = { command = \"other-mcp\" } }\n"
        try inline.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentClient.codex.status(key: "new", home: home), .unreadable)
        try AgentClient.codex.install(key: "new", home: home)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), inline)
    }

    func testLeavesAloneWhatIsNotItsOwn() throws {
        XCTAssertEqual(AgentClient.amp.status(key: "a", home: home), .notInstalled)
        try AgentClient.amp.install(key: "a", home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/amp/settings.json").path))

        // Claude Code's state file is never created by VoiceiQ.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        XCTAssertEqual(AgentClient.claudeCode.status(key: "a", home: home), .notInstalled)

        let commented = "{\n  // mine\n  \"amp.showCosts\": false\n}\n"
        let amp = try write(commented, to: ".config/amp/settings.json")
        XCTAssertEqual(AgentClient.amp.status(key: "a", home: home), .unreadable)
        try AgentClient.amp.install(key: "a", home: home)
        XCTAssertEqual(try String(contentsOf: amp, encoding: .utf8), commented)

        let foreign = #"{"amp.mcpServers": {"voiceiq": {"url": "https://example.com/mcp"}}}"#
        _ = try write(foreign, to: ".config/amp/settings.json")
        XCTAssertEqual(AgentClient.amp.status(key: "a", home: home), .otherServer)
        try AgentClient.amp.install(key: "a", home: home)
        try AgentClient.amp.remove(home: home)
        XCTAssertEqual(try String(contentsOf: amp, encoding: .utf8), foreign)
    }

    func testAmpSetUpInAFreshConfigFolder() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/amp"), withIntermediateDirectories: true)
        try AgentClient.amp.install(key: "a", home: home)
        let file = home.appendingPathComponent(".config/amp/settings.json")
        let servers = try XCTUnwrap(try json(file)["amp.mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["voiceiq"]?["url"] as? String, "http://127.0.0.1:47823/mcp")
        XCTAssertNil(servers["voiceiq"]?["type"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }
}
