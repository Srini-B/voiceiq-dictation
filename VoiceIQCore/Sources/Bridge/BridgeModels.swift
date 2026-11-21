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
    /// A stop's start command: the stop ends only the dictation that start
    /// began, once it records (a hold on the dictation key released early).
    public var startID: UUID?

    public init(
        id: UUID = UUID(),
        action: Action,
        issuedAt: Date = Date(),
        mode: KeyboardMode = .dictate,
        context: String? = nil,
        hostBundleID: String? = nil,
        startID: UUID? = nil
    ) {
        self.id = id
        self.action = action
        self.issuedAt = issuedAt
        self.mode = mode
        self.context = context
        self.hostBundleID = hostBundleID
        self.startID = startID
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
        // The level as is: `AudioLevelCurve` already puts ordinary speech in
        // the upper half. Raising it to 1.4 here kept speech under 40%.
        heights.append(smoothed)
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

/// A dictation's result held for the next keyboard (as anomalyco/hex #2163
/// does): typed into the same field within `insertWindow`, otherwise offered
/// in the suggestion strip until `offerWindow` runs out.
public struct HeldDictation: Codable, Equatable, Sendable {
    public static let insertWindow: TimeInterval = 30
    public static let offerWindow: TimeInterval = 600

    public enum Delivery: Equatable, Sendable { case insert, offer, expired }

    public var id: UUID
    public var text: String
    public var mode: KeyboardMode
    /// The field it was started in (`UITextDocumentProxy.documentIdentifier`).
    public var document: UUID?
    /// The app it was started in, and the text before the cursor when the
    /// keyboard hid: iOS names the field anew when its app comes back, so
    /// these tell the same field apart from another.
    public var host: String?
    public var textBefore: String?
    public var finishedAt: Date

    public init(id: UUID = UUID(), text: String, mode: KeyboardMode, document: UUID?,
                host: String? = nil, textBefore: String? = nil, finishedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.mode = mode
        self.document = document
        self.host = host
        self.textBefore = textBefore
        self.finishedAt = finishedAt
    }

    /// Where the keyboard is now: its field, app, and text before the cursor.
    /// Typed only when the field is surely the same: both sides name it and
    /// the names match, or (iOS renames a field when its app returns, and
    /// may not name it at all while focus moves) the app is the same and so
    /// is the text before the cursor, which must not be empty. Anything less
    /// certain is offered, never typed.
    public func delivery(in document: UUID?, host: String? = nil, textBefore: String? = nil, at now: Date = Date()) -> Delivery {
        let age = now.timeIntervalSince(finishedAt)
        guard age < Self.offerWindow else { return .expired }
        let sameID = self.document != nil && self.document == document
        let sameContext = self.host != nil && self.host == host
            && !(self.textBefore ?? "").isEmpty && self.textBefore == textBefore
        return (sameID || sameContext) && age < Self.insertWindow ? .insert : .offer
    }
}
