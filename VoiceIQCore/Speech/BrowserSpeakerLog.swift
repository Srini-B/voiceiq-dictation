import Foundation

/// Who is talking in a browser meeting, as the VoiceiQ Meetings Chrome
/// extension sees it: the call's WebRTC audio sources that are loud right
/// now. Each source is one participant: Meet and Teams mix people into a few
/// streams and name each person by a contributing source (CSRC); other
/// services send one stream (SSRC) per person. The page's layout plays no part,
/// so a shared screen, a background tab, or another window in front change nothing.
public struct BrowserSpeakerEvent: Codable, Equatable, Sendable {
    /// Unix time in milliseconds.
    public var t: Double
    /// Host and path of the meeting page, such as `meet.google.com/abc-defg-hij`.
    public var page: String
    public var tab: Int
    /// The sources loud at `t`, such as `csrc:3141` or `ssrc:2718`. Empty when nobody is.
    public var active: [String]

    public init(t: Double, page: String, tab: Int, active: [String]) {
        self.t = t; self.page = page; self.tab = tab; self.active = active
    }
}

/// The extension's events, one JSON line each, in a file per day. The native
/// messaging host appends; the app reads a meeting's stretch when it stops.
public enum BrowserSpeakerLog {
    public static func folder(root: URL? = nil) -> URL {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceiQ", isDirectory: true)
        return base.appendingPathComponent("browser-speakers", isDirectory: true)
    }

    static func file(for time: Date, root: URL?) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.dateComponents([.year, .month, .day], from: time)
        let name = String(format: "%04d-%02d-%02d.jsonl", day.year!, day.month!, day.day!)
        return folder(root: root).appendingPathComponent(name)
    }

    public static func append(_ event: BrowserSpeakerEvent, root: URL? = nil) throws {
        let url = file(for: Date(timeIntervalSince1970: event.t / 1000), root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONEncoder().encode(event) + Data("\n".utf8))
    }

    /// Events between two times, from every day file they span. A line that
    /// does not decode (a write cut short) is skipped.
    public static func events(from start: Date, to end: Date, root: URL? = nil) -> [BrowserSpeakerEvent] {
        var urls: [URL] = [], day = start
        while day <= end.addingTimeInterval(86_400) {
            let url = file(for: day, root: root)
            if !urls.contains(url) { urls.append(url) }
            day = day.addingTimeInterval(86_400)
        }
        let range = (start.timeIntervalSince1970 * 1000)...(end.timeIntervalSince1970 * 1000)
        let decoder = JSONDecoder()
        return urls.flatMap { url -> [BrowserSpeakerEvent] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? decoder.decode(BrowserSpeakerEvent.self, from: Data($0.utf8)) }
        }
        .filter { range.contains($0.t) }
        .sorted { $0.t < $1.t }
    }

    /// Day files older than a week: their meetings have copied what they need.
    public static func prune(olderThan days: Int = 7, root: URL? = nil, now: Date = Date()) {
        let folder = folder(root: root), cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}
