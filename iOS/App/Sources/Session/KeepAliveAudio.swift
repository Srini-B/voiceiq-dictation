import AVFoundation
import VoiceIQCore

/// What each keeper asks of the audio session.
extension MobileSettings.KeepActiveMode {
    /// A discarding input tap keeps the mic open (the orange dot shows).
    var holdsMicOpen: Bool { self == .openMic }
    /// Whether other apps' audio keeps playing. iOS refuses to start a
    /// *mixable* recording from the background (`'!rec'`,
    /// CoreAudioTypes/AudioSessionTypes.h), so the background-audio keeper
    /// gives up mixing: that is what lets a dictation start in place with the
    /// mic closed meanwhile.
    var mixesWithOthers: Bool { self != .backgroundAudio }
}

/// The audio session behind a voice session: a `.playAndRecord` session the
/// dictation's capture engine records into, plus looping silence that keeps
/// the app running, plus interruption handling.
///
/// What else it does depends on the keeper (`MobileSettings.KeepActiveMode`):
/// - Keep mic on: holds the mic open for the warm window.
/// - Background audio: a non-mixable session; the mic stays closed until a
///   dictation starts.
///
/// iOS lets a backgrounded app start a *mixable* recording only while it is
/// already recording. Measured on device (builds 13–15, all with
/// `.mixWithOthers`): with silent playback alone, or with a Live Activity up,
/// every in-place start failed; with the mic held open, it worked. The
/// background-audio keeper is the untested case: a non-mixable session, which
/// the SDK header says is allowed to start recording from the background. The
/// warm window, set in Settings › Dictation, decides how long a keeper lasts
/// after a dictation.
///
/// The session must be started while the app is in the foreground, or inside
/// the Action button's audio-recording intent: iOS refuses to activate an
/// audio session from the background otherwise.
@MainActor
final class KeepAliveAudio {
    /// An interruption (a call, Siri) began. The mic is gone until it ends.
    var onInterruptionBegan: (() -> Void)?
    /// The session could not be brought back after an interruption.
    var onLost: ((String) -> Void)?

    private(set) var isRunning = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observers: [NSObjectProtocol] = []
    private var preferBuiltInMic = true
    private var keeper: MobileSettings.KeepActiveMode = .openMic

    func start(preferBuiltInMic: Bool, keeper: MobileSettings.KeepActiveMode) throws {
        guard !isRunning else { return }
        self.preferBuiltInMic = preferBuiltInMic
        self.keeper = keeper
        try configureSession()
        try startSilence()
        observe()
        isRunning = true
        Log.audio.info("keep-alive started (keeper: \(keeper.rawValue, privacy: .public), built-in mic preferred: \(preferBuiltInMic), mic held open: \(keeper.holdsMicOpen), mixable: \(keeper.mixesWithOthers))")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        stopSilence()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Log.audio.info("keep-alive stopped")
    }

    /// Re-applies the input preference, e.g. after the setting changes.
    func setPreferBuiltInMic(_ prefer: Bool) {
        preferBuiltInMic = prefer
        guard isRunning else { return }
        try? configureSession()
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Mix with others so music and podcasts keep playing, except for the
        // keeper that needs a non-mixable session. HFP Bluetooth is only
        // allowed when the user wants their headset mic: enabling it moves
        // AirPods to the low-quality call profile for everything they play.
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        if keeper.mixesWithOthers { options.insert(.mixWithOthers) }
        if !preferBuiltInMic { options.insert(.allowBluetoothHFP) }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
        applyPreferredInput()
    }

    private func applyPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        if preferBuiltInMic {
            let builtIn = session.availableInputs?.first { $0.portType == .builtInMic }
            try? session.setPreferredInput(builtIn)
        } else {
            try? session.setPreferredInput(nil)
        }
    }

    // MARK: - Silence

    private func startSilence() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Holds the microphone open. Buffers are dropped; nothing is recorded.
        // Touching `inputNode` at all opens the mic, so the other keeper
        // leaves it alone.
        if keeper.holdsMicOpen {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            if inputFormat.sampleRate > 0, inputFormat.channelCount > 0 {
                input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { _, _ in }
            }
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
            }
        }
        engine.prepare()
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
        self.player = player

        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartSilence(reason: "configuration change") }
        })
    }

    private func stopSilence() {
        player?.stop()
        if keeper.holdsMicOpen { engine?.inputNode.removeTap(onBus: 0) }
        engine?.stop()
        player = nil
        engine = nil
    }

    private func restartSilence(reason: String) {
        guard isRunning else { return }
        Log.audio.info("keep-alive restarting: \(reason, privacy: .public)")
        stopSilence()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try startSilence()
        } catch {
            Log.audio.error("keep-alive restart failed: \(String(describing: error), privacy: .public)")
            onLost?("VoiceiQ lost the audio session")
        }
    }

    // MARK: - Interruptions

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in self?.handleInterruption(type, options: options) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPreferredInput() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                do { try self.configureSession() } catch {}
                self.restartSilence(reason: "media services reset")
            }
        })
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        guard isRunning, let type else { return }
        switch type {
        case .began:
            Log.audio.info("audio interruption began")
            onInterruptionBegan?()
        case .ended:
            Log.audio.info("audio interruption ended (resume: \(options.contains(.shouldResume)))")
            restartSilence(reason: "interruption ended")
        @unknown default:
            break
        }
    }
}
