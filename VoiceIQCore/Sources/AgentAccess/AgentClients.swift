import Foundation

/// The coding agents VoiceiQ sets up by itself: it adds a `voiceiq` MCP
/// server to each one's user config, keeps its key current, and takes it out
/// again. It only touches a `voiceiq` entry whose URL is `AgentAPI.mcpURL`;
/// everything else in the file is kept. Before each change the file is copied
/// to `<name>.voiceiq-backup` next to it.
public enum AgentClient: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, codex, amp

    public static let serverName = "voiceiq"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .amp: "Amp"
        }
    }

    public enum Status: Equatable, Sendable {
        /// Its config folder isn't there: not installed, or never run.
        case notInstalled
        case notSetUp
        case setUp
        /// Set up with another key.
        case needsUpdate
        /// A `voiceiq` server pointing somewhere else, left alone.
        case otherServer
        /// The config is in a form VoiceiQ could not edit without losing something
        /// (JSON with comments, a settings.jsonc, a TOML `voiceiq` not written as a table), so it is left alone.
        case unreadable
    }

    /// Claude Code keeps user-scope MCP servers in `~/.claude.json`, Codex in
    /// `~/.codex/config.toml`, the Amp CLI in `~/.config/amp/settings.json`.
    public func configFile(home: URL) -> URL {
        switch self {
        case .claudeCode: home.appendingPathComponent(".claude.json")
        case .codex: home.appendingPathComponent(".codex/config.toml")
        case .amp: home.appendingPathComponent(".config/amp/settings.json")
        }
    }

    /// What each tool creates on its first run. Claude Code's `.claude.json`
    /// holds its whole state, so VoiceiQ never creates that one.
    private func isInstalled(home: URL) -> Bool {
        let marker = switch self {
        case .claudeCode: ".claude.json"
        case .codex: ".codex"
        case .amp: ".config/amp"
        }
        return FileManager.default.fileExists(atPath: home.appendingPathComponent(marker).path)
    }

    public func status(key: String, home: URL) -> Status {
        guard isInstalled(home: home) else { return .notInstalled }
        if self == .amp, !exists(configFile(home: home)),
           exists(home.appendingPathComponent(".config/amp/settings.jsonc")) {
            return .unreadable
        }
        let entry: Entry?
        do { entry = try currentEntry(home: home) } catch { return .unreadable }
        switch entry {
        case nil: return .notSetUp
        case .other?: return .otherServer
        case .ours(let entryKey)?: return entryKey == key ? .setUp : .needsUpdate
        }
    }

    /// Adds the server or updates its key. Does nothing when it is already
    /// current, or when the tool isn't installed or its config can't be edited.
    public func install(key: String, home: URL) throws {
        guard [.notSetUp, .needsUpdate].contains(status(key: key, home: home)) else { return }
        try write(home: home) { text in
            switch self {
            case .codex:
                let rest = Self.tomlRemovingOurs(text)
                return rest + (rest.isEmpty || rest.hasSuffix("\n") ? "" : "\n") + Self.tomlEntry(key: key)
            case .claudeCode, .amp:
                return try self.editingJSON(text) { $0[Self.serverName] = self.jsonEntry(key: key) }
            }
        }
    }

    /// Takes out VoiceiQ's server, if it is there.
    public func remove(home: URL) throws {
        guard case .ours? = try? currentEntry(home: home) else { return }
        try write(home: home) { text in
            switch self {
            case .codex: return Self.tomlRemovingOurs(text)
            case .claudeCode, .amp: return try self.editingJSON(text) { $0[Self.serverName] = nil }
            }
        }
    }

    // MARK: - Reading

    private enum Entry: Equatable {
        case ours(key: String?)
        case other
    }

    /// Nil when there is no `voiceiq` server. Throws when the file can't be parsed.
    private func currentEntry(home: URL) throws -> Entry? {
        let file = configFile(home: home)
        guard exists(file) else { return nil }
        let text = try String(contentsOf: file, encoding: .utf8)
        let url: String?, authorization: String?
        switch self {
        case .codex:
            // MCP servers, or `voiceiq` itself, written as dotted keys or inline
            // tables rather than as `[mcp_servers.<name>]` tables: appending a
            // table would clash with them, so this form is left alone.
            if Self.tomlRemovingOurs(text).range(of: #"(?m)^\s*(mcp_servers|"mcp_servers"|'mcp_servers'|voiceiq|"voiceiq"|'voiceiq')\s*[.=]"#,
                                                  options: .regularExpression) != nil {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard let block = Self.tomlOurBlock(text) else { return nil }
            url = Self.tomlString("url", in: block)
            authorization = Self.tomlString("Authorization", in: block)
        case .claudeCode, .amp:
            let root = try Self.jsonObject(text)
            guard let entry = (root[containerKey] as? [String: Any])?[Self.serverName] as? [String: Any] else { return nil }
            url = entry["url"] as? String
            authorization = (entry["headers"] as? [String: Any])?["Authorization"] as? String
        }
        guard url == AgentAPI.mcpURL else { return .other }
        return .ours(key: authorization.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil })
    }

    private func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    // MARK: - Writing

    private func write(home: URL, _ edit: (String) throws -> String) throws {
        let file = configFile(home: home)
        let fileManager = FileManager.default
        let old = exists(file) ? try String(contentsOf: file, encoding: .utf8) : nil
        let new = try edit(old ?? "")
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The key is a secret, and the backup may hold the old one: both are
        // left readable by the user alone, whatever the file allowed before.
        let existing = (try? fileManager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0o600
        let permissions = existing & 0o700
        if old != nil {
            let backup = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".voiceiq-backup")
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: file, to: backup)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: backup.path)
        }
        try Data(new.utf8).write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
    }

    // MARK: - JSON (Claude Code, Amp)

    private var containerKey: String { self == .amp ? "amp.mcpServers" : "mcpServers" }

    private func jsonEntry(key: String) -> [String: Any] {
        var entry: [String: Any] = ["url": AgentAPI.mcpURL, "headers": ["Authorization": "Bearer \(key)"]]
        if self == .claudeCode { entry["type"] = "http" }
        return entry
    }

    private func editingJSON(_ text: String, _ change: (inout [String: Any]) -> Void) throws -> String {
        var root = try Self.jsonObject(text)
        var servers = root[containerKey] as? [String: Any] ?? [:]
        change(&servers)
        root[containerKey] = servers.isEmpty ? nil : servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func jsonObject(_ text: String) throws -> [String: Any] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    // MARK: - TOML (Codex)

    private static func tomlEntry(key: String) -> String {
        "\n[mcp_servers.\(serverName)]\nurl = \"\(AgentAPI.mcpURL)\"\nhttp_headers = { Authorization = \"Bearer \(key)\" }\n"
    }

    /// The key path of a TOML table header line, such as `["mcp_servers", "voiceiq.backup"]`
    /// for `[mcp_servers."voiceiq.backup"]`; nil for other lines. Quoted parts keep their dots.
    private static func tomlTable(_ line: String) -> [String]? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        guard rest.popFirst() == "[" else { return nil }
        let isArray = rest.first == "["
        if isArray { rest.removeFirst() }
        var path: [String] = [], part = "", quote: Character?
        while let character = rest.popFirst() {
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"", let escaped = rest.popFirst() {
                    part.append(escaped)
                } else {
                    part.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." || character == "]" {
                path.append(part.trimmingCharacters(in: .whitespaces))
                part = ""
                guard character == "]" else { continue }
                if isArray, rest.popFirst() != "]" { return nil }
                let after = rest.trimmingCharacters(in: .whitespaces)
                return (after.isEmpty || after.hasPrefix("#")) && !path.contains("") ? path : nil
            } else {
                part.append(character)
            }
        }
        return nil
    }

    private static func isOurs(_ table: [String]) -> Bool {
        table.count >= 2 && table[0] == "mcp_servers" && table[1] == serverName
    }

    /// The lines of `[mcp_servers.voiceiq]` and its sub-tables, nil when there are none.
    private static func tomlOurBlock(_ text: String) -> String? {
        var inside = false, lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let table = tomlTable(line) { inside = isOurs(table) }
            if inside { lines.append(line) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func tomlRemovingOurs(_ text: String) -> String {
        var inside = false, kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let table = tomlTable(line) { inside = isOurs(table) }
            if !inside { kept.append(line) }
        }
        var result = kept.joined(separator: "\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }

    /// The first `name = "value"` in `block`, also inside an inline table.
    private static func tomlString(_ name: String, in block: String) -> String? {
        let pattern = "(?:^|[\\s{,])\"?\(name)\"?\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block) else { return nil }
        return String(block[range])
    }
}
