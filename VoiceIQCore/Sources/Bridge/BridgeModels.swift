import Foundation

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
    /// The app the keyboard was typing in, when it could be resolved.
    public var hostBundleID: String?
    /// The input session the keyboard was in (`FieldIdentity.documentID`).
    public var documentID: UUID?
    /// The text around the cursor then (`FieldIdentity.draft`).
    public var draft: String?
    /// The text around the cursor then, for the writing model to fit the
    /// dictation to (`SurroundingText.excerpt`). Nil when the keyboard
    /// could not read it.
    public var surroundingText: SurroundingText?

    public init(
        id: UUID = UUID(),
        action: Action,
        issuedAt: Date = Date(),
        field: FieldIdentity? = nil,
        surroundingText: SurroundingText? = nil
    ) {
        self.id = id
        self.action = action
        self.issuedAt = issuedAt
        self.hostBundleID = field?.hostBundleID
        self.documentID = field?.documentID
        self.draft = field?.draft
        self.surroundingText = surroundingText?.excerpt
    }

    /// Where the keyboard was when it sent this. Nil from a keyboard that
    /// could name neither the app nor the session.
    public var field: FieldIdentity? {
        hostBundleID == nil && documentID == nil
            ? nil : FieldIdentity(hostBundleID: hostBundleID, documentID: documentID, draft: draft)
    }

    /// A command older than this is never acted on: the keyboard gave up on it
    /// and the user has moved on.
    public static let maximumAge: TimeInterval = 30

    public func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(issuedAt) < Self.maximumAge
    }
}

/// What a VoiceiQ keyboard can tell about the field it is typing into. iOS
/// gives a keyboard no identity for a text field, so whether two readings
/// are the same field is judged from these (`Delivery.route`).
public struct FieldIdentity: Codable, Equatable, Sendable {
    /// The app, when the keyboard could resolve it.
    public var hostBundleID: String?
    /// `UITextDocumentProxy.documentIdentifier`. It names one input session,
    /// not a text view: the same field reports a new one each time it takes
    /// focus again, after the keyboard was dismissed, after another field,
    /// and after the app was left and reopened (measured in the iOS 27.2
    /// Simulator). Equal IDs mean the keyboard never left.
    public var documentID: UUID?
    /// `Draft.fingerprint` of the text around the cursor. Nil in an empty field.
    public var draft: String?

    public init(hostBundleID: String?, documentID: UUID?, draft: String? = nil) {
        self.hostBundleID = hostBundleID
        self.documentID = documentID
        self.draft = draft
    }
}

/// One input session the keyboard was shown in (`SharedStore.fieldVisits`).
public struct FieldVisit: Codable, Equatable, Sendable {
    public var hostBundleID: String?
    public var documentID: UUID
    /// When the keyboard found itself in it.
    public var at: Date

    public init(hostBundleID: String?, documentID: UUID, at: Date = Date()) {
        self.hostBundleID = hostBundleID
        self.documentID = documentID
        self.at = at
    }
}

