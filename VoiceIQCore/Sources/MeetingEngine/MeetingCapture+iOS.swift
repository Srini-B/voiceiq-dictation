#if os(iOS)
import AVFoundation
import Foundation
import VoiceIQObjC

/// Records the phone's microphone to a 16 kHz mono CAF for meeting notes.
///
/// The app's audio session must already be active (`.playAndRecord`); this
/// only builds the engine, so it keeps recording after the app is backgrounded.
public final class MicTap: @unchecked Sendable {
    public enum MicError: Error { case format, noDevice }
    private let url: URL
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                       channels: 1, interleaved: true)!
    private let queue = DispatchQueue(label: "io.blue.voiceiq.meeting.mic.io", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var writer: CAFWriter?
    private var frames: Int64 = 0
    private var configObserver: NSObjectProtocol?

    /// Each converted 16 kHz mono Int16 buffer, after it is written; set
    /// before `start`. Feeds the live meeting transcript.
    public var onPCM: (@Sendable (Data) -> Void)?

    public init(url: URL) { self.url = url }

    public func start() throws {
        writer = try CAFWriter(url: url, format: target)
        frames = 0
        try buildEngine()
    }

    public func stop() -> Double {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        queue.sync { writer?.close(); writer = nil }
        Log.meeting.notice("mic stopped: frames=\(self.frames)")
        return Double(frames) / target.sampleRate
    }

    private func buildEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.noDevice }
        guard let converter = AVAudioConverter(from: format, to: target) else { throw MicError.format }
        self.converter = converter
        // AVFAudio raises (and would abort the app) when the route changes
        // while the tap goes in; see AudioCaptureEngine.catchingException.
        try VQObjCException.perform {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.queue.async { self?.write(buffer, rate: format.sampleRate) }
            }
            engine.prepare()
        }
        try engine.start()
        self.engine = engine
        // A route change (AirPods in or out) stops the engine. Rebuild on the new
        // route and keep appending to the same file.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.writer != nil else { return }
            self.engine?.inputNode.removeTap(onBus: 0)
            self.engine = nil
            do { try self.buildEngine() } catch {
                Log.meeting.error("mic rebuild failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, rate: Double) {
        guard let converter, let writer else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / rate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard out.frameLength > 0 else { return }
        do {
            try writer.write(out)
            frames += Int64(out.frameLength)
        } catch { Log.meeting.error("mic write failed: \(String(describing: error), privacy: .public)") }
        onPCM?(out.int16Data)
    }
}

/// iOS does not let an app record other apps' audio or call audio. The meeting
/// pipeline mixes a mic file with a system file, so this writes an empty one.
public final class SystemAudioTap: @unchecked Sendable {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func start() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        CAFWriter.touch(url: url, format: format)
    }

    public func stop() -> Double { 0 }
}

/// Call detection reads other apps' audio and windows, which iOS forbids.
@MainActor public final class CallDetector {
    public var onChange: ((CallSource?) -> Void)?
    public init() {}
    public func start() {}
    public func stop() {}
}

extension CAFWriter {
    static func touch(url: URL, format: AVAudioFormat) {
        (try? CAFWriter(url: url, format: format))?.close()
    }
}
#endif
