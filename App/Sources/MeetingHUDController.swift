import Combine
import Foundation
import VoiceIQCore

/// Puts meetings on the pill: the "record it?" offer when a call is noticed,
/// the recording clock, and the Option-M toggle.
///
/// Dictation owns the pill while a dictation runs. This controller only paints
/// when dictation is resting, and `DictationController` asks `restingState`
/// when it returns to rest so a recording meeting shows again afterwards.
@MainActor
final class MeetingHUDController {
    private let meetings: MeetingEngine
    private let hud: PillHUDController
    private var cancellables: Set<AnyCancellable> = []
    private var pendingPrompt: CallSource?
    private var promptDismiss: Task<Void, Never>?

    /// Set by DictationController: paint a pill state (honours the idle-dot preference).
    var setPill: ((PillState) -> Void) = { _ in }
    /// Set by DictationController: is a dictation using the pill right now.
    var dictationIsActive: () -> Bool = { false }
    /// Set by DictationController: the pill to return to after a notice ends.
    var restingPill: () -> PillState = { .idleDot }
    var notice: ((String) -> Void) = { _ in }

    /// How long the offer stays up before it folds away on its own.
    static let promptSeconds: TimeInterval = 30

    init(meetings: MeetingEngine, hud: PillHUDController) {
        self.meetings = meetings
        self.hud = hud
    }

    /// The pill state that stands in for the idle dot while a meeting records.
    var restingState: PillState? {
        if let until = meetings.endingAt { return .meetingEnding(until: until) }
        if case let .recording(_, since) = meetings.phase { return .meetingRecording(since: since, micMuted: meetings.micMuted) }
        return nil
    }

    func bind() {
        meetings.onCallDetected = { [weak self] source in self?.offer(source) }
        meetings.onCallEnded = { [weak self] in self?.withdrawOffer() }

        meetings.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.phaseChanged(phase) }
            .store(in: &cancellables)
        meetings.$endingAt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] until in self?.endingChanged(until) }
            .store(in: &cancellables)
        meetings.$micMuted
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] muted in self?.micMutedChanged(muted) }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        center.addObserver(forName: .pillMeetingAccepted, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.accept() }
        }
        center.addObserver(forName: .pillMeetingDismissed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        center.addObserver(forName: .pillMeetingStopTapped, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.meetings.stopRecording() }
        }
        center.addObserver(forName: .pillMeetingKeepTapped, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.meetings.keepRecordingAfterCallEnd() }
        }
        // Posted only by the pill's confirmed Discard.
        center.addObserver(forName: .pillMeetingDiscardTapped, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.meetings.discardRecording() }
        }
    }

    /// Option-M.
    func toggle() {
        Log.hotkey.info("meeting toggle shortcut fired")
        meetings.toggleRecording()
    }

    /// Dictation finished and the pill is free again: show anything held back.
    func dictationBecameIdle() {
        guard let source = pendingPrompt else { return }
        pendingPrompt = nil
        offer(source)
    }

    private func offer(_ source: CallSource) {
        guard !dictationIsActive() else { pendingPrompt = source; return }
        setPill(.meetingPrompt(MeetingEngine.name(source)))
        promptDismiss?.cancel()
        promptDismiss = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.promptSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(quiet: false)
        }
    }

    private func withdrawOffer() {
        pendingPrompt = nil
        promptDismiss?.cancel()
        if case .meetingPrompt = hud.model.state { setPill(restingPill()) }
    }

    private func accept() {
        promptDismiss?.cancel()
        meetings.acceptDetectedCall()
    }

    private func dismiss(quiet: Bool = true) {
        promptDismiss?.cancel()
        pendingPrompt = nil
        meetings.dismissDetectedCall(quiet: quiet)
        if case .meetingPrompt = hud.model.state { setPill(restingPill()) }
    }

    /// The recorded call ended (a countdown), or the countdown was kept or the call came back.
    private func endingChanged(_ until: Date?) {
        guard !dictationIsActive(), case let .recording(_, since) = meetings.phase else { return }
        setPill(until.map { .meetingEnding(until: $0) } ?? .meetingRecording(since: since, micMuted: meetings.micMuted))
    }

    private func micMutedChanged(_ muted: Bool) {
        guard !dictationIsActive(), case let .recording(_, since) = meetings.phase, meetings.endingAt == nil else { return }
        setPill(.meetingRecording(since: since, micMuted: muted))
    }

    private func phaseChanged(_ phase: MeetingPhase) {
        switch phase {
        case let .recording(_, since):
            // A notice posted as recording starts (the On device one) keeps its
            // seconds; its dismissal lands on the recording pill.
            if case .notice = hud.model.state { return }
            if !dictationIsActive() { setPill(.meetingRecording(since: since, micMuted: meetings.micMuted)) }
        case .idle, .failed:
            // Notes are made in the background; the pill is free at once and
            // shows the check only when they are saved.
            if !dictationIsActive() {
                switch hud.model.state {
                case .meetingRecording, .meetingEnding: setPill(restingPill())
                default: break
                }
            }
        case .callDetected:
            break
        }
    }
}
