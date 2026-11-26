import Foundation

/// When `SystemAudioTap` must rebuild its tap mid-meeting, and how much
/// silence keeps the system track on the meeting's clock across a rebuild.
/// Adapted from Hex (anomalyco/hex `5704885d`, `4a3e9d49`, `src/meeting/capture.rs`).
public enum SystemTapWatch {
    /// A tap whose output device went away keeps calling back with exact
    /// zeros, so the callbacks alone never show the loss. Long, because an
    /// idle call is legitimately silent.
    public static let silenceLimit: TimeInterval = 15

    /// Exact zeros on the system track, counted only after it carried sound,
    /// so a recording of nothing, or a call before anyone talks, is not a
    /// stalled tap.
    public struct Silence: Equatable, Sendable {
        public private(set) var armed = false
        private var zeros: TimeInterval = 0
        /// Rebuilds since the track last carried sound. Each one waits four
        /// times longer (15, 60, then 240 s), so a far side that went quiet
        /// while its call app plays exact zeros is not rebuilt every 15 s.
        private var rebuilds = 0

        /// How long the zeros must last before the next check.
        public var limit: TimeInterval {
            SystemTapWatch.silenceLimit * Double(1 << (2 * min(rebuilds, 2)))
        }

        public init() {}

        /// One buffer of `seconds`. True each time the track, after carrying
        /// sound, has been exact zeros for another `silenceLimit`, so the
        /// caller can check again later when the output was idle the first time.
        public mutating func hear(seconds: TimeInterval, exactZero: Bool) -> Bool {
            guard exactZero else { armed = true; zeros = 0; rebuilds = 0; return false }
            guard armed else { return false }
            zeros += seconds
            guard zeros >= limit else { return false }
            zeros = 0
            return true
        }

        /// A rebuilt tap restarts the count but stays armed: a replacement
        /// that also delivers only zeros (an output still settling) is
        /// rebuilt again, after a longer wait each time, instead of leaving
        /// the rest of the meeting silent.
        public mutating func rebuilt() {
            zeros = 0
            rebuilds += 1
        }
    }

    /// The default output moved to another device the tap was not made on.
    /// An unreadable device (0, `kAudioObjectUnknown`) is no evidence of a move.
    public static func outputMoved(from made: UInt32, to current: UInt32) -> Bool {
        made != 0 && current != 0 && made != current
    }

    /// Gaps shorter than this are buffer jitter, not lost time.
    static let shortestGap: TimeInterval = 0.05

    /// Frames of silence to write before the first buffer after a rebuild:
    /// the time between the old tap's last buffer and this one, less this
    /// buffer's own length, so the system track stays aligned with the mic.
    public static func gapFrames(lastBufferAt: TimeInterval, now: TimeInterval, bufferSeconds: TimeInterval,
                                 sampleRate: Double) -> Int {
        let gap = now - lastBufferAt - bufferSeconds
        return gap >= shortestGap ? Int((gap * sampleRate).rounded()) : 0
    }
}
