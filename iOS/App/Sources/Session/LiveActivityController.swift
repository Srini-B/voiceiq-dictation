// ActivityKit does not mark Activity Sendable; its update and end calls run
// off the main actor.
@preconcurrency import ActivityKit
import Foundation
import VoiceIQBridge
import VoiceIQCore

/// The Dynamic Island for the background session.
///
/// Requesting an activity only works while the app is in the foreground, so it
/// starts with the session. Updates work from the background.
@MainActor
final class LiveActivityController {
    typealias State = VoiceSessionAttributes.ContentState

    /// The user swiped the activity away, or iOS ended it (it caps a Live
    /// Activity at eight hours). The session stays warm; without an activity
    /// iOS will not let the app start the microphone from the background, so
    /// the next dictation opens the app once and a new activity starts there.
    var onEndedOutsideApp: (() -> Void)?

    /// True while an activity is on screen. iOS lets a backgrounded app start
    /// recording only while it has one (observed on device: with Live
    /// Activities turned off, the second in-place dictation failed to start).
    var isRunning: Bool { activity?.activityState == .active }

    private var activity: Activity<VoiceSessionAttributes>?
    private var lastState: State?
    private var watcher: Task<Void, Never>?

    /// Live Activities outlive the process that started them. One left over
    /// from a crash or a force quit would show a session that no longer exists.
    static func endLeftovers() {
        for activity in Activity<VoiceSessionAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Starts an activity if none is running. Only works while the app is in
    /// the foreground; ActivityKit refuses the request from the background.
    func start(_ state: State) {
        if isRunning { update(state); return }
        activity = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Log.session.info("live activities disabled by the user")
            return
        }
        do {
            let activity = try Activity.request(
                attributes: VoiceSessionAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            self.activity = activity
            lastState = state
            watch(activity)
        } catch {
            SessionDiagnostics.note("live activity request failed: \(error)")
        }
    }

    func update(_ state: State) {
        guard let activity, state != lastState else { return }
        lastState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        watcher?.cancel()
        watcher = nil
        if let activity {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
        lastState = nil
    }

    private func watch(_ activity: Activity<VoiceSessionAttributes>) {
        watcher = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .dismissed || state == .ended {
                    await MainActor.run {
                        guard let self, self.activity?.id == activity.id else { return }
                        self.activity = nil
                        self.lastState = nil
                        self.onEndedOutsideApp?()
                    }
                    return
                }
            }
        }
    }
}
