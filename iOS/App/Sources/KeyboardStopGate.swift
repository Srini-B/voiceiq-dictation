import Foundation
import VoiceIQBridge
import VoiceIQCore

/// Ties the keyboard's stops to the start command that began the dictation,
/// so a stop sent for one recording never ends another.
struct KeyboardStopGate {
    /// The keyboard start command the dictation in progress began with.
    private(set) var startedBy: UUID?
    /// A stop waiting for its dictation to record.
    private var held: KeyboardCommand?

    mutating func started(by id: UUID) { startedBy = id }
    mutating func ended() { startedBy = nil }

    /// Takes a stop from the keyboard; true when it finalizes the dictation now.
    /// A plain stop ends whatever records. One bound to a start, or sent while
    /// the dictation still warms up, waits until that dictation records.
    mutating func receive(_ stop: KeyboardCommand, state: DictationState) -> Bool {
        if stop.startID == nil, case .recording = state { return true }
        guard stop.startID != nil || state == .warming else { return false }
        var stop = stop
        stop.startID = stop.startID ?? startedBy
        held = stop
        return takeHeldStop(state: state)
    }

    /// True once, when the held stop's dictation is the one recording. A stop
    /// for another start, or older than a command may be, never applies.
    mutating func takeHeldStop(state: DictationState) -> Bool {
        guard let stop = held else { return false }
        guard stop.isFresh(), stop.startID != nil else { held = nil; return false }
        guard stop.startID == startedBy, case .recording = state else { return false }
        held = nil
        return true
    }
}
