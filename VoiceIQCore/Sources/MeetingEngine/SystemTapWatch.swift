import Foundation

/// When `SystemAudioTap` must rebuild its tap mid-meeting, and how much
/// silence keeps the system track on the meeting's clock across a rebuild.
/// Adapted from Hex (anomalyco/hex `5704885d`, `4a3e9d49`, `src/meeting/capture.rs`).
public enum SystemTapWatch {
    /// A tap whose output device went away keeps calling back with exact
    /// zeros, so the callbacks alone never show the loss. Long, because an
    /// idle call is legitimately silent.
    public static let silenceLimit: TimeInterval = 15

    /// The loudest 16-bit sample of a track that carries nothing: about −72 dBFS.
    /// MEASURED 2026-11-28: the live-call probe's m2 and m3 system tracks
    /// heard none of the call and peaked near −84 dBFS, not exact zeros, so
    /// a watch for zeros alone never fired. Not −60 dBFS: a Meet call's speech
    /// peaked near there (`TrackAudio.gain`, 2026-09-27).
    public static let quietPeak: Int16 = 8

    public static func isQuiet(_ samples: UnsafeBufferPointer<Int16>) -> Bool {
        !samples.contains { $0 > quietPeak || $0 < -quietPeak }
    }

    /// A quiet system track, counted from the start: a call that was never
    /// heard is the stall to catch. A recording of nothing, or a call before
    /// anyone talks, is let through by the caller, which rebuilds only while
    /// the tapped processes play.
    public struct Silence: Equatable, Sendable {
        private var zeros: TimeInterval = 0
        /// Rebuilds since the track last carried sound. Each one waits four
        /// times longer (15, 60, then 240 s), so a far side that went quiet
        /// while its call app plays silence is not rebuilt every 15 s.
        private var rebuilds = 0
        /// The track has carried sound: from then on a quiet stretch is more
        /// likely the owner's long turn than a lost tap, so the wait starts
        /// at 60 s, and a rebuild seldom lands on the far side's reply (Neon on #137).
        private var heard = false

        /// How long the quiet must last before the next check.
        public var limit: TimeInterval {
            SystemTapWatch.silenceLimit * (heard ? 4 : 1) * Double(1 << (2 * min(rebuilds, 2)))
        }

        public init() {}

        /// One buffer of `seconds`. True each time the track has been quiet
        /// for another `limit`, so the caller can check again later when the
        /// output was idle the first time.
        public mutating func hear(seconds: TimeInterval, quiet: Bool) -> Bool {
            guard quiet else { zeros = 0; rebuilds = 0; heard = true; return false }
            zeros += seconds
            guard zeros >= limit else { return false }
            zeros = 0
            return true
        }

        /// A rebuilt tap restarts the count: a replacement
        /// that also delivers only quiet (an output still settling) is
        /// rebuilt again, after a longer wait each time, instead of leaving
        /// the rest of the meeting silent.
        /// `backingOff` is false for a rebuild after an output move, which
        /// says nothing about whether the tap stalls.
        public mutating func rebuilt(backingOff: Bool = true) {
            zeros = 0
            if backingOff { rebuilds += 1 }
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
