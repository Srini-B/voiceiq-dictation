#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// The Live Activity shown in the Dynamic Island while a voice session is up.
public struct VoiceSessionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public enum Phase: String, Codable, Hashable, Sendable {
            case ready
            case recording
            case processing
            case meeting
        }

        public var phase: Phase
        public var mode: KeyboardMode
        /// Start of the current recording or meeting, for the running timer.
        public var since: Date?

        public init(phase: Phase, mode: KeyboardMode = .dictate, since: Date? = nil) {
            self.phase = phase
            self.mode = mode
            self.since = since
        }
    }

    public init() {}
}

/// "End" in the Dynamic Island. Ends the background session and turns the mic off.
public struct EndVoiceSessionIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "End VoiceiQ Session"
    public static let isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        SharedStore.shared.request(.endSession)
        return .result()
    }
}

/// "Stop" in the Dynamic Island while dictating. The result waits for the keyboard.
public struct StopDictationIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Stop Dictation"
    public static let isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        SharedStore.shared.request(.stopDictation)
        return .result()
    }
}

/// Where `ToggleDictationIntent` hands off inside the app. The app sets it at
/// launch; iOS runs the intent in the app's process (it is a
/// `LiveActivityIntent`), launching the app in the background if needed.
@MainActor
public enum ActionButtonBridge {
    /// Returns why no dictation started, or nil.
    public static var toggle: (@MainActor () async -> String?)?

    static func run() async throws {
        // A cold launch can reach here before the app has finished setting up.
        for _ in 0..<30 where toggle == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let refusal = await toggle?() {
            throw ActionButtonRefusal(message: refusal)
        }
    }
}

/// A reason the Action button could not start, shown by the system.
public struct ActionButtonRefusal: Error, CustomLocalizedStringResourceConvertible {
    public let message: String
    public var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// The Control Center control (and the Action button, when the user assigns
/// the control to it). Starts a dictation without opening VoiceiQ, or stops
/// the one in progress. As an audio-recording intent it may open the
/// microphone from the background; iOS requires a Live Activity for as long
/// as it records, which the app starts before returning.
@available(iOS 18.0, *)
public struct ToggleDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    public static let title: LocalizedStringResource = "Dictate with VoiceiQ"
    public static let description = IntentDescription("Starts or stops a VoiceiQ dictation.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await ActionButtonBridge.run()
        return .result()
    }
}

/// The Control Center toggle, also run by the Action button. iOS passes the
/// flipped displayed state as `value`, but that state can be stale: the app's
/// reload after a dictation stopped elsewhere does not always reach the
/// control. So `value` is ignored and a press toggles the real state, like
/// `ToggleDictationIntent`. Not an App Shortcut: a required value would make
/// Siri and Spotlight ask for it.
@available(iOS 18.0, *)
public struct SetDictationIntent: SetValueIntent, AudioRecordingIntent, LiveActivityIntent {
    public static let title: LocalizedStringResource = "Dictate with VoiceiQ"
    public static let isDiscoverable = false

    @Parameter(title: "Dictating")
    public var value: Bool

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await ActionButtonBridge.run()
        return .result()
    }
}

extension SharedStore {
    /// The control is on while the app records a dictation.
    public static let dictationControlKind = "io.blue.voiceiq.ios.control.dictate"

    public func isDictating(now: Date = Date()) -> Bool {
        snapshot.phase == .recording && appIsAlive(now: now)
    }
}

/// "Stop" in the Dynamic Island while recording a meeting.
public struct StopMeetingIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Stop Meeting Recording"
    public static let isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        SharedStore.shared.request(.stopMeeting)
        return .result()
    }
}
#endif
