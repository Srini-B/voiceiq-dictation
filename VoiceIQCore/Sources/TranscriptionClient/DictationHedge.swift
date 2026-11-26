import Foundation

/// When a dictation's second request starts: at the 90th percentile of the
/// last 20 dictations' answer times, between 4 and 20 s, so it goes out only
/// for the slow tail (a call that thinks, a stalled server).
///
/// Answer times barely depend on the recording's length or the prompt: on
/// 656 calls (2026-11-26) dictations of 0–5 s and 20–60 s answered in a
/// median 3.0 s and 3.6 s, while the 90th percentile moved from 6 s to 13 s
/// with the API's load from one hour to the next. Recent answers predict the
/// next one; the request's own size does not. A dictation that needed the
/// second request counts as 1.5 times the delay it waited, so a slow spell
/// raises the delay instead of hiding behind the early answers it bought.
///
/// Off in the app since 2026-11-26 (`shared` is built with `sendsBackup:
/// false`): 99 simultaneous request pairs gave the same p50 and p90 with a
/// backup at 6 s as with one request (3.24 s and 9.04 s), because the two
/// copies' answer times correlate at 0.93, and every backup is a billed call
/// against the cost cap. Pass `true` to bring it back. A request that loses
/// its connection still gets a second attempt (`GeminiClient.firstSuccess`).
actor DictationHedge {
    static let shared = DictationHedge(sendsBackup: false)

    /// The delay while the backup is off: longer than any dictation's overall
    /// deadline (`TimeoutPolicy.overallDeadline`), so the timer never fires.
    static let never: TimeInterval = 24 * 60 * 60

    private let sendsBackup: Bool

    init(sendsBackup: Bool) {
        self.sendsBackup = sendsBackup
    }

    private var recent: [TimeInterval] = []
    private static let window = 20
    private static let floor: TimeInterval = 4
    private static let ceiling: TimeInterval = 20
    /// Before five dictations have answered.
    static let initialDelay: TimeInterval = 8

    func delay() -> TimeInterval {
        guard sendsBackup else { return Self.never }
        guard recent.count >= 5 else { return Self.initialDelay }
        let sorted = recent.sorted()
        let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
        return min(max(p90, Self.floor), Self.ceiling)
    }

    /// A dictation answered after `seconds`, with the second request due after `delay`.
    func record(answeredAfter seconds: TimeInterval, delay: TimeInterval) {
        recent.append(seconds > delay ? delay * 1.5 : seconds)
        if recent.count > Self.window { recent.removeFirst() }
    }
}
