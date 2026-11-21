import AVFAudio
import UIKit
import VoiceIQCore
import WebKit

/// The keyboard's microphone: `getUserMedia` in a hidden `WKWebView`.
///
/// iOS refuses to record from a keyboard extension ("is an extension and
/// doesn't have entitlements to record audio"), but WebKit captures in its own
/// processes under the app's microphone permission. The page streams 16 kHz
/// mono Int16 PCM back; this writes it to the session's CAF exactly as
/// `AudioCaptureEngine` does, so `DictationCoordinator` runs on it unchanged:
/// levels, the PCM sink for Real-time transcription, silence trim, failures.
///
/// Adapted from stephancill/ios-keyboard-dictation (MIT, see
/// THIRD_PARTY_NOTICES.md). From anomalyco/hex's KeyboardLocalDictation (MIT):
/// the mixable session (#2005) and asking the audio the capture paused to
/// resume (#2151).
///
/// Sendable by hand: its state is touched only on the main thread (the
/// coordinator, WebKit's callbacks, and `stop`, which hops there).
final class WebMicCapture: NSObject, AudioCapturing, @unchecked Sendable {
    static let sampleRate = 16_000
    /// After a capture ends, long enough for WebKit to have let its audio
    /// session go (anomalyco/hex #2151).
    static let resumeOtherAudioDelay: TimeInterval = 0.5

    var onLevel: (@Sendable (Float) -> Void)?
    var onDeviceChange: (@Sendable (String) -> Void)?
    var onWriteFailure: (@Sendable () -> Void)?
    var onEngineDied: (@Sendable (String) -> Void)?

    private(set) var isReady = false
    /// When the page last sent audio, for the watchdog.
    private(set) var lastAudioAt: Date?
    /// Another app played audio as this capture began, which WebKit's
    /// capture interrupts.
    private var otherAudioAtStart = false
    /// Why the last capture never delivered audio (getUserMedia refused, the
    /// page died, the watchdog), or nil once audio arrived, even late.
    private(set) var startFailure: String?
    private var isCapturing = false
    /// Numbers each capture. The page tags its messages with it, and each
    /// `stop()` finishes the oldest capture not yet stopped: a capture
    /// started while an earlier one's `stop()` is still on its way keeps its
    /// file and its audio.
    private var generation = 0
    private var unstopped: [Int] = []
    /// Results of captures a new `start` closed while their `stop()` waited.
    private var closedResults: [Int: AudioCaptureResult] = [:]
    /// Runs script in the page; tests replace it to drive the capture
    /// without a microphone.
    var runScript: @MainActor (String) -> Void = { _ in }
    private var sink: (@Sendable (Data) -> Void)?
    private var file: AVAudioFile?
    private var frames: Int64 = 0
    private var peak: Float = 0
    private var writtenPeak: Float = 0
    private var heartbeat: Timer?
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!
    private let webView: WKWebView

