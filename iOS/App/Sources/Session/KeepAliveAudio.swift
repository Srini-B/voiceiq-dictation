import AVFoundation
import VoiceIQCore

/// The audio session behind a voice session: a `.playAndRecord` session the
/// dictation's capture engine records into, plus looping silence and a
/// discarding input tap that keep the app running with the mic open (the
/// orange dot shows), plus interruption handling.
///
/// iOS lets a backgrounded app start a *mixable* recording only while it is
/// already recording. Measured on device (builds 13–15): with silent playback
/// alone, or with a Live Activity up, every in-place start failed; with the
/// mic held open, it worked. A non-mixable "background audio" keeper that left
/// the mic closed was tried in 0.6.x and removed: it did not start in place
/// either. `MobileSettings.warmWindow` decides how long the mic stays open
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
    /// The microphone choice of the dictation in progress; nil between
    /// dictations, when the session holds the iPhone's mic.
    private var dictationChoice: MobileSettings.MicrophoneChoice?

    func start() throws {
        guard !isRunning else { return }
        dictationChoice = nil
        try configureSession()
        try startSilence()
        observe()
        isRunning = true
        Log.audio.info("keep-alive started")
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

    /// A dictation is about to start: move to the input its microphone choice
    /// picks. Called before its capture engine starts.
    func useDictationInput(_ choice: MobileSettings.MicrophoneChoice) {
        guard isRunning else { return }
        dictationChoice = choice
        try? configureSession()
        let input = AVAudioSession.sharedInstance().preferredInput?.portName ?? "iOS default"
        Log.audio.info("dictation input (\(choice.rawValue, privacy: .public)): \(input, privacy: .public)")
    }

    /// The dictation is over: back to the iPhone's mic, without Bluetooth
    /// hands-free, for the rest of the warm session.
    func useKeepAliveInput() {
        guard isRunning, dictationChoice != nil else { return }
        dictationChoice = nil
        try? configureSession()
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Mix with others so music and podcasts keep playing. HFP Bluetooth is
        // only allowed while a dictation set to Bluetooth records: enabling it
        // moves AirPods or a car to the low-quality call profile for
        // everything they play.
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        if dictationChoice == .bluetooth { options.insert(.allowBluetoothHFP) }
        // Voice isolation: the capture engine turns on voice processing, and a
        // dictation records in the voice-chat mode that goes with it. Between
        // dictations the session goes back to the default mode. After Hex (MIT,
        // github.com/anomalyco/hex 492d8c28, ios/HEXMobile/AudioBackend.swift).
        let mode: AVAudioSession.Mode = dictationChoice != nil && SettingsStore().voiceIsolation ? .voiceChat : .default
        // Voice chat turns on hands-free Bluetooth by itself, so the options
        // read back with it even though they were set without it.
        var current = session.categoryOptions
        if mode == .voiceChat, !options.contains(.allowBluetoothHFP) { current.remove(.allowBluetoothHFP) }
        // Setting the same category again can still renegotiate the route, so
        // a dictation that changes nothing leaves it alone.
        if session.category != .playAndRecord || session.mode != mode || current != options {
            try session.setCategory(.playAndRecord, mode: mode, options: options)
        }
        try session.setActive(true)
        applyPreferredInput()
    }

    /// The warm session always pins the iPhone's mic, so it never holds a car
    /// or headset in call audio between dictations. A dictation takes the
    /// first input its choice lists that iOS offers. The port orders follow
    /// Hex (MIT, github.com/anomalyco/hex, ios/HEXShared/MicrophoneChoice.swift).
    private func applyPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let ports: [AVAudioSession.Port] = switch dictationChoice {
        case nil, .iPhone: [.builtInMic]
        case .automatic: [.headsetMic, .usbAudio, .carAudio, .builtInMic]
        case .bluetooth: [.headsetMic, .usbAudio, .carAudio, .bluetoothHFP, .bluetoothLE, .builtInMic]
        }
        let input = ports.lazy.compactMap { port in inputs.first(where: { $0.portType == port }) }.first
        // The route change this causes calls back here; only a real change is applied.
        guard session.preferredInput?.uid != input?.uid else { return }
        try? session.setPreferredInput(input)
    }

    // MARK: - Silence

    private func startSilence() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Holds the microphone open. Buffers are dropped; nothing is recorded.
        // The tap runs on the audio thread: @Sendable keeps the block off the
        // main actor, whose isolation check would stop the app there.
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        if inputFormat.sampleRate > 0, inputFormat.channelCount > 0 {
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable _, _ in }
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
        engine?.inputNode.removeTap(onBus: 0)
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
