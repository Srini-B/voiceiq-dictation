import Foundation

/// What the hotkey layer asks the session coordinator to do.
public enum HotkeyIntent: Equatable, Sendable {
    /// Key went down — start recording NOW (audio from t=0).
    case begin
    /// Lock into hands-free recording.
    case lockIn
    /// Stop requested — finalize and transcribe.
    case finalize
    /// ⌘Esc — cancel the session (audio still saved per retention policy).
    case cancel
    /// Another key was typed within the interruption window — accidental chord,
    /// cancel silently (Wispr/VoiceInk pattern).
    case abortAccidental
}

/// Timing constants for the hotkey grammar.
public enum HotkeyTuning {
    /// A non-hotkey keystroke within this window of session start aborts as accidental.
    public static let interruptionWindow: TimeInterval = 1.0
}
