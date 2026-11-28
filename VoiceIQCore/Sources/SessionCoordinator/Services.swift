#if os(macOS)
import AppKit
#endif
import Foundation
import os
import VoiceIQBridge

/// Transcription seam. `AssemblyAITranscriptionService` in the app; tests use fakes.
public protocol TranscriptionServicing: Sendable {
    /// Throws TranscriptionError.
    func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult
    /// The text to insert for a transcript the on-device model made: written
    /// by the writing rules, or as transcribed. Never throws for a failed
    /// writing request; the transcript is the fallback.
    func write(_ transcript: TranscriptionResult, context: DictationContext) async throws -> TranscriptionResult
    /// Opens a stream that transcribes the dictation while it is recorded;
    /// nil when this service does not.
    func listen(context: DictationContext) -> RealtimeTranscription?
    /// `transcribe`, with the transcript `live` streamed when it finished;
    /// the recording on disk otherwise. `onHeard` gets the transcript, with
    /// the Dictionary's replacements, the moment it is known and only when
    /// the writing model is about to rewrite it, so the field can show it
    /// as a draft meanwhile.
    func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext,
                    live: RealtimeTranscription?,
                    onHeard: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult
}

public extension TranscriptionServicing {
    func write(_ transcript: TranscriptionResult, context: DictationContext) async throws -> TranscriptionResult {
        transcript
    }
    func listen(context: DictationContext) -> RealtimeTranscription? { nil }
    func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext,
                    live: RealtimeTranscription?,
                    onHeard: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
        live?.cancel()
        return try await transcribe(audioURL: audioURL, durationSeconds: durationSeconds, context: context)
    }
}

public struct TranscriptionResult: Equatable, Sendable {
    /// The model's text before the Dictionary's replacement rules.
    public var rawTranscript: String
    /// The text that is inserted.
    public var cleanedTranscript: String
    public var modelID: String
    /// A short note for the pill when the text went in without the writing
    /// rules, such as when the writing model refused for lack of balance.
    public var notice: String?

    public init(rawTranscript: String, cleanedTranscript: String, modelID: String, notice: String? = nil) {
        self.rawTranscript = rawTranscript
        self.cleanedTranscript = cleanedTranscript
        self.modelID = modelID
        self.notice = notice
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
    /// The AssemblyAI account has no balance for this call (the LLM Gateway
    /// is not covered by the free credit).
    case noBalance
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
    /// A draft for the field the dictation goes to, which shows a spinner at
    /// the cursor from now on; nil when the field can't hold a draft that is
    /// replaced later, and the written text then goes in once by `insert`.
    @MainActor func draft(context: DictationContext) async -> TextDraft?
}

public extension TextInserting {
    @MainActor func draft(context: DictationContext) async -> TextDraft? { nil }
}

/// The transcript shown in the field while the writing model rewrites it,
/// then swapped for the written text. Only the draft's own text is ever
/// replaced: once the user edited it, or it can't be found for certain, it
/// stays as it is.
@MainActor
public protocol TextDraft: AnyObject {
    /// Puts the transcript in the field, marked as a draft.
    func show(_ text: String) async -> DraftShown
    /// Swaps the draft for the written text. False when the draft was
    /// edited, is gone, or can't be told apart; it then stays.
    func replace(with text: String) async -> Bool
    /// Ends the draft: the spinner and the marks go, the text stays.
    /// `replace(with: "")` first takes it out instead.
    func end()
    /// The dictation is ending without written text: a `show` that has not
    /// put anything in the field yet puts nothing in.
    func stopShowing()
}


public enum DraftShown: Equatable, Sendable {
    /// In the field, and found again for the replace.
    case shown
    /// Offered to the field but not confirmed (the iPhone keyboard may have
    /// typed it). The written text still goes through `replace`, which
    /// names the draft, but in the dictation's insert turn.
    case pending
    /// Nothing went in: the written text goes in by `insert`.
    case notInserted
    /// It went in, or may have, but can't be found again; it stays, and the
    /// written text is not inserted a second time.
    case lost
    /// Pasted with ⌘V into a field that still reads exactly as before: the
    /// paste may be there (a field that clears itself once it passes text
    /// on) or not, so the written text is not inserted beside it either.
    case unseen
}

public enum InsertionOutcome: Equatable, Sendable {
    case inserted
    case frontmostChanged
    case fellBackToClipboard
    /// Secure input active — text stays in History only, never on the clipboard.
    case blockedSecureField
}

// MARK: - M2 stubs (replaced in M3/M4)

/// Before the transcription client existed, "transcription" echoes a stub instantly.
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
