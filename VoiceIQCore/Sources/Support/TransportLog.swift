import Foundation

/// One model request attempt, as the network stack saw it.
public struct TransportEvent: Codable, Equatable, Sendable {
    public var at: Date
    /// Sent as `X-Client-Request-Id`; the same on every attempt of one call.
    public var requestID: String
    public var attempt: Int
    public var stage: String
    public var model: String
    public var host: String?
    /// "h2", "h3", "http/1.1"; nil when no transaction started.
    public var networkProtocol: String?
    public var reusedConnection: Bool?
    public var connectMs: Int?
    /// Request start to first response byte.
    public var firstByteMs: Int?
    public var totalMs: Int
    public var requestBytes: Int64?
    public var responseBytes: Int64?
    public var status: Int?
    /// "ok", "http_<status>", "timeout", "connection_lost", "offline", "url_<code>", "cancelled".
    public var outcome: String
}

/// Every model request attempt, one JSON object per line, in
/// `transport.jsonl` next to the history database.
///
/// The unified log keeps CFNetwork's per-request summaries for about a day,
/// which was too short to investigate the 09-27/09-28 cleanup misses. This file
/// keeps the same facts (protocol, reuse, timings, bytes, outcome) for as long
/// as it stays under its size cap. It holds no request or response content.
public enum TransportLog {
    static let maxBytes = 2_000_000
    private static let queue = DispatchQueue(label: "io.blue.voiceiq.transport-log")

    public static var fileURL: URL { FileLayout.appSupportRoot.appendingPathComponent("transport.jsonl") }
    static var previousURL: URL { FileLayout.appSupportRoot.appendingPathComponent("transport.1.jsonl") }

    public static func record(_ event: TransportEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        let url = fileURL, previous = previousURL, payload = line
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: url, to: previous)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: payload)
            } else {
                try? payload.write(to: url, options: .atomic)
            }
        }
    }

    /// Waits for queued writes; tests read the file right after a request.
    static func flush() { queue.sync {} }
}
