import Foundation

/// The debug log the user turns on in Settings › Advanced: one line for
/// everything the app logs (`Log` in VoiceIQCore sends each message here),
/// plus the keyboard, the Chrome extension's host and every network request,
/// so a user can send support one file.
///
/// Each process writes its own file per day, `debug-<day>-<process>.log`
/// (Chrome hosts add their process id), so
/// two processes never write the same file. Files older than `keepDays` days
/// go, and the oldest go first once all of them pass `maxTotalBytes`.
/// API keys and tokens are removed from every line before it is written.
public enum DebugLog {
    public static let keepDays = 7
    public static let maxTotalBytes = 30_000_000

    /// Test hook, like `FileLayout.overrideRoot`.
    nonisolated(unsafe) public static var overrideFolder: URL?

    private static let enabledKey = "debugLogEnabled"
    private static let queue = DispatchQueue(label: "io.blue.voiceiq.debug-log")
    nonisolated(unsafe) private static var prunedDay: String?
    /// Bytes this process appended since its last prune, so a busy day stays
    /// under `maxTotalBytes` too.
    nonisolated(unsafe) private static var bytesSincePrune = 0
    nonisolated(unsafe) private static var wroteLaunchLine = false
    private static let secretsLock = NSLock()
    nonisolated(unsafe) private static var secrets: Set<String> = []

    // MARK: - On or off

    /// iOS: the App Group, so the keyboard follows the app's switch. Mac: the
    /// app's own defaults, which the Chrome host reads by name.
    private static let defaults: UserDefaults = {
        #if os(iOS)
        return UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard
        #else
        let app = "io.blue.voiceiq"
        return Bundle.main.bundleIdentifier == app ? .standard : (UserDefaults(suiteName: app) ?? .standard)
        #endif
    }()

    public static var isEnabled: Bool { defaults.bool(forKey: enabledKey) }

    public static func setEnabled(_ on: Bool) {
        if on {
            defaults.set(true, forKey: enabledKey)
            write(level: "info", category: "debug-log", "debug log turned on")
        } else {
            write(level: "info", category: "debug-log", "debug log turned off")
            defaults.set(false, forKey: enabledKey)
        }
    }

    // MARK: - Writing

    /// Appends one line when the log is on. Newlines in `message` are folded
    /// so each entry stays one line.
    public static func write(level: String, category: String, _ message: @autoclosure () -> String) {
        guard isEnabled, let folder else { return }
        let now = Date(), text = message()
        queue.async {
            let day = dayFormatter.string(from: now)
            if prunedDay != day || bytesSincePrune > 1_000_000 {
                prunedDay = day
                bytesSincePrune = 0
                pruneOnQueue(folder: folder, now: now)
            }
            var lines = ""
            if !wroteLaunchLine {
                wroteLaunchLine = true
                lines += line(now, "info", "launch", launchDescription)
            }
            lines += line(now, level, category, redact(text))
            bytesSincePrune += lines.utf8.count
            append(lines, to: folder.appendingPathComponent("debug-\(day)-\(fileProcess).log"))
        }
    }

    /// Waits for queued lines; a process calls it before it exits.
    public static func flush() { queue.sync {} }

