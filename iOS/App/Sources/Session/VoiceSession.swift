import Foundation
import UIKit
import VoiceIQBridge
import WidgetKit
import VoiceIQCore

/// The background voice session: the open mic that lets keyboard taps record
/// in place, and everything the keyboard reads from the App Group.
///
/// A session starts when a keyboard tap opens the app (the one-time bounce)
/// or when the Action button runs `ToggleDictationIntent`. `KeepAliveAudio`
/// holds the mic open for `MobileSettings.warmWindow` after each dictation,
/// then the session ends ("Never" ends it as soon as the text is delivered). Once it ends, the next keyboard tap
/// bounces again. The Live Activity, with Stop and Cancel for when no keyboard
/// is on screen, is up for the whole session
/// (`MobileSettings.showsSessionActivity`); sessions the Action button started
/// (iOS requires one for an audio-recording intent) and meetings always have it.
@MainActor
final class VoiceSession: ObservableObject {
    @Published private(set) var isActive = false
    /// When the warm window runs out, while it is counting.
    @Published private(set) var warmUntil: Date?

    /// What the dictation pipeline is doing. Set by the app model.
    @Published var dictationPhase: SessionSnapshot.Phase = .warm {
        didSet {
            // A dictation begun in this process is newer than the one an
            // earlier process left: that one's recovered text stays in History.
            if dictationPhase.hasDictation { orphan = nil }
            publishIfChanged()
            if dictationPhase != oldValue { phaseChanged() }
        }
    }
    var recordingStartedAt: Date? { didSet { publishIfChanged() } }
    /// Where the dictation in progress will land. Set by the app model.
    var dictationField: FieldIdentity? { didSet { publishIfChanged() } }
    /// A dictation an earlier process was recording or writing when iOS
    /// ended it, and when that process last ran. The launch recovery takes it
    /// so the recovered text still reaches its field, unless a new dictation
    /// began first.
    private(set) var orphan: (field: FieldIdentity, lastAlive: Date)?
    var meetingStartedAt: Date? {
        didSet {
            publishIfChanged()
            if meetingStartedAt == nil, oldValue != nil { becameIdle() }
            // A meeting keeps the session on: no warm deadline while it runs.
            if meetingStartedAt != nil, oldValue == nil { cancelWarmEnd() }
        }
    }

    var onInterruptionBegan: (() -> Void)?

    private let audio = KeepAliveAudio()
    private let activity = LiveActivityController()
    private let store = SharedStore.shared
    private var heartbeat: Timer?
    private var warmTimer: Timer?
    /// Waits for a model load that is finishing as a warm-up before ending.
    private var warmHold: Task<Void, Never>?
    private var delivery: Delivery?
    /// The transcript offered as a draft while the writing model works
    /// (`SessionSnapshot.draft`). Never carried over from an earlier process.
    private var draft: Delivery?
    private var notice: Notice?
    private var lastPublished: SessionSnapshot?
    private var bars = LevelBars()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// The Action button started this session, so it carries a Live Activity.
    private var startedByActionButton = false

    init() {
        LiveActivityController.endLeftovers()
        // Whatever an earlier process left in the App Group is stale, except
        // the last result and where an unfinished dictation was going.
        let left = store.snapshot
        delivery = left.delivery.map { $0.isPending(handledID: store.insertedDeliveryID) ? $0 : $0.forgettingDraft() }
        if left.phase == .recording || left.phase == .processing, let field = left.field, let lastAlive = store.heartbeat {
            orphan = (field, lastAlive)
        }
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
        try audio.start()
        isActive = true
        startedByActionButton = fromActionButton
        if wantsActivity { activity.start(activityState) }
        heartbeat = Timer.scheduledTimer(withTimeInterval: SharedStore.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
        beat()
        publish(force: true)
        SessionDiagnostics.note("session began (\(fromActionButton ? "action button" : "keyboard")), warm window \(MobileSettings.warmWindow.label)")
        // The dictation that opened the session starts right after this. If
        // none does (it was refused), count the warm window from now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isActive, self.dictationPhase == .warm, self.warmTimer == nil, self.warmHold == nil else { return }
            self.scheduleWarmEnd()
        }
    }

    /// Whether a dictation can start without opening the app.
    var canRecordInBackground: Bool {
        isActive && audio.isRunning
    }

    func end() {
        guard isActive else { return }
        isActive = false
        startedByActionButton = false
        cancelWarmEnd()
        heartbeat?.invalidate()
        heartbeat = nil
        store.heartbeat = nil
        clearDictationTrace()
        audio.stop()
        activity.end()
        publish(force: true)
        SessionDiagnostics.note("session ended")
    }

    // MARK: - Warm window

    private func phaseChanged() {
        // Each dictation starts with an empty glow and no words.
        clearDictationTrace()
        guard isActive else { return }
        switch dictationPhase {
        case .starting, .recording:
            cancelWarmEnd()
        case .warm:
            audio.useKeepAliveInput()
            becameIdle()
        default:
            break
        }
    }

