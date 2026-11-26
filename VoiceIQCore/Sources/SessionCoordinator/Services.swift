#if os(macOS)
import AppKit
#endif
import Foundation
import os
import VoiceIQBridge

/// Transcription seam. `GeminiTranscriptionService` in the app; tests use fakes.
public protocol TranscriptionServicing: Sendable {
    /// Throws TranscriptionError.
    func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult
    /// The text to insert for a transcript the on-device model made: written
    /// by the writing rules, or as transcribed. Never throws for a failed
    /// writing request; the transcript is the fallback.
    func write(_ transcript: TranscriptionResult, context: DictationContext) async throws -> TranscriptionResult
    /// Sends the request for speech that ended in a pause before the
    /// recording ends; nil when this service does not.
    func speculate(_ speech: PausedSpeech, context: DictationContext) -> SpeculativeDictation?
    /// `transcribe`, answered by `speculation` when it covers the same speech
    /// and prompt.
    func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext,
                    speculation: SpeculativeDictation?) async throws -> TranscriptionResult
}

public extension TranscriptionServicing {
    func write(_ transcript: TranscriptionResult, context: DictationContext) async throws -> TranscriptionResult {
        transcript
    }
    func speculate(_ speech: PausedSpeech, context: DictationContext) -> SpeculativeDictation? { nil }
    func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext,
                    speculation: SpeculativeDictation?) async throws -> TranscriptionResult {
        speculation?.cancel()
        return try await transcribe(audioURL: audioURL, durationSeconds: durationSeconds, context: context)
    }
}

/// Send-on-pause: the dictation request for speech that ended in a pause,
/// sent while the recording goes on. At key-up it stands in for the request
/// only when the recording's speech and the prompt are unchanged; otherwise
/// it is cancelled. Requests stream, so one cancelled before the first chunk
/// of its answer is not billed.
public final class SpeculativeDictation: Sendable {
    public let range: Range<Int64>
    public let prompt: String
    public let sentAt: ContinuousClock.Instant
    public let answer: Task<String, Error>
    private let progress: OSAllocatedUnfairLock<Progress>

    private struct Progress {
        var streamed = false
        var answeredAt: ContinuousClock.Instant?
    }

    /// `answer` sends the request off the main actor and calls the closure
    /// it is given when the first chunk of the answer arrives.
    public init(range: Range<Int64>, prompt: String, sentAt: ContinuousClock.Instant,
                answer: @escaping @Sendable (_ onFirstChunk: @escaping @Sendable () -> Void) async throws -> String) {
        let progress = OSAllocatedUnfairLock(initialState: Progress())
        self.range = range
        self.prompt = prompt
        self.sentAt = sentAt
        self.progress = progress
        self.answer = Task {
            let text = try await answer { progress.withLock { $0.streamed = true } }
            progress.withLock { $0.streamed = true; $0.answeredAt = ContinuousClock().now }
            return text
        }
    }

    /// Part of the answer arrived, so Gemini bills the request whether or
    /// not it is used.
    public var isBilled: Bool { progress.withLock { $0.streamed } }

    /// When the whole answer arrived; nil until then.
    public var answeredAt: ContinuousClock.Instant? { progress.withLock { $0.answeredAt } }

    public func cancel() { answer.cancel() }
}

public struct TranscriptionResult: Equatable, Sendable {
    /// The model's text before the Dictionary's replacement rules.
    public var rawTranscript: String
    /// The text that is inserted.
    public var cleanedTranscript: String
    public var modelID: String

    public init(rawTranscript: String, cleanedTranscript: String, modelID: String) {
        self.rawTranscript = rawTranscript
        self.cleanedTranscript = cleanedTranscript
        self.modelID = modelID
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
    /// The screen's text, one entry per capture, when screen context is on.
    public var screenText: [String]
    /// When the key ended the recording. Press Return after paste skips the
    /// Return when Esc came after it.
    public var recordingEndedAt: Date?

    public init(
        targetAppBundleID: String? = nil,
        targetAppName: String? = nil,
        targetPID: pid_t? = nil,
        focusedField: FocusedFieldCapture? = nil,
        screenText: [String] = []
    ) {
        self.targetAppBundleID = targetAppBundleID
        self.targetAppName = targetAppName
        self.targetPID = targetPID
        self.focusedField = focusedField
        self.screenText = screenText
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
