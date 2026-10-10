import VoiceIQCore
import SwiftUI

/// The pill's semantic state — a pure projection of coordinator state
/// (experience spec owns all timing/lifecycle; critic reconciliation #7).
enum PillState: Equatable {
    case hidden
    case idleDot
    case listening(locked: Bool)
    case processing
    case success(words: Int?)
    /// Neutral informational chip (coaching hint, copied-to-clipboard, offline…).
    case notice(String)
    case answer(String)
    /// The agent session panel. Its content lives in `PillModel.agent`.
    case agent
    /// Error styling: errorContainer surface + "saved to History" framing.
    case error(String)
    /// A call was noticed; the pill offers to record it. The string names the app or site.
    case meetingPrompt(String)
    /// A meeting is recording: timer, waveform, stop.
    case meetingRecording(since: Date)
    /// A downloaded update waits for a restart. The string is its version.
    case updateReady(String)
}

/// Microphone level for the waveform. A plain reference, not published: the
/// level arrives ~30 times a second, and publishing it rebuilt the whole pill
/// view and re-laid out its hosting view on every tick. The waveform's Canvas
/// reads the latest value on its own timeline instead.
@MainActor
final class LevelSource {
    var value: Float = 0

    static let silent = LevelSource()
}

@MainActor
final class PillModel: ObservableObject {
    @Published var state: PillState = .idleDot
    @Published var elapsed: TimeInterval = 0
    /// A provisional preview, never the result to insert.
    @Published var partial = ""
    /// Still-working slow state (>3s in processing — TimeoutPolicy.slowStateUI).
    @Published var slow = false
    /// `SettingsStore.pillAnchor`, mirrored so the pill hugs the panel edge
    /// the anchor points at instead of floating in the panel's middle.
    @Published var anchor: Double = SettingsStore().pillAnchor
    let level = LevelSource()
    /// The agent session shown while `state == .agent`.
    let agent = AgentPanelModel()
}