/// The text a keyboard reads around the cursor, reduced to a fingerprint so
/// two readings can be compared without the App Group keeping the text.
public enum Draft {
    public static func fingerprint(before: String?, after: String?) -> String? {
        let text = (before ?? "") + (after ?? "")
        guard !text.isEmpty else { return nil }
        // FNV-1a, 64 bit: the same in the app and the keyboard, which
        // `Hasher` is not.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// A finished result. It stays pending until a keyboard types it
/// (`route(in:handledID:firstReturn:now:)` has the rules) or the app copies it.
public struct Delivery: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    /// The field the text belongs in: where Stop was tapped in a keyboard,
    /// otherwise where Dictate was. Nil when no keyboard took part (the
    /// Action button with no keyboard on screen).
    public let destination: FieldIdentity?
    /// When the user stopped the dictation: the keyboard's Stop, the Live
    /// Activity's, or the Action button. Nil when it ended another way (a
    /// call, the launch recovery).
    public let stoppedAt: Date?
    /// The draft (`SessionSnapshot.draft`) a keyboard typed for this
    /// dictation, which this written text replaces. Nil when the text comes
    /// alone.
    public let replacesDraft: UUID?

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), destination: FieldIdentity?,
                stoppedAt: Date? = nil, replacesDraft: UUID? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.destination = destination
        self.stoppedAt = stoppedAt
        self.replacesDraft = replacesDraft
    }

    /// The same result without the fingerprint of the destination's text,
    /// which is only needed while the result is pending.
    public func forgettingDraft() -> Delivery {
        guard var destination, destination.draft != nil else { return self }
        destination.draft = nil
        return Delivery(id: id, text: text, createdAt: createdAt, destination: destination, stoppedAt: stoppedAt,
                        replacesDraft: replacesDraft)
    }

    /// A keyboard types a draft only while it is younger than this. The app
    /// waits `draftWait` for a keyboard to say it typed one, so a draft is
    /// never typed after the app gave up on it and sent the written text
    /// alone.
    public static let draftWindow: TimeInterval = 0.45
    public static let draftWait: TimeInterval = 0.6

    /// Whether a keyboard may still type this draft.
    public func isFreshDraft(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age >= 0 && age < Self.draftWindow
    }

    /// Why the keyboard on screen may type a result unasked.
    public enum Match: String, Equatable, Sendable {
        /// The same input session: the keyboard never left the field.
        case sameSession = "same session"
        /// Back in the same app, with the same text around the cursor.
        case sameDraft = "same draft"
        /// Back in the same app, in an empty field as the destination was,
        /// and the keyboard has been in no other field of that app since the
        /// dictation was stopped. A guess: nothing tells two empty fields of
        /// one app apart.
        case firstEmptyReturn = "first return to an empty field"
        /// The result has no destination, and this is the first keyboard up.
        case unaddressed = "no destination"
    }

    /// What the keyboard on screen does with a result.
    public enum Route: Equatable, Sendable {
        /// Type it into this field now.
        case type(Match)
        /// It may belong elsewhere. Say it is waiting; Paste last types it here.
        case offer
        /// Handled already, or too old to act on unasked.
        case leave
    }

    /// How long a result waits for its field. After that it is neither typed
    /// nor offered unasked; Paste last and History still have it.
    public static let pendingWindow: TimeInterval = 3600
    /// How long the empty-field guess (`Match.firstEmptyReturn`) is made.
    /// Looking something up takes minutes; later than this the result is
    /// only offered.
    public static let emptyReturnWindow: TimeInterval = 600
    /// A result with no destination is typed by the first keyboard on screen
    /// within this, when the app has not copied it first.
    public static let unaddressedWindow: TimeInterval = 120

    /// The one rule for where a result lands. `handledID` is
    /// `SharedStore.insertedDeliveryID`; `firstReturn` is
    /// `isFirstReturn(to:visits:)`, asked only for the empty-field guess.
    /// `takesProse` is false in a field for a username, an address, a code
    /// or a number: such a field receives a result only when Stop was tapped
    /// in it, never because it looks like the destination.
    public func route(in field: FieldIdentity, handledID: UUID?, firstReturn: @autoclosure () -> Bool,
                      takesProse: Bool = true, now: Date = Date()) -> Route {
        guard id != handledID else { return .leave }
        let age = now.timeIntervalSince(createdAt)
        guard let destination else { return age < Self.unaddressedWindow ? .type(.unaddressed) : .leave }
        guard age < Self.pendingWindow else { return .leave }
        if let session = destination.documentID, session == field.documentID { return .type(.sameSession) }
        // Past this point the field is judged by what it looks like, which
        // only means anything inside the same app.
        guard takesProse, let host = destination.hostBundleID, host == field.hostBundleID else { return .offer }
        if let draft = destination.draft { return draft == field.draft ? .type(.sameDraft) : .offer }
        return field.draft == nil && age < Self.emptyReturnWindow && firstReturn() ? .type(.firstEmptyReturn) : .offer
    }

    /// Whether `field` is the first field of the destination's app that the
    /// keyboard has been in since the dictation was stopped (since the text
    /// was ready, when nobody stopped it). `visits` is
    /// `SharedStore.fieldVisits`. Sessions before that do not count: the same
    /// field starts a new input session each time the keyboard comes back to
    /// it while a dictation records. A session in an app that could not be
    /// named counts, and so does a list too short to reach back that far.
    public func isFirstReturn(to field: FieldIdentity, visits: [FieldVisit]) -> Bool {
        guard let destination, let host = destination.hostBundleID else { return false }
        let left = stoppedAt ?? createdAt
        if visits.count >= SharedStore.fieldVisitLimit, let oldest = visits.first, oldest.at > left { return false }
        return !visits.contains {
            $0.at > left && $0.documentID != field.documentID && $0.documentID != destination.documentID
                && ($0.hostBundleID == host || $0.hostBundleID == nil)
        }
    }

    /// Whether a keyboard may still type or offer it unasked.
    public func isPending(handledID: UUID?, now: Date = Date()) -> Bool {
        id != handledID && now.timeIntervalSince(createdAt) < (destination == nil ? Self.unaddressedWindow : Self.pendingWindow)
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
        /// A dictation was started and its microphone has not delivered audio
        /// yet. The keyboard says "Starting…", not that it is listening.
        case starting
        case recording
        case processing

        /// A dictation is starting or recording: the Control Center toggle is on.
        public var isDictating: Bool { self == .starting || self == .recording }

        /// A dictation is in progress, from its start until its text is delivered.
        public var hasDictation: Bool { isDictating || self == .processing }
    }

    public var phase: Phase
    public var recordingStartedAt: Date?
    public var delivery: Delivery?
    public var notice: Notice?
    public var meetingActive: Bool
    /// Where the dictation in progress will land (`Delivery.destination`),
    /// from its start until its text is delivered. An app that iOS ended
    /// mid-dictation reads it at the next launch, so the recovered text
    /// still reaches its field.
    public var field: FieldIdentity?
    /// The transcript of the dictation in progress, offered while the
    /// writing model rewrites it. Only a keyboard still in the input session
    /// Stop was tapped in types it, underlined, and says so in
    /// `SharedStore.typedDraftID`; the written text then comes as a delivery
    /// that names it (`Delivery.replacesDraft`). The app withdraws it once
    /// a keyboard took it or `Delivery.draftWait` passed.
    public var draft: Delivery?

    public init(
        phase: Phase = .off,
        recordingStartedAt: Date? = nil,
        delivery: Delivery? = nil,
        notice: Notice? = nil,
        meetingActive: Bool = false,
        field: FieldIdentity? = nil,
        draft: Delivery? = nil
    ) {
        self.phase = phase
        self.recordingStartedAt = recordingStartedAt
        self.delivery = delivery
        self.notice = notice
        self.meetingActive = meetingActive
        self.field = field
        self.draft = draft
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
        case cancelDictation
        /// Put the pending result on the clipboard.
        case copyResult
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
