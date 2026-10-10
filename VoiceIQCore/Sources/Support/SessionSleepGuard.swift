import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// One lock shared by dictation and meeting capture, so finishing one cannot
/// release the other's protection. A warm microphone alone does not hold it.
@MainActor
public final class SessionSleepGuard {
    private var observation: AnyCancellable?
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #else
    private var previousIdleTimerDisabled: Bool?
    #endif

    public init(dictation: DictationCoordinator, meetings: MeetingEngine) {
        observation = dictation.$state.combineLatest(meetings.$phase)
            .map { state, phase in
                if case .recording = phase { return true }
                switch state {
                case .warming, .recording, .finalizing, .transcribing, .inserting: return true
                case .idle, .done, .cancelled, .failed: return false
                }
            }
            .removeDuplicates()
            .sink { [weak self] active in self?.setActive(active) }
    }

    private func setActive(_ active: Bool) {
        #if os(macOS)
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "VoiceiQ dictation or meeting recording"
            )
        } else if !active, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #else
        if active, previousIdleTimerDisabled == nil {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if !active, let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
        }
        #endif
    }

    public func stop() {
        observation = nil
        setActive(false)
    }
}
