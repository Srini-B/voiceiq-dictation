import Foundation
import UIKit
import VoiceIQBridge
import VoiceIQCore

/// The background voice session: the keeper that lets keyboard taps record
/// in place, and everything the keyboard reads from the App Group.
///
/// A session starts when a keyboard tap opens the app (the one-time bounce)
/// or when the Action button runs `ToggleDictationIntent`. One keeper holds it
/// (`MobileSettings.KeepActiveMode`) for `MobileSettings.warmWindow` after
/// each dictation, then the session ends:
/// - Keep mic on: the mic stays open meanwhile.
/// - Background audio: silent playback on a non-mixable session keeps the app
///   up; the mic is off while idle.
/// Once it ends, the next keyboard tap bounces again. The Live Activity is
/// shown only for sessions the Action button started (iOS requires one for an
/// audio-recording intent) and for meetings.
@MainActor
final class VoiceSession: ObservableObject {
    typealias Keeper = MobileSettings.KeepActiveMode

    /// What holds the session, or nil when there is none.
    @Published private(set) var keeper: Keeper?
    var isActive: Bool { keeper != nil }
    /// When the warm window runs out, while it is counting.
    @Published private(set) var warmUntil: Date?

    /// What the dictation pipeline is doing. Set by the app model.
    var dictationPhase: SessionSnapshot.Phase = .warm {
        didSet {
            publishIfChanged()
            if dictationPhase != oldValue { phaseChanged() }
        }
    }
    var mode: KeyboardMode = .dictate { didSet { publishIfChanged() } }
    var recordingStartedAt: Date? { didSet { publishIfChanged() } }
    var meetingStartedAt: Date? {
        didSet {
            publishIfChanged()
            if meetingStartedAt == nil, oldValue != nil { becameIdle() }
        }
    }

    var onInterruptionBegan: (() -> Void)?

    private let audio = KeepAliveAudio()
    private let activity = LiveActivityController()
    private let store = SharedStore.shared
    private var heartbeat: Timer?
    private var warmTimer: Timer?
    private var delivery: Delivery?
    private var notice: Notice?
    private var lastPublished: SessionSnapshot?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// The Action button started this session, so it carries a Live Activity.
    private var startedByActionButton = false

    init() {
        LiveActivityController.endLeftovers()
        // Whatever an earlier process left in the App Group is stale.
        delivery = store.snapshot.delivery
        publish(force: true)
        audio.onInterruptionBegan = { [weak self] in self?.onInterruptionBegan?() }
        audio.onLost = { [weak self] message in
            self?.post(notice: message)
            self?.end()
        }
        activity.onEndedOutsideApp = {
            SessionDiagnostics.note("live activity ended outside the app")
        }
    }

    /// Starts the session. Runs in the foreground, or inside the Action
    /// button's intent with `fromActionButton`.
    func begin(fromActionButton: Bool = false) throws {
        if isActive {
            if fromActionButton, !startedByActionButton {
                startedByActionButton = true
                activity.start(activityState)
            }
            return
        }
        let keeper = MobileSettings.keepActiveMode
        try audio.start(preferBuiltInMic: MobileSettings.preferBuiltInMic, keeper: keeper)
        self.keeper = keeper
        startedByActionButton = fromActionButton
        if fromActionButton { activity.start(activityState) }
        heartbeat = Timer.scheduledTimer(withTimeInterval: SharedStore.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
        beat()
        publish(force: true)
        SessionDiagnostics.note("session began (\(fromActionButton ? "action button" : "keyboard")), keeper \(keeper.label), warm window \(MobileSettings.warmWindow.label)")
        // The dictation that opened the session starts right after this. If
        // none does (it was refused), count the warm window from now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isActive, self.dictationPhase == .warm, self.warmTimer == nil else { return }
            self.scheduleWarmEnd()
        }
    }

    /// Whether a dictation can start without opening the app.
    var canRecordInBackground: Bool {
        keeper != nil && audio.isRunning
    }

    var keeperDescription: String {
        guard canRecordInBackground, let keeper else { return "none" }
        return keeper.label.lowercased()
    }

    /// The setting changed. An idle session held by the other keeper ends, so
    /// the next one starts with the new keeper.
    func keepActiveModeChanged() {
        guard let keeper, keeper != MobileSettings.keepActiveMode, dictationPhase == .warm, meetingStartedAt == nil else { return }
        end()
    }

