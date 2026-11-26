import Foundation

/// When a dictation's second request starts: at the 90th percentile of the
/// last 20 dictations' answer times, so it goes out only for the slow tail
/// (a call that thinks, a stalled server) and a dictation is billed twice
/// about one time in ten.
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
