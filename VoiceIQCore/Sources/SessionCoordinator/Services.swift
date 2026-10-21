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

/// Why the writing rules did not shape a transcript when they were on, and
/// what stood in for them.
public struct CleanupSkip: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// The user keeps dictations of 5 seconds or less as spoken.
        case shortDictation
        /// The cleanup request never answered: timed out, offline, or a network error.
        case requestFailed
        /// The model answered and the validation gate refused its rewrite.
        case rewriteRejected
    }
    public var cause: Cause
    /// `FillerStripper` removed hesitation sounds in the model's place.
    public var fillersRemoved: Bool
    /// The row's details in History.
    public var note: String

    public init(cause: Cause, fillersRemoved: Bool = false, note: String) {
        self.cause = cause
        self.fillersRemoved = fillersRemoved
        self.note = note
    }
}

public struct TranscriptionResult: Equatable, Sendable {
    public var rawTranscript: String
    public var cleanedTranscript: String
    public var modelID: String
    /// Set when the writing rules were on and did not shape `cleanedTranscript`.
    public var cleanupSkip: CleanupSkip?
    /// Local English formatting candidate. The original remains authoritative.
    public var normalizedTranscript: String?
    /// An Ask Anything result that is the edited selection rather than an
    /// answer: it goes through the insertion ladder in place of the selected
    /// text instead of the answer pill.
    public var replacesSelection: Bool

    /// Shown in History as the row's details.
    public var cleanupNote: String? { cleanupSkip?.note }

    public init(rawTranscript: String, cleanedTranscript: String, modelID: String, cleanupSkip: CleanupSkip? = nil,
                normalizedTranscript: String? = nil, replacesSelection: Bool = false) {
        self.rawTranscript = rawTranscript
        self.cleanedTranscript = cleanedTranscript
        self.modelID = modelID
        self.cleanupSkip = cleanupSkip
        self.normalizedTranscript = normalizedTranscript
        self.replacesSelection = replacesSelection
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
    /// Targets in order of preference; the model picks the first one the
    /// transcript is not already in.
    case translate(targets: [String])
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
    private var capturedWindowTitle: String?
    private var capturedPageURL: String?
    public init() {}
    public var element: AnyObject? { lock.withLock { captured } }
    public var surroundingText: SurroundingText? { lock.withLock { capturedText } }
    /// The title of the target app's focused window (a document name, a page
    /// title, a chat name). Read with the field, so it costs no extra wait.
    public var windowTitle: String? { lock.withLock { capturedWindowTitle } }
    public func set(_ element: AnyObject?, surroundingText: SurroundingText?, windowTitle: String? = nil) {
        lock.withLock { captured = element; capturedText = surroundingText; capturedWindowTitle = windowTitle }
    }
    /// The browser page's host and path. Found by a tree walk after the
    /// field, so it is set on its own and may arrive later.
    public var pageURL: String? { lock.withLock { capturedPageURL } }
    public func setPageURL(_ url: String?) { lock.withLock { capturedPageURL = url } }
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
