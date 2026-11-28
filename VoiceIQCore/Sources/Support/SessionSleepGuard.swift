import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// One lock shared by dictation and meeting capture, so finishing one cannot
/// release the other's protection. A warm microphone alone does not hold it.
/// A meeting waiting to retry AssemblyAI does not hold it either.
@MainActor
public final class SessionSleepGuard {
    private var observation: AnyCancellable?
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #else
    private var previousIdleTimerDisabled: Bool?
    #endif

    public init(dictation: DictationCoordinator, meetings: MeetingEngine, writeUpCap: TimeInterval = 60 * 60) {
        // A stopped meeting holds it until its transcript and notes are saved
        // or fail, and at most `writeUpCap`, so a step that never returns
        // cannot keep the Mac awake until quit. The cap restarts whenever a
        // meeting joins or leaves the write-up, so overlapping ones each get it.
        let writingUp = meetings.$processing.map { Set($0.keys) }.removeDuplicates()
            .map { ids in
                !ids.isEmpty ? Just(true).append(Just(false).delay(for: .seconds(writeUpCap), scheduler: DispatchQueue.main)).eraseToAnyPublisher()
                     : Just(false).eraseToAnyPublisher()
            }
            .switchToLatest()
        observation = dictation.$state.combineLatest(meetings.$phase, dictation.$hasBackgroundJobs, writingUp)
            .map { state, phase, background, writingUp in
                if case .recording = phase { return true }
                if background || writingUp { return true }
                switch state {
                case .warming, .recording, .finalizing, .transcribing, .inserting: return true
                case .idle, .done, .cancelled, .failed: return false
                }
            }
            .removeDuplicates()
            .sink { [weak self] active in self?.setActive(active) }
    }

    /// The name `pmset -g assertions` shows for the lock.
    static let reason = "VoiceiQ is recording or transcribing a dictation or meeting"

    private func setActive(_ active: Bool) {
        #if os(macOS)
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: Self.reason
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
