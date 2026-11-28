import Foundation

/// The single source of truth for every network deadline in the app.
/// (Critic reconciliation #9 — no other file may define timeout constants.)
public enum TimeoutPolicy {
    /// When the HUD flips to the "Still working…" slow state.
    public static let slowStateUI: TimeInterval = 3

    /// Longest a transcription waits out a per-minute throttle before giving
    /// the row back to History.
    public static let rateLimitWait: TimeInterval = 65

    /// On-device session load, including the first-use Core ML compile of a
    /// model and the English tools.
    public static let localLoad: TimeInterval = 120
    /// How long a stopped dictation waits for a model that is still loading
    /// before it goes to AssemblyAI, when a key is saved. A cold Core ML load
    /// takes about a minute on iPhone and 15 s on an M2 Mac; a warm one
    /// finishes during the recording. The load goes on as a warm-up for the
    /// next dictation.
    public static let localColdLoad: TimeInterval = 5
    /// On-device final decode: twice the audio length, at least two minutes.
    public static func localTranscribe(frames: Int64) -> TimeInterval {
        max(120, Double(frames) / 8_000)
    }
    /// On-device meeting: model loading plus a decode and a diarizer pass.
    /// Both run faster than real time on Apple silicon, so three times the
    /// audio covers a slow machine with the fans already on.
    public static func localMeeting(audioSeconds: Double) -> TimeInterval {
        max(600, 3 * audioSeconds)
    }

    /// Pre-recorded transcription: upload, queue and processing. AssemblyAI
    /// plans STT-3.7 at about 9 s p50 and 60 s p95 for a 5-minute file.
    public static func transcriptDeadline(audioDuration: TimeInterval) -> TimeInterval {
        90 + audioDuration / 2
    }
}