    func end() {
        guard let keeper else { return }
        self.keeper = nil
        startedByActionButton = false
        cancelWarmEnd()
        heartbeat?.invalidate()
        heartbeat = nil
        store.heartbeat = nil
        store.level = 0
        audio.stop()
        activity.end()
        publish(force: true)
        SessionDiagnostics.note("session ended")
    }

    // MARK: - Warm window

    private func phaseChanged() {
        guard isActive else { return }
        switch dictationPhase {
        case .recording:
            cancelWarmEnd()
        case .processing where MobileSettings.warmWindow.seconds == 0 && meetingStartedAt == nil:
            // "Never": the audio session closes as soon as the dictation
            // stops, but the session stays up until the text is delivered, so
            // the keyboard and the Dynamic Island show "Writing…" meanwhile.
            // It ends at `.warm`. Background time covers the transcription.
            holdBackgroundTime()
            audio.stop()
            SessionDiagnostics.note("audio session closed (warm window: Never)")
        case .warm:
            becameIdle()
        default:
            break
        }
    }

    /// No dictation or meeting is running. The warm window counts down.
    private func becameIdle() {
        scheduleWarmEnd()
    }

    /// Counts the warm window from the end of the dictation (the text has
    /// been delivered); a meeting in progress holds it open.
    private func scheduleWarmEnd() {
        guard isActive, meetingStartedAt == nil, dictationPhase == .warm else { return }
        cancelWarmEnd()
        let seconds = MobileSettings.warmWindow.seconds
        guard seconds > 0 else {
            end()
            return
        }
        warmUntil = Date().addingTimeInterval(seconds)
        warmTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.dictationPhase == .warm, self.meetingStartedAt == nil else { return }
                SessionDiagnostics.note("warm window over")
                self.end()
            }
        }
    }

    private func cancelWarmEnd() {
        warmTimer?.invalidate()
        warmTimer = nil
        warmUntil = nil
    }

    func setPreferBuiltInMic(_ prefer: Bool) {
        audio.setPreferBuiltInMic(prefer)
    }

    // MARK: - Results for the keyboard

    func deliver(_ delivery: Delivery) {
        self.delivery = delivery
        publish(force: true)
    }

    func post(notice text: String) {
        notice = Notice(text: text)
        publish(force: true)
    }

    func setLevel(_ level: Float) {
        guard isActive else { return }
        store.level = level
    }

    // MARK: - Background time

    /// Transcription can outlive the session (the user ended it mid-dictation,
    /// or a call interrupted it). Ask iOS for time to finish the request.
    func holdBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish transcription") { [weak self] in
            self?.releaseBackgroundTime()
        }
    }

    func releaseBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Publishing

    private var snapshot: SessionSnapshot {
        SessionSnapshot(
            phase: isActive ? dictationPhase : .off,
            mode: mode,
            recordingStartedAt: recordingStartedAt,
            delivery: delivery,
            notice: notice,
            meetingActive: meetingStartedAt != nil
        )
    }

    private var activityState: VoiceSessionAttributes.ContentState {
        if let meetingStartedAt {
            return .init(phase: .meeting, mode: mode, since: meetingStartedAt)
        }
        switch dictationPhase {
        case .recording: return .init(phase: .recording, mode: mode, since: recordingStartedAt)
        case .processing: return .init(phase: .processing, mode: mode)
        case .warm, .off: return .init(phase: .ready, mode: mode)
        }
    }

    private func publishIfChanged() {
        publish(force: false)
    }

    private func publish(force: Bool) {
        let current = snapshot
        guard force || current != lastPublished else { return }
        if current.phase != lastPublished?.phase {
            SessionDiagnostics.note("phase \(current.phase.rawValue)")
        }
        lastPublished = current
        store.publish(current)
        guard isActive else { return }
        if meetingStartedAt != nil || startedByActionButton {
            if activity.isRunning {
                activity.update(activityState)
            } else if meetingStartedAt != nil, UIApplication.shared.applicationState == .active {
                // Meetings start in the app, so the activity with its Stop
                // button can be requested here.
                activity.start(activityState)
            }
        } else if activity.isRunning {
            activity.end()
        }
    }

    private func beat() {
        store.heartbeat = Date()
    }
}