    /// Back to the iPhone's mic for the warm session, once a dictation's
    /// capture has stopped.
    func useKeepAliveInput() {
        guard isActive else { return }
        audio.useKeepAliveInput()
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
            endAfterModelLoad()
            return
        }
        warmUntil = Date().addingTimeInterval(seconds)
        warmTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.dictationPhase == .warm, self.meetingStartedAt == nil else { return }
                SessionDiagnostics.note("warm window over")
                self.endAfterModelLoad()
            }
        }
    }

    /// A cold model load that outlived its dictation goes on as a warm-up
    /// (`LocalModelWarmup`). The mic stays open until it ends, so iOS does not
    /// suspend the app with the load half done; the next dictation then loads
    /// fast. Without a load in progress the session ends now. The hold is
    /// bounded by `TimeoutPolicy.localLoad`: a stalled load must not keep the
    /// mic open indefinitely.
    private func endAfterModelLoad() {
        guard LocalModelWarmup.isLoading else {
            end()
            return
        }
        SessionDiagnostics.note("session held open for the model load")
        warmHold = Task { [weak self] in
            let ended = await Self.modelLoadEnded(within: TimeoutPolicy.localLoad)
            guard let self, !Task.isCancelled, self.dictationPhase == .warm, self.meetingStartedAt == nil else { return }
            if !ended {
                SessionDiagnostics.note(String(format: "model load still running after %.0fs; session ended", TimeoutPolicy.localLoad))
            }
            self.warmHold = nil
            self.end()
        }
    }

    /// True when every model load ended within `seconds`.
    private static func modelLoadEnded(within seconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await LocalModelWarmup.finished(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// The picker changed. An idle session takes the new window from now;
    /// "Never" ends it at once. A dictation in progress picks it up when it
    /// returns to `.warm`.
    func warmWindowChanged() {
        guard isActive, dictationPhase == .warm, meetingStartedAt == nil else { return }
        scheduleWarmEnd()
    }

    private func cancelWarmEnd() {
        warmTimer?.invalidate()
        warmTimer = nil
        warmUntil = nil
        warmHold?.cancel()
        warmHold = nil
    }

    /// A dictation is about to start its capture: move to the input
    /// Settings › Dictation › Microphone picks. It returns to the iPhone's
    /// mic once transcription starts, and again at `.warm`.
    func useDictationInput() {
        audio.useDictationInput(MobileSettings.microphoneChoice)
    }

    // MARK: - Results for the keyboard

    func deliver(_ delivery: Delivery) {
        self.delivery = delivery
        publish(force: true)
    }

    /// Offers the transcript as a draft (`KeyboardInserter`), or withdraws it with nil.
    func showDraft(_ draft: Delivery?) {
        guard draft != self.draft else { return }
        self.draft = draft
        publish(force: true)
    }

    /// A keyboard typed the result, or the app copied it.
    func resultSettled() {
        forgetDraftIfSettled()
        refreshActivity()
    }

    /// The fingerprint of the destination's text is needed only while the
    /// result is pending. Typed, copied or too old, the result drops it.
    private func forgetDraftIfSettled() {
        guard let settled = delivery, settled.destination?.draft != nil,
              !settled.isPending(handledID: store.insertedDeliveryID) else { return }
        delivery = settled.forgettingDraft()
        publish(force: true)
    }

    /// The launch recovery used the orphan, or found nothing to recover.
    func takeOrphan() -> (field: FieldIdentity, lastAlive: Date)? {
        defer { orphan = nil }
        return orphan
    }

    /// A result that belongs in a field and has not reached it yet.
    private var resultIsWaiting: Bool {
        guard let delivery, delivery.destination != nil else { return false }
        return delivery.isPending(handledID: store.insertedDeliveryID)
    }

    func post(notice text: String) {
        notice = Notice(text: text)
        publish(force: true)
    }

    func setLevel(_ level: Float) {
        guard isActive, dictationPhase == .recording else { return }
        bars.append(level)
        store.levelBars = bars.heights
    }

    private func clearDictationTrace() {
        bars = LevelBars()
        store.levelBars = []
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
            recordingStartedAt: recordingStartedAt,
            delivery: delivery,
            notice: notice,
            meetingActive: meetingStartedAt != nil,
            field: dictationPhase.hasDictation ? dictationField : nil,
            draft: isActive ? draft : nil
        )
    }

    private var activityState: VoiceSessionAttributes.ContentState {
        if let meetingStartedAt {
            return .init(phase: .meeting, since: meetingStartedAt)
        }
        switch dictationPhase {
        case .starting: return .init(phase: .starting)
        case .recording: return .init(phase: .recording, since: recordingStartedAt)
        case .processing: return .init(phase: .processing)
        case .warm, .off: return .init(phase: resultIsWaiting ? .waiting : .ready)
        }
    }

    /// Keyboard sessions carry the Live Activity when the setting is on;
    /// meetings and Action button sessions always do.
    private var wantsActivity: Bool {
        meetingStartedAt != nil || startedByActionButton || MobileSettings.showsSessionActivity
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
        let wasDictating = lastPublished?.phase.isDictating == true
        lastPublished = current
        store.publish(current)
        if #available(iOS 18.0, *), wasDictating != current.phase.isDictating {
            // The Control Center toggle shows whether a dictation records.
            ControlCenter.shared.reloadControls(ofKind: SharedStore.dictationControlKind)
        }
        refreshActivity()
    }

    /// Brings the Live Activity in line with the session. Also called when
    /// something outside the snapshot changes what it shows: the setting or
    /// the app coming to the front.
    func refreshActivity() {
        guard isActive else { return }
        if wantsActivity {
            if activity.isRunning {
                activity.update(activityState)
            } else if UIApplication.shared.applicationState == .active {
                // ActivityKit refuses a request from the background, so a
                // session that lost its activity gets one back the next time
                // the app is in front.
                activity.start(activityState)
            }
        } else if activity.isRunning {
            activity.end()
        }
    }

    private func beat() {
        store.heartbeat = Date()
        // A waiting result turns into "ready" once it is typed or too old;
        // the keyboard's ping can be missed.
        forgetDraftIfSettled()
        if activity.isRunning { activity.update(activityState) }
    }
}
