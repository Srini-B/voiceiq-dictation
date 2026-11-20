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
/// THIRD_PARTY_NOTICES.md); the mixable session follows anomalyco/hex #2005.
final class WebMicCapture: NSObject, AudioCapturing {
    static let sampleRate = 16_000

    var onLevel: ((Float) -> Void)?
    var onDeviceChange: ((String) -> Void)?
    var onWriteFailure: (() -> Void)?
    var onEngineDied: ((String) -> Void)?

    private(set) var isReady = false
    /// Why the last capture never delivered audio (getUserMedia refused, the
    /// page died), or nil once audio arrived.
    private(set) var startFailure: String?
    private var isCapturing = false
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
            guard isReady else { throw CocoaError(.featureUnsupported) }
            file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            frames = 0
            peak = 0
            writtenPeak = 0
            startFailure = nil
            isCapturing = true
            Self.mixWithOtherAudio()
            heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.webView.evaluateJavaScript("captureHeartbeat(); 0") }
            }
            webView.evaluateJavaScript("startCapture(); 0")
        }
    }

    func stop() async -> AudioCaptureResult {
        await MainActor.run { webView.evaluateJavaScript("stopCapture(); 0") }
        // Chunks the page posted before it stopped are still queued for the
        // main thread; let them reach the file.
        try? await Task.sleep(nanoseconds: 150_000_000)
        return await MainActor.run { finish() }
    }

    @MainActor
    private func finish() -> AudioCaptureResult {
        heartbeat?.invalidate()
        heartbeat = nil
        if isCapturing {
            // Lets music the capture ducked or paused carry on.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        isCapturing = false
        file = nil
        return AudioCaptureResult(framesWritten: frames, durationSeconds: Double(frames) / Double(Self.sampleRate),
                                  peakLevel: peak, writtenPeakLevel: writtenPeak, peakIsTrustworthy: frames > 0)
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
    fileprivate func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
        case "audio":
            guard isCapturing, let base64 = message["data"] as? String, let data = Data(base64Encoded: base64) else { return }
            let level = AudioLevelCurve.level(fromRMS: (message["rms"] as? NSNumber)?.floatValue ?? 0)
            peak = max(peak, level)
            onLevel?(level)
            write(data)
            sink?(data)
        case "interrupted", "failed":
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
    let stopCapture = () => {};
    window.stopCapture = () => stopCapture();
    window.startCapture = async () => {
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
      stopCapture = cleanup;
      try {
        const constraints = { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false };
        const inputs = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'audioinput');
        const builtIn = inputs.find(d => /iphone|ipad|built-in/i.test(d.label));
        if (builtIn) constraints.deviceId = { exact: builtIn.deviceId };
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
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
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