    @MainActor
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakHandler(self), name: "capture")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // In the window but invisible: WebKit throttles a web view outside one.
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        runScript = { [weak self] script in self?.webView.evaluateJavaScript(script) }
        load()
    }

    /// Puts the page in the keyboard on screen. A keyboard that reappears
    /// mid-dictation takes it over without reloading it.
    @MainActor
    func attach(to view: UIView) {
        guard webView.superview !== view else { return }
        view.addSubview(webView)
        view.sendSubviewToBack(webView)
    }

    func setPCMSink(_ sink: (@Sendable (Data) -> Void)?) { self.sink = sink }

    func start(writingTo url: URL) throws {
        try MainActor.assumeIsolated {
            guard isReady else {
                // WebKit ended after the tap was taken: the app records this one.
                startFailure = "capture page not ready"
                throw CocoaError(.featureUnsupported)
            }
            // An earlier capture whose stop() is still draining: it ends here,
            // and its stop() gets its own result.
            if isCapturing {
                runScript("stopCapture(\(generation)); 0")
                closedResults[generation] = finish()
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            self.file = file
            generation += 1
            unstopped.append(generation)
            frames = 0
            peak = 0
            writtenPeak = 0
            startFailure = nil
            lastAudioAt = Date()
            isCapturing = true
            otherAudioAtStart = otherAudioAtStart || AVAudioSession.sharedInstance().isOtherAudioPlaying
            Self.mixWithOtherAudio()
            heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.runScript("captureHeartbeat(); 0") }
            }
            runScript("startCapture(\(generation)); 0")
        }
    }

    func stop() async -> AudioCaptureResult {
        let stopping = await MainActor.run {
            let oldest = unstopped.isEmpty ? generation : unstopped.removeFirst()
            runScript("stopCapture(\(oldest)); 0")
            return oldest
        }
        // Chunks the page posted before it stopped are still queued for the
        // main thread; let them reach the file.
        try? await Task.sleep(nanoseconds: 150_000_000)
        return await MainActor.run {
            if let closed = closedResults.removeValue(forKey: stopping) { return closed }
            return stopping == generation ? finish() : AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
        }
    }

    /// The watchdog found no audio since the start: if none ever arrived,
    /// this capture never started, which `startFailure` now says.
    @MainActor
    func markStartTimedOut() -> Bool {
        guard isCapturing, frames == 0 else { return false }
        startFailure = startFailure ?? "no audio from the page"
        return true
    }

    @MainActor
    private func finish() -> AudioCaptureResult {
        heartbeat?.invalidate()
        heartbeat = nil
        if isCapturing { resumeOtherAudio() }
        isCapturing = false
        file = nil
        return AudioCaptureResult(framesWritten: frames, durationSeconds: Double(frames) / Double(Self.sampleRate),
                                  peakLevel: peak, writtenPeakLevel: writtenPeak, peakIsTrustworthy: frames > 0)
    }

    /// Asks the music or video the capture paused to carry on, once WebKit
    /// has let its session go and unless another capture started: only when
    /// other audio played at the start and has stopped (anomalyco/hex #2151).
    @MainActor
    private func resumeOtherAudio() {
        guard otherAudioAtStart else { return }
        otherAudioAtStart = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeOtherAudioDelay) { [weak self] in
            guard let self, !self.isCapturing else {
                self?.otherAudioAtStart = true
                return
            }
            let session = AVAudioSession.sharedInstance()
            guard !session.isOtherAudioPlaying else { return }
            do {
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true, options: [])
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                KeyboardLog.note("asked the audio the capture paused to resume")
            } catch {
                KeyboardLog.note("asking paused audio to resume failed: \((error as NSError).code)")
            }
        }
    }

    /// The same session the app's `KeepAliveAudio` uses: mixable, built-in
    /// mic, A2DP output. Music keeps playing and a car or headset never drops
    /// into call audio. The keyboard may set its category; it just cannot
    /// record itself.
    private static func mixWithOtherAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    @MainActor
    private func load() {
        // An https base URL gives the page the secure context getUserMedia needs.
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://voiceiq-keyboard.invalid/"))
    }

    @MainActor
    func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        // A message from an earlier capture (a late chunk, its failure) never
        // touches the current one.
        if let id = message["id"] as? Int, id != generation { return }
        switch type {
        case "ready":
            isReady = true
        case "audio":
            guard isCapturing, let base64 = message["data"] as? String, let data = Data(base64Encoded: base64) else { return }
            let level = AudioLevelCurve.level(fromRMS: (message["rms"] as? NSNumber)?.floatValue ?? 0)
            lastAudioAt = Date()
            peak = max(peak, level)
            onLevel?(level)
            write(data)
            sink?(data)
        case "interrupted", "failed":
            KeyboardLog.note("capture page: \(type) (\(message["reason"] as? String ?? "unknown"))")
            guard isCapturing else { return }
            if frames == 0 { startFailure = message["reason"] as? String ?? type }
            onEngineDied?("Microphone stopped (\(message["reason"] as? String ?? "unknown"))")
        default:
            break
        }
    }

    @MainActor
    private func write(_ data: Data) {
        let count = data.count / 2
        guard count > 0, let file, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        var loudest: Int32 = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            buffer.int16ChannelData![0].update(from: samples.baseAddress!, count: count)
            for sample in samples { loudest = max(loudest, abs(Int32(sample))) }
        }
        do {
            try file.write(from: buffer)
            frames += Int64(count)
            // Audio that arrived late (during stop()'s drain, after the
            // watchdog) means the capture did start.
            startFailure = nil
            writtenPeak = max(writtenPeak, AudioLevelCurve.level(fromRMS: Float(loudest) / 32_768))
        } catch {
            self.file = nil
            onWriteFailure?()
        }
    }

    /// The raw microphone, as `AudioCaptureEngine` records it: no echo
    /// cancellation, noise suppression or gain control.
    private static let page = """
    <!doctype html><html><body><script>
    const targetRate = \(sampleRate);
    const post = m => window.webkit.messageHandlers.capture.postMessage(m);
    const encode = s => {
      const b = new Uint8Array(s.buffer, 0, s.length * 2);
      let t = '';
      for (let i = 0; i < b.length; i += 0x8000) t += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
      return btoa(t);
    };
    let lastHeartbeat = performance.now();
    window.captureHeartbeat = () => { lastHeartbeat = performance.now(); };
    const stops = {};
    window.stopCapture = id => { stops[id]?.(); delete stops[id]; };
    window.startCapture = async id => {
      const post = m => window.webkit.messageHandlers.capture.postMessage({ ...m, id });
      let stopping = false, stream, context, source, processor, sink, watchdog;
      const session = navigator.audioSession;
      const cleanup = () => {
        if (stopping) return;
        stopping = true;
        clearInterval(watchdog);
        if (processor) { processor.onaudioprocess = null; processor.disconnect(); }
        source?.disconnect(); sink?.disconnect();
        stream?.getTracks().forEach(t => t.stop());
        context?.close().catch(() => {});
      };
      const interrupted = reason => { if (!stopping) { cleanup(); post({ type: 'interrupted', reason }); } };
      stops[id] = cleanup;
      try {
        const constraints = { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false };
        const inputs = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'audioinput');
        const builtIn = inputs.find(d => /iphone|ipad|built-in/i.test(d.label));
        if (builtIn) constraints.deviceId = { exact: builtIn.deviceId };
        // A touch cancelled while the devices were listed never opens the mic.
        if (stopping) return;
        stream = await navigator.mediaDevices.getUserMedia({ audio: constraints });
        if (stopping) { stream.getTracks().forEach(t => t.stop()); return; }
        stream.getAudioTracks()[0].onended = () => interrupted('track-ended');
        context = new AudioContext({ latencyHint: 'interactive' });
        await context.resume();
        processor = context.createScriptProcessor(1024, 1, 1);
        sink = context.createGain(); sink.gain.value = 0;
        processor.connect(sink); sink.connect(context.destination);
        source = context.createMediaStreamSource(stream); source.connect(processor);
        context.onstatechange = () => { if (context.state !== 'running') interrupted('context-' + context.state); };
        if (session) session.onstatechange = () => { if (session.state === 'interrupted') interrupted('audio-session-interrupted'); };
        lastHeartbeat = performance.now();
        // The keyboard went away without stopping: never keep the mic.
        watchdog = setInterval(() => { if (performance.now() - lastHeartbeat > 3000) interrupted('heartbeat-expired'); }, 500);
        const step = context.sampleRate / targetRate;
        let position = 0, sum = 0, count = 0;
        processor.onaudioprocess = e => {
          const input = e.inputBuffer.getChannelData(0);
          const out = new Int16Array(Math.ceil(input.length / step) + 1);
          let n = 0, energy = 0;
          for (const x of input) {
            energy += x * x; sum += x; count += 1; position += 1;
            if (position >= step) { position -= step; out[n++] = Math.max(-1, Math.min(1, sum / count)) * 32767; sum = 0; count = 0; }
          }
          if (n > 0) post({ type: 'audio', data: encode(out.subarray(0, n)), rms: Math.sqrt(energy / input.length) });
        };
        post({ type: 'started' });
      } catch (error) {
        if (stopping) return;
        cleanup();
        post({ type: 'failed', reason: error.name + ': ' + error.message });
      }
    };
    post({ type: 'ready' });
    </script></body></html>
    """
}

extension WebMicCapture: WKUIDelegate, WKNavigationDelegate {
    /// The app's microphone permission still applies; this only skips
    /// WebKit's own prompt for the page.
    @MainActor
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            isReady = false
            if isCapturing, frames == 0 { startFailure = "web content process ended" }
            if isCapturing { onEngineDied?("WebKit's capture process ended") }
            load()
        }
    }
}

/// `WKUserContentController` retains its handlers.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebMicCapture?
    init(_ target: WebMicCapture) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.handle(message.body) }
    }
}
