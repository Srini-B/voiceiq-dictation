import Foundation

/// What a dictation produces. Mirrors the macOS dictation key, ⌃⌥T and ⌃⌥A.
public enum KeyboardMode: String, Codable, CaseIterable, Sendable {
    case dictate
    case translate
    case ask

    public var title: String {
        switch self {
        case .dictate: return "Dictate"
        case .translate: return "Translate"
        case .ask: return "Ask"
        }
    }

    public var symbol: String {
        switch self {
        case .dictate: return "mic.fill"
        case .translate: return "globe"
        case .ask: return "sparkles"
        }
    }
}

/// One request from the keyboard. Only the keyboard writes these.
public struct KeyboardCommand: Codable, Equatable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable {
        case start
        case stop
        case cancel
    }

    public let id: UUID
    public let action: Action
    public let issuedAt: Date
    public var mode: KeyboardMode
    /// Selected text, or the text before the cursor, for Ask.
    public var context: String?
    /// The app the keyboard was typing in, when it could be resolved.
    public var hostBundleID: String?

    public init(
        id: UUID = UUID(),
        action: Action,
        issuedAt: Date = Date(),
        mode: KeyboardMode = .dictate,
        context: String? = nil,
        hostBundleID: String? = nil
    ) {
        self.id = id
        self.action = action
        self.issuedAt = issuedAt
        self.mode = mode
        self.context = context
        self.hostBundleID = hostBundleID
    }

    /// A command older than this is never acted on: the keyboard gave up on it
    /// and the user has moved on.
    public static let maximumAge: TimeInterval = 30

    public func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(issuedAt) < Self.maximumAge
    }
}

/// A finished result waiting for the keyboard to insert or show it.
public struct Delivery: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let mode: KeyboardMode
    public let text: String
    public let createdAt: Date
    public let hostBundleID: String?

    public init(id: UUID = UUID(), mode: KeyboardMode, text: String, createdAt: Date = Date(), hostBundleID: String?) {
        self.id = id
        self.mode = mode
        self.text = text
        self.createdAt = createdAt
        self.hostBundleID = hostBundleID
    }
}

/// A short message the keyboard shows instead of a result.
public struct Notice: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// The app's session as the keyboard and the Live Activity see it. Only the
/// app writes this.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// No background session. The next mic tap opens the app once.
        case off
        /// Session alive, mic off. The next mic tap records in place.
        case warm
        case recording
        case processing
    }

    public var phase: Phase
    public var mode: KeyboardMode
    public var recordingStartedAt: Date?
    public var delivery: Delivery?
    public var notice: Notice?
    public var meetingActive: Bool

    public init(
        phase: Phase = .off,
        mode: KeyboardMode = .dictate,
        recordingStartedAt: Date? = nil,
        delivery: Delivery? = nil,
        notice: Notice? = nil,
        meetingActive: Bool = false
    ) {
        self.phase = phase
        self.mode = mode
        self.recordingStartedAt = recordingStartedAt
        self.delivery = delivery
        self.notice = notice
        self.meetingActive = meetingActive
    }
}

/// The keyboard's recording glow: one height per microphone level the app
/// samples, newest last. The app keeps it, so a keyboard that appears in the
/// middle of a dictation shows what came before instead of starting empty.
public struct LevelBars: Sendable {
    public static let capacity = 256
    public private(set) var heights: [Float] = []
    private var smoothed: Float = 0

    public init() {}

    public mutating func append(_ level: Float) {
        // A NaN would stick in `smoothed`, and `SharedStore.levelBars` traps converting it.
        guard level.isFinite else { return }
        let target = min(max(level, 0), 1)
        // Fast attack, slow release: syllables jump up and fall back gently.
        smoothed += (target - smoothed) * (target > smoothed ? 0.7 : 0.3)
        // The level saturates for close or loud speech; this spreads the top
        // of the range so loud speech still rises and falls.
        heights.append(pow(smoothed, 1.4))
        if heights.count > Self.capacity { heights.removeFirst(heights.count - Self.capacity) }
    }
}

/// A button pressed in the Live Activity. Its intents run in the app process.
public struct ActivityRequest: Codable, Equatable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable {
        case stopDictation
        case endSession
        case stopMeeting
    }

    public let id: UUID
    public let action: Action
    public let issuedAt: Date

    public init(id: UUID = UUID(), action: Action, issuedAt: Date = Date()) {
        self.id = id
        self.action = action
        self.issuedAt = issuedAt
    }
}

/// A word the keyboard asked the app to add to the dictionary.
public struct DictionaryAddition: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let term: String
    public let createdAt: Date

    public init(id: UUID = UUID(), term: String, createdAt: Date = Date()) {
        self.id = id
        self.term = term
        self.createdAt = createdAt
    }

    /// What the keyboard offers to add: one line, 1–60 characters after
    /// trimming, the dictionary's own limit. Nil otherwise.
    public static func candidate(from text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...60).contains(trimmed.count), !trimmed.contains(where: \.isNewline) else { return nil }
        return trimmed
    }
}
