#if os(macOS)
import AppKit
#endif
import Foundation
import VoiceIQBridge

/// Transcription seam. M3 provides the Gemini implementation; tests use fakes.
public protocol TranscriptionServicing: Sendable {
    /// Returns (rawTranscript, cleanedTranscript). Throws TranscriptionError.
    func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult
    func process(_ transcript: TranscriptionResult, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult
}

public extension TranscriptionServicing {
    func process(_ transcript: TranscriptionResult, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        transcript
    }
}

public struct TranscriptionResult: Equatable, Sendable {
    public var rawTranscript: String
    public var cleanedTranscript: String
    public var modelID: String
    /// Why the writing rules did not shape `cleanedTranscript`, when they were
    /// on and did not. Shown in History as the row's details.
    public var cleanupNote: String?

    public init(rawTranscript: String, cleanedTranscript: String, modelID: String, cleanupNote: String? = nil) {
        self.rawTranscript = rawTranscript
        self.cleanedTranscript = cleanedTranscript
        self.modelID = modelID
        self.cleanupNote = cleanupNote
    }
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case offline
    case network(String)
    /// Permanent request failure (400) — retrying is pointless (audit #3).
    case badRequest(String)
    /// 401 — the key itself was rejected.
    case auth
    /// 403/404 — key is fine but this model is gated, renamed, or unknown.
    /// Distinct from .auth: "fix your key" is the WRONG advice here.
    case modelUnavailable(model: String, detail: String?)
    /// 429 that is a real daily/hard quota.
    case rateLimitedDaily
    /// 429 per-minute throttle — clears on its own; retryable. Carries the
    /// server's Retry-After so the retry can wait exactly that long.
    case rateLimitedTransient(retryAfter: TimeInterval?)
    case timeout
    case emptyTranscript
    case safetyBlocked
}

public enum DictationMode: Equatable, Sendable {
    case dictate
    case askAnything(selectedText: String?)
    case translate(target: String)
    /// A spoken command for the agent. The transcript is handed to the
    /// agent loop instead of being inserted or answered here.
    case agent

    /// Modes whose result goes to `onAnswerReady` instead of insertion.
    public var handsTranscriptToCaller: Bool {
        switch self {
        case .askAnything, .agent: return true
        case .dictate, .translate: return false
        }
    }

    /// Modes whose recording and transcript stay in History. Agent commands
    /// live in the agent run instead.
    public var keepsRecording: Bool { self != .agent }
}

/// The text field that had focus when dictation started, and the text around
/// its cursor then. An Accessibility query can stall on a busy app, so it is
/// filled in off the main thread a moment after the session starts. Empty
/// when the app could not say or focus was not in a field text can be typed
/// into.
public final class FocusedFieldCapture: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var captured: AnyObject?
    private var capturedText: SurroundingText?
    public init() {}
    public var element: AnyObject? { lock.withLock { captured } }
    public var surroundingText: SurroundingText? { lock.withLock { capturedText } }
    public func set(_ element: AnyObject?, surroundingText: SurroundingText?) {
        lock.withLock { captured = element; capturedText = surroundingText }
    }
    public static func == (lhs: FocusedFieldCapture, rhs: FocusedFieldCapture) -> Bool { lhs === rhs }
}

/// Snapshot of where the user was dictating, captured at hotkey-down.
public struct DictationContext: Equatable, Sendable {
    public var targetAppBundleID: String?
    public var targetAppName: String?
    public var targetPID: pid_t?
    public var focusedField: FocusedFieldCapture?
    public var mode: DictationMode
    public var selectedTextIsSettable: Bool
    public var screenshots: [Data]

    public init(
        targetAppBundleID: String? = nil,
        targetAppName: String? = nil,
        targetPID: pid_t? = nil,
        focusedField: FocusedFieldCapture? = nil,
        mode: DictationMode = .dictate,
        selectedTextIsSettable: Bool = false,
        screenshots: [Data] = []
    ) {
        self.targetAppBundleID = targetAppBundleID
        self.targetAppName = targetAppName
        self.targetPID = targetPID
        self.focusedField = focusedField
        self.mode = mode
        self.selectedTextIsSettable = selectedTextIsSettable
        self.screenshots = screenshots
    }
}

/// Insertion seam. M4 provides the AX/paste ladder; tests use fakes.
public protocol TextInserting {
    @MainActor func insert(_ text: String, context: DictationContext) async -> InsertionOutcome
}

public enum InsertionOutcome: Equatable, Sendable {
    case inserted
    case frontmostChanged
    case fellBackToClipboard
    /// Secure input active — text stays in History only, never on the clipboard.
    case blockedSecureField
}

// MARK: - M2 stubs (replaced in M3/M4)

/// Until the Gemini client lands, "transcription" echoes a stub instantly.
public struct StubTranscriptionService: TranscriptionServicing {
    public init() {}
    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let text = String(format: "(recorded %.1fs — transcription arrives in M3)", durationSeconds)
        return TranscriptionResult(rawTranscript: text, cleanedTranscript: text, modelID: "stub")
    }
}

/// Until the insertion ladder lands, put the text on the clipboard.
#if os(macOS)
public struct StubClipboardInserter: TextInserting {
    public init() {}
    @MainActor public func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return .fellBackToClipboard
    }
}
#endif
