import Foundation

/// The pure hotkey grammar. One press toggles hands-free dictation:
///
///   press while idle        → begin recording, hands-free
///   press while recording   → finalize
///   Esc                     → cancel
///   other key < 1s in       → accidental chord, silent abort (the tap only
///                             reports one while the modifier is still held)
///
/// Releasing the key never does anything, so holding it is harmless. Pure and
/// clock-free: callers pass monotonic timestamps.
public struct HotkeyProcessor {
    public enum Event: Equatable, Sendable {
        case hotkeyDown
        case hotkeyUp
        case escDown
        case otherKeyDown
    }

    public struct Effects: Equatable, Sendable {
        public var intents: [HotkeyIntent] = []
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Hands-free recording started by a press at `sessionStartAt`.
        case locked(sessionStartAt: TimeInterval)
    }

    public private(set) var phase: Phase = .idle

    /// Snap back to idle after the coordinator refuses a begin (secure field,
    /// busy), otherwise the next press would read as a stop.
    public mutating func reset() {
        phase = .idle
    }

    /// True whenever a dictation session is in flight from the hotkey's perspective;
    /// the event tap uses this to decide whether to intercept Esc.
    public var isSessionActive: Bool { phase != .idle }

    public init() {}

    public mutating func handle(_ event: Event, at now: TimeInterval) -> Effects {
        var fx = Effects()
        switch (phase, event) {
        case (.idle, .hotkeyDown):
            phase = .locked(sessionStartAt: now)
            fx.intents = [.begin, .lockIn]

        case (.locked, .hotkeyDown):
            phase = .idle
            fx.intents = [.finalize]

        case (.locked, .escDown):
            phase = .idle
            fx.intents = [.cancel]

        case (.locked(let startAt), .otherKeyDown):
            // A letter typed right after the press means the modifier was part of
            // a chord, not a dictation. Later typing is deliberate and passes.
            if now - startAt < HotkeyTuning.interruptionWindow {
                phase = .idle
                fx.intents = [.abortAccidental]
            }

        case (.idle, _), (.locked, .hotkeyUp):
            break
        }
        return fx
    }
}
