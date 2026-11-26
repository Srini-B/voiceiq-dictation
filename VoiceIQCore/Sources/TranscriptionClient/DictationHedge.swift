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
actor DictationHedge {
    static let shared = DictationHedge()

    private var recent: [TimeInterval] = []
    private static let window = 20
    private static let floor: TimeInterval = 4
    /// A 6 s cap was tried and measured worse (2026-11-26, 198 calls each,
    /// paired sessions): p90 9.2 s against 7.0 s at 20 s, with a backup on 22%
    /// of dictations against 15%. When the API is slow both requests are slow,
    /// so an earlier backup adds calls without shortening the wait.
    private static let ceiling: TimeInterval = 20
    /// Before five dictations have answered.
    static let initialDelay: TimeInterval = 8

    func delay() -> TimeInterval {
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
