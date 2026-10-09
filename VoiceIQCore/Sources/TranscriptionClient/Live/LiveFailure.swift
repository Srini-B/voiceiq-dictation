import Foundation
import CryptoKit

/// Provider details survive decoding so billing refusals are not retried as RPM limits.
public struct LiveFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var status: Int?
    public var code: String
    public var message: String
    public var retryAfter: TimeInterval?

    public init(status: Int? = nil, code: String = "", message: String, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }

    public var description: String { "\(status.map(String.init) ?? "") \(code): \(message)" }

    enum Recovery: Equatable {
        case retry, dailyQuota, configuration, billing
    }

    var recovery: Recovery {
        let text = (code + " " + message).lowercased()
        if status == 402 || ["insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded",
                            "project_spend_limit_exceeded", "organization_usage_limit_exceeded"].contains(where: text.contains) {
            return .billing
        }
        if ["per_day", "perday", "per day", "daily", "requestsperday"].contains(where: text.contains) {
            return .dailyQuota
        }
        if status.map({ [400, 401, 403, 404, 413].contains($0) }) == true ||
            ["invalid_request_error", "invalid_argument", "unauthenticated", "permission_denied", "not_found",
             "api_key_invalid", "invalid_api_key", "model_not_found", "websocket_1008", "websocket_1009"].contains(where: text.contains) {
            return .configuration
        }
        return .retry
    }

    static func decode(_ node: Any?) -> LiveFailure {
        let error = node as? [String: Any] ?? [:]
        let details = error["details"] as? [[String: Any]] ?? []
        let retry = details.compactMap { $0["retryDelay"] as? String }.compactMap(duration).max()
        var code = error["code"] as? String ?? error["status"] as? String ?? error["type"] as? String ?? ""
        let violations = details.flatMap { $0["violations"] as? [[String: Any]] ?? [] }
        let quotaIDs = violations.compactMap { $0["quotaId"] as? String }
        if !quotaIDs.isEmpty { code += " " + quotaIDs.joined(separator: " ") }
        return LiveFailure(status: error["code"] as? Int, code: code,
                           message: error["message"] as? String ?? "Live request refused", retryAfter: retry)
    }

    static func duration(_ value: String) -> TimeInterval? {
        guard let seconds = Double(value.hasSuffix("s") ? String(value.dropLast()) : value),
              seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = duration(value) { return seconds }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return format.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// Local admission control, not a guess at the account's project-wide allowance.
final class LiveAvailability: @unchecked Sendable {
    static let shared = LiveAvailability()
    private struct Entry { var failures = 0; var until = Date.distantPast }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    static func identity(model: String, key: String) -> String {
        model + ":" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func allows(_ identity: String, now: Date = Date()) -> Bool {
        lock.withLock { (entries[identity]?.until ?? .distantPast) <= now }
    }

    func resetRefusals() {
        lock.withLock { entries = entries.filter { $0.value.until != .distantFuture } }
    }

    func refused(_ failure: LiveFailure, identity: String, now: Date = Date()) {
        lock.withLock {
            var entry = entries[identity] ?? Entry()
            entry.failures += 1
            let delay: TimeInterval
            switch failure.recovery {
            case .configuration, .billing:
                entry.until = .distantFuture
                entries[identity] = entry
                return
            case .dailyQuota:
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
                delay = (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)).timeIntervalSince(now)
            case .retry:
                delay = min(900, 60 * pow(2, Double(min(entry.failures - 1, 4)))) + Double.random(in: 0...5)
            }
            entry.until = max(entry.until, now.addingTimeInterval(max(delay, failure.retryAfter ?? 0)))
            entries[identity] = entry
        }
    }
}
