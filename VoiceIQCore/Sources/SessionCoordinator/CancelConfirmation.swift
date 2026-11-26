import Foundation

/// ⌘Esc on a dictation that has recorded for a while asks first: the first
/// press keeps recording and the pill says to press again, and a second press
/// within `window` cancels. Shorter dictations cancel at the first press, as
/// before. Hex asks the same way (anomalyco/hex, MIT).
public struct CancelConfirmation: Sendable {
    /// The length from which a cancelled recording is kept in History
    /// (`DictationCoordinator.cancelKeepThreshold`): from here on a stray
    /// press costs a trip to History, so it is worth one more press.
    public static let longRecording: TimeInterval = DictationCoordinator.cancelKeepThreshold
    /// How long the first press waits for the second.
    public static let window: TimeInterval = 3

    private var askedAt: Date?

    public init() {}

    /// Whether a cancel press at `now` cancels a recording that started at
    /// `recordingSince` (nil when nothing records). False means it asked
    /// instead; the caller keeps recording and says so.
    public mutating func cancels(recordingSince: Date?, now: Date) -> Bool {
        guard let recordingSince, now.timeIntervalSince(recordingSince) >= Self.longRecording else { return true }
        if let askedAt, now.timeIntervalSince(askedAt) <= Self.window {
            self.askedAt = nil
            return true
        }
        askedAt = now
        return false
    }
}
