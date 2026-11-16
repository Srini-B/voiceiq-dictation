import os
import VoiceIQBridge

/// Central loggers, one per subsystem area. Subsystem matches the app bundle id.
/// Each message goes to the unified log and, while the user has it on, to
/// the debug log (`DebugLog`).
public enum Log {
    public static let subsystem = "io.blue.voiceiq"

    public static let session = LogChannel("session")
    public static let hotkey = LogChannel("hotkey")
    public static let audio = LogChannel("audio")
    public static let transcription = LogChannel("transcription")
    public static let insertion = LogChannel("insertion")
    public static let learning = LogChannel("learning")
    public static let history = LogChannel("history")
    public static let meeting = LogChannel("meeting")
    public static let screen = LogChannel("screen")
    public static let permissions = LogChannel("permissions")
    public static let ui = LogChannel("ui")
    public static let usage = LogChannel("usage")
}

/// `Logger`'s calls, for messages written the same way:
/// `Log.audio.info("started on \(name, privacy: .public)")`.
public struct LogChannel: Sendable {
    public let category: String
    private let logger: Logger

    public init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: Log.subsystem, category: category)
    }

    public func debug(_ message: LogMessage) { emit(.debug, "debug", message) }
    public func info(_ message: LogMessage) { emit(.info, "info", message) }
    public func notice(_ message: LogMessage) { emit(.default, "notice", message) }
    public func warning(_ message: LogMessage) { emit(.error, "warning", message) }
    public func error(_ message: LogMessage) { emit(.error, "error", message) }
    public func fault(_ message: LogMessage) { emit(.fault, "fault", message) }

    private func emit(_ type: OSLogType, _ level: String, _ message: LogMessage) {
        logger.log(level: type, "\(message.unified, privacy: .public)")
        DebugLog.write(level: level, category: category, message.debug)
    }
}

/// How a value shows, as with `OSLogPrivacy`. `.auto` hides all but numbers
/// and Bools in the unified log, like `Logger`; the debug log shows it with
/// keys removed. `.private` never leaves the process.
public enum LogPrivacy: Sendable {
    case `public`, `private`, auto
}

public enum LogNumberFormat: Sendable {
    case fixed(precision: Int)
}

/// A log line built from a string literal, with `Logger`'s interpolations:
/// `privacy:`, and `format: .fixed(precision:)` for floating-point values.
public struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    /// For the unified log.
    let unified: String
    /// For the debug log.
    let debug: String

    public init(stringLiteral value: String) {
        unified = value
        debug = value
    }

    public init(stringInterpolation: StringInterpolation) {
        unified = stringInterpolation.unified
        debug = stringInterpolation.debug
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var unified = ""
        var debug = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            unified.reserveCapacity(literalCapacity + interpolationCount * 8)
            debug.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) {
            unified += literal
            debug += literal
        }

        public mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .auto) {
            append(String(describing: value), privacy: privacy, isNumber: value is any BinaryInteger || value is any BinaryFloatingPoint || value is Bool)
        }

        public mutating func appendInterpolation<F: BinaryFloatingPoint>(_ value: F, format: LogNumberFormat, privacy: LogPrivacy = .auto) {
            switch format {
            case .fixed(let precision):
                append(String(format: "%.\(precision)f", Double(value)), privacy: privacy, isNumber: true)
            }
        }

        private mutating func append(_ text: String, privacy: LogPrivacy, isNumber: Bool) {
            switch privacy {
            case .public:
                unified += text
                debug += text
            case .private:
                unified += "<private>"
                debug += "<private>"
            case .auto:
                unified += isNumber ? text : "<private>"
                debug += text
            }
        }
    }
}
