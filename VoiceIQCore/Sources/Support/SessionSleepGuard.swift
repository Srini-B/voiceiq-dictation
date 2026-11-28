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

    public init(dictation: DictationCoordinator, meetings: MeetingEngine) {
        let writingUp = Self.writingUp(meetings.$processing.map { Set($0.keys) }, cap: 60 * 60)
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

    /// True while a stopped meeting's transcript and notes are being written,
    /// for at most `cap` after the latest meeting joined, so a step that never
    /// returns cannot keep the device awake until quit. A meeting leaving
    /// never extends it.
    nonisolated static func writingUp<P: Publisher<Set<MeetingID>, Never>>(
        _ ids: P, cap: TimeInterval, now: @escaping @Sendable () -> Date = Date.init
    ) -> AnyPublisher<Bool, Never> {
        ids.removeDuplicates()
            .scan([MeetingID: Date]()) { joined, ids in
                var next = joined.filter { ids.contains($0.key) }
                for id in ids where next[id] == nil { next[id] = now() }
                return next
            }
            .map { joined -> AnyPublisher<Bool, Never> in
                let left = joined.values.max().map { $0.addingTimeInterval(cap).timeIntervalSince(now()) } ?? 0
                guard left > 0 else { return Just(false).eraseToAnyPublisher() }
                return Just(true).append(Just(false).delay(for: .seconds(left), scheduler: DispatchQueue.main)).eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
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
