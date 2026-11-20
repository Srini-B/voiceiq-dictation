import AVFAudio
import Combine
import UIKit
import VoiceIQBridge
import VoiceIQCore

/// Dictation inside the keyboard, for when no app session is running: the
/// app's own pipeline (`DictationCoordinator`, `GeminiTranscriptionService`,
/// Real-time transcription, writing rules, dictionary, Translate, Ask), wired
/// as `AppModel` wires it, with `WebMicCapture` as the microphone. One per
/// keyboard process, so a keyboard that reappears mid-dictation picks it up.
///
/// Settings and keys come from the app through the App Group
/// (`AppSettingsMirror`, `KeychainStore`). Session folders go to
/// `KeyboardInbox`, which the app adds to History; billed calls are counted
/// in memory and handed over with the folder.
@MainActor
final class KeyboardDictation: ObservableObject {
    static let shared = KeyboardDictation()

    /// `.off` when idle; otherwise `.recording` or `.processing`.
    @Published private(set) var phase: SessionSnapshot.Phase = .off
    @Published private(set) var recordingStartedAt: Date?
    private(set) var bars = LevelBars()
    var liveText: String { phase == .recording ? coordinator?.partialTranscript ?? "" : "" }

    /// The result, typed or shown by the keyboard on screen.
    var onDeliver: ((String, KeyboardMode) -> Void)?
    var onNotice: ((String) -> Void)?
    /// The microphone never started; the tap should go through the app.
    var onStartFailed: (() -> Void)?

    /// Made on the first appearance with Full Access.
    private(set) lazy var mic = WebMicCapture()
    private var coordinator: DictationCoordinator?
    private let inserter = KeyboardInserter()
    private let target = DictationTarget()
    private var cancellables: Set<AnyCancellable> = []
    private var folder: URL?
    private var processingSince: Date?
    private var previousState: DictationState = .idle
    private var hiddenFinalize: DispatchWorkItem?

    /// Why this tap cannot dictate in the keyboard, or nil when it can.
    func blocker() -> String? {
        if !mic.isReady { return "capture page not ready" }
        if !AppSettingsMirror.apply() { return "app settings not shared yet" }
        if !KeychainStore.hasModelKey { return "no key for the selected provider" }
        if AVAudioApplication.shared.recordPermission != .granted { return "microphone not allowed" }
        if phase != .off { return "a dictation is running" }
        return nil
    }

    /// Starts a dictation. Call `blocker()` first.
    func start(mode: KeyboardMode, selectedText: String?, host: String?) -> Bool {
        let coordinator = self.coordinator ?? makeCoordinator()
        target.host = host
        let dictationMode: DictationMode
        switch mode {
        case .dictate: dictationMode = .dictate
        case .translate: dictationMode = .translate(targets: SettingsStore().translationTargetLanguages)
        case .ask: dictationMode = .askAnything(selectedText: selectedText)
        }
        guard coordinator.handle(.begin, mode: dictationMode) else {
            KeyboardLog.note("in-keyboard start refused: \(coordinator.coachingHint ?? "busy")")
            return false
        }
        coordinator.handle(.lockIn)
        return true
    }

    func stop() {
        guard case .recording = coordinator?.state else { return }
        coordinator?.handle(.finalize)
    }

    func cancel() {
        coordinator?.handle(.cancel)
    }

    /// A keyboard is on screen: the page moves into it.
    func keyboardAppeared(in view: UIView) {
        hiddenFinalize?.cancel()
        hiddenFinalize = nil
        mic.attach(to: view)
    }

    /// No keyboard is on screen. A recording that no keyboard takes over
    /// within two seconds is finished, so the mic is never left open behind
    /// the user; the words are kept.
    func keyboardHidden() {
        guard phase == .recording else { return }
        let work = DispatchWorkItem { [weak self] in
            KeyboardLog.note("keyboard hidden while recording in the keyboard; finishing")
            self?.stop()
        }
        hiddenFinalize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Wiring

    private init() {
        LevelGlowSource.levels = { [unowned self] in
            self.phase == .recording ? self.bars.heights : SharedStore.shared.levelBars
        }
    }

    private func makeCoordinator() -> DictationCoordinator {
        FileLayout.overrideRoot = KeyboardInbox.root
        UsageMeter.store = try? UsageStore.inMemory()
        let client = GeminiClient(
            apiKey: { KeychainStore.loadAPIKey() },
            openAIKey: { KeychainStore.loadOpenAIKey() },
            openAIConfig: { SettingsStore().openAIConfig },
            provider: { SettingsStore().preferredProvider },
            elevenLabsKey: { KeychainStore.loadKey(.elevenLabs) }
        )
        let target = self.target
        let coordinator = DictationCoordinator(
            audioFactory: { [mic] in mic },
            transcription: GeminiTranscriptionService(client: client),
            insertion: inserter,
            contextProvider: {
                DictationContext(targetAppBundleID: target.host, targetAppName: target.host.map(AppNames.displayName(for:)))
            },
            liveFactory: { _ in LiveTranscriber.makeFromSettings() }
        )
        inserter.onDeliver = { [weak self] text, mode in self?.onDeliver?(text, mode) }
        coordinator.onAnswerReady = { [weak self] answer in self?.onDeliver?(answer, .ask) }
        coordinator.onStageTimes = { stages in KeyboardLog.note(DictationNotice.stepsLine(stages)) }
        coordinator.$state
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &cancellables)
        coordinator.$micLevel
            .sink { [weak self] level in
                guard let self, self.phase == .recording else { return }
                self.bars.append(level)
            }
            .store(in: &cancellables)
        self.coordinator = coordinator
        return coordinator
    }

    private func stateChanged(_ state: DictationState) {
        defer { previousState = state }
        switch state {
        case .warming, .recording:
            // The folder exists only once the engine is up.
            if folder == nil { folder = coordinator?.activeSessionFolder }
            if recordingStartedAt == nil {
                recordingStartedAt = Date()
                bars = LevelBars()
                KeyboardLog.note("in-keyboard dictation started (host: \(target.host ?? "unknown"))")
            }
            phase = .recording
        case .finalizing, .transcribing, .inserting:
            recordingStartedAt = nil
            phase = .processing
            if processingSince == nil { processingSince = Date() }
        case .idle, .done, .cancelled, .failed:
            guard state != previousState else { return }
            if let since = processingSince {
                KeyboardLog.note(String(format: "processed in %.1fs (keyboard)", Date().timeIntervalSince(since)))
            }
            processingSince = nil
            recordingStartedAt = nil
            phase = .off
            bars = LevelBars()
            if state != .cancelled, let reason = mic.startFailure {
                // Nothing was recorded; the app records this one instead.
                if let folder { try? FileManager.default.removeItem(at: folder) }
                folder = nil
                KeyboardLog.note("in-keyboard microphone did not start (\(reason)); going through the app")
                onStartFailed?()
                return
            }
            hand(over: folder)
            folder = nil
            if let coordinator, let message = DictationNotice.message(for: state, coordinator: coordinator) {
                onNotice?(message)
            }
        }
    }

    /// The dictation is over: its folder and billed calls go to the app.
    private func hand(over folder: URL?) {
        guard let folder else { return }
        let id = SessionMeta.read(from: folder)?.id.uuidString
        let usage = id.map { UsageMeter.store?.records(forSession: $0) ?? [] } ?? []
        KeyboardInbox.finish(folder: folder, usage: usage)
        UsageMeter.store?.deleteAll()
    }
}