    private static func line(_ date: Date, _ level: String, _ category: String, _ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: " ⏎ ").replacingOccurrences(of: "\n", with: " ⏎ ")
        return "\(stampFormatter.string(from: date)) \(process) \(level) [\(category)] \(flat)\n"
    }

    private static func append(_ text: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: url.path) || fm.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Secrets

    /// A key the app holds, removed wherever it appears. `KeychainStore`
    /// registers every key it loads or saves, so a key in an unknown format
    /// is caught too.
    public static func registerSecret(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return }
        secretsLock.lock(); secrets.insert(trimmed); secretsLock.unlock()
    }

    private static let patterns: [(NSRegularExpression, String)] = [
        (#"AIza[0-9A-Za-z_\-]{30,}"#, "[redacted]"),
        (#"\bsk-[A-Za-z0-9_\-]{12,}"#, "[redacted]"),
        (#"\bsk_[A-Za-z0-9]{16,}"#, "[redacted]"),
        (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*"#, "[redacted]"),
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=\-]{8,}"#, "$1 [redacted]"),
        (#"(?i)\b(api[_-]?key|x-goog-api-key|xi-api-key|x-api-key|access[_-]?token|refresh[_-]?token|client[_-]?secret|token|secret|password|passwd|authorization|signature|sig|key)(\s*["']?\s*[:=]\s*["']?)(?!\[redacted\])[^\s"'&,;}\]]{4,}"#, "$1$2[redacted]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// `text` without the keys this process holds, API keys of the formats
    /// the providers issue, bearer tokens, JWTs, and the values of
    /// `key=`/`token:`-style pairs.
    public static func redact(_ text: String) -> String {
        secretsLock.lock(); let known = secrets; secretsLock.unlock()
        var result = text
        for secret in known where result.contains(secret) {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        for (regex, template) in patterns {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    // MARK: - Reading

    public static var folder: URL? { overrideFolder ?? defaultFolder }

    private static let defaultFolder: URL? = {
        #if os(iOS)
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID)?
            .appendingPathComponent("Library", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        #endif
        return base?.appendingPathComponent("Logs/VoiceiQ", isDirectory: true)
    }()

    private static func files(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("debug-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    public static var totalBytes: Int {
        queue.sync { folder.map { files(in: $0).reduce(0) { $0 + size($1) } } ?? 0 }
    }

    /// Every process's lines, oldest first. A line starts with its time, so
    /// sorting by that prefix interleaves the processes.
    private static func mergedLines(_ urls: [URL]) -> [Substring] {
        let lines = urls.flatMap { url -> [Substring] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n")
        }
        return lines.enumerated().sorted {
            let a = $0.element.prefix(23), b = $1.element.prefix(23)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }

    /// The newest `limit` lines, from the most recent days only.
    public static func recentLines(limit: Int) -> [String] {
        queue.sync {
            guard let folder else { return [] }
            var lines: [Substring] = []
            let byDay = Dictionary(grouping: files(in: folder)) { $0.lastPathComponent.dropFirst(6).prefix(10) }
            for day in byDay.keys.sorted(by: >) where lines.count < limit {
                lines = mergedLines(byDay[day] ?? []) + lines
            }
            return lines.suffix(limit).map(String.init)
        }
    }

    /// One file with every day kept, oldest line first, under a header that
    /// names the build and device. For a share sheet or a save panel. Each
    /// export is its own copy, in its own folder; `discardExport` removes it.
    public static func export(now: Date = Date()) throws -> URL {
        let body: [Substring] = queue.sync { folder.map { mergedLines(files(in: $0)) } ?? [] }
        let exported = DateFormatter()
        exported.locale = Locale(identifier: "en_US_POSIX")
        exported.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        let header = """
        VoiceiQ debug log
        Exported \(exported.string(from: now)); times below are in this time zone.
        \(launchDescription)
        Keeps the last \(keepDays) days, up to \(maxTotalBytes / 1_000_000) MB. API keys and tokens are removed; text the app marks private (transcripts, window titles, page addresses) is never written.

        """
        let name = "VoiceiQ-debug-log-\(dayFormatter.string(from: now))-\(Int(now.timeIntervalSince1970)).txt"
        let exportFolder = exportsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let url = exportFolder.appendingPathComponent(name)
        try Data((header + body.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        return url
    }

    /// Removes a file `export` made.
    public static func discardExport(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static var exportsFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("debug-log-exports", isDirectory: true)
    }

    // MARK: - Removing

    public static func clear() {
        queue.sync {
            guard let folder else { return }
            for url in files(in: folder) { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: exportsFolder)
            wroteLaunchLine = false
        }
    }

    /// Runs at launch from `RetentionPolicy.purge` and on each process's first
    /// line of a day, so days go even while the log stays off.
    public static func prune(now: Date = Date()) {
        queue.async { if let folder { pruneOnQueue(folder: folder, now: now) } }
    }

    private static func pruneOnQueue(folder: URL, now: Date) {
        let oldestKept = dayFormatter.string(from: now.addingTimeInterval(-Double(keepDays - 1) * 86_400))
        var kept: [(url: URL, size: Int)] = []
        for url in files(in: folder) {
            if String(url.lastPathComponent.dropFirst(6).prefix(10)) < oldestKept {
                try? FileManager.default.removeItem(at: url)
            } else {
                kept.append((url, size(url)))
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for file in kept where total > maxTotalBytes {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    // MARK: - Facts

    /// "app", "keyboard" or "chrome-host": which process wrote a line.
    static let process: String = {
        switch Bundle.main.bundleIdentifier {
        case "io.blue.voiceiq", "io.blue.voiceiq.ios": return "app"
        case "io.blue.voiceiq.ios.keyboard": return "keyboard"
        case "io.blue.voiceiq.localspeech": return "chrome-host"
        case let id?: return id.split(separator: ".").last.map(String.init) ?? id
        case nil: return ProcessInfo.processInfo.processName
        }
    }()

    /// `process` in the file name. Chrome starts one host per profile, so
    /// each host process writes its own file.
    static let fileProcess = process == "chrome-host" ? "chrome-host-\(ProcessInfo.processInfo.processIdentifier)" : process

    static let launchDescription: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let system = "iOS"
        #elseif os(macOS)
        let system = "macOS"
        #else
        let system = "OS"
        #endif
        return "VoiceiQ \(version) (\(build)), \(system) \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(model), \(process) pid \(ProcessInfo.processInfo.processIdentifier)"
    }()

    private static var model: String {
        #if canImport(Darwin)
        #if os(iOS)
        let name = "hw.machine"
        #else
        let name = "hw.model"
        #endif
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &bytes, &size, nil, 0)
        return String(cString: bytes)
        #else
        return "unknown device"
        #endif
    }

    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let stampFormatter = formatter("yyyy-MM-dd HH:mm:ss.SSS")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
