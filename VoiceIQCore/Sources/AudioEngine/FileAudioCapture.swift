import AVFoundation
import Foundation

/// For end-to-end tests on a machine without a usable microphone: plays
/// audio files in as the dictation microphone, in real time, one file per
/// dictation in turn, then silence until the dictation stops. Used only when
/// the `DebugDictationAudioFiles` default lists files
/// (`defaults write io.blue.voiceiq DebugDictationAudioFiles -array a.wav b.wav`).
public final class FileAudioCapture: AudioCapturing, @unchecked Sendable {
    public static let defaultsKey = "DebugDictationAudioFiles"
    @MainActor private static var nextFile = 0

    public var onLevel: (@Sendable (Float) -> Void)?
    public var onFirstAudio: (@Sendable () -> Void)?
    public var onDeviceChange: (@Sendable (String) -> Void)?
    public var onWriteFailure: (@Sendable () -> Void)?
    public var onEngineDied: (@Sendable (String) -> Void)?
    public var onSamples: (@Sendable ([Int16]) -> Void)? {
        get { lock.withLock { samplesHandler } }
        set { lock.withLock { samplesHandler = newValue } }
    }

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!
    /// 100 ms of audio per tick, as a microphone delivers it.
    private static let chunk = 1_600

    private let samples: [Int16]
    private let queue = DispatchQueue(label: "io.blue.voiceiq.file-audio")
    private let lock = NSLock()
    private var samplesHandler: (@Sendable ([Int16]) -> Void)?
    private var timer: DispatchSourceTimer?
    private var writer: CAFWriter?
    private var position = 0
    private var framesWritten: Int64 = 0
    private var peakLevel: Float = 0
    private var stopped = false

    private init(samples: [Int16]) {
        self.samples = samples
    }

    /// The next listed file as a recorder; nil when none is listed or it
    /// can't be read (the real microphone is used then).
    @MainActor
    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> FileAudioCapture? {
        guard let paths = defaults.stringArray(forKey: defaultsKey), !paths.isEmpty else { return nil }
        let path = paths[nextFile % paths.count]
        nextFile += 1
        guard let samples = load(URL(fileURLWithPath: path)) else {
            Log.audio.error("debug audio: can't read \(path, privacy: .public) — using the microphone")
            return nil
        }
        Log.audio.notice("debug audio: dictation from \(path, privacy: .public)")
        return FileAudioCapture(samples: samples)
    }

    /// The file as 16 kHz mono Int16, the format the recorder writes.
    static func load(_ url: URL) -> [Int16]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024)
        else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = output.int16ChannelData?[0], output.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    public func start(writingTo url: URL) throws {
        writer = try CAFWriter(url: url, format: Self.format)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    /// Queue. Writes the next 100 ms: the file, then silence.
    private func tick() {
        guard !stopped, let writer,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(Self.chunk)),
              let out = buffer.int16ChannelData?[0] else { return }
        var chunk = [Int16](repeating: 0, count: Self.chunk)
        let available = max(0, min(Self.chunk, samples.count - position))
        if available > 0 { chunk.replaceSubrange(0..<available, with: samples[position..<(position + available)]) }
        position += available
        chunk.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: Self.chunk) }
        buffer.frameLength = AVAudioFrameCount(Self.chunk)
        do {
            try writer.write(buffer)
        } catch {
            Log.audio.error("debug audio: write failed: \(error)")
            return
        }
        let first = framesWritten == 0
        framesWritten += Int64(Self.chunk)
        if first { onFirstAudio?() }
        onSamples?(chunk)
        let meanSquare = chunk.reduce(Float(0)) { $0 + Float($1) * Float($1) } / Float(Self.chunk)
        let level = AudioLevelCurve.level(fromRMS: meanSquare.squareRoot() / 32_768)
        lock.withLock { peakLevel = max(peakLevel, level) }
        onLevel?(level)
    }

    public func stop() async -> AudioCaptureResult {
        timer?.cancel()
        timer = nil
        let frames = queue.sync { () -> Int64 in
            stopped = true
            writer?.close()
            writer = nil
            return framesWritten
        }
        let peak = lock.withLock { peakLevel }
        return AudioCaptureResult(
            framesWritten: frames,
            durationSeconds: Double(frames) / Self.format.sampleRate,
            peakLevel: peak,
            writtenPeakLevel: peak
        )
    }
}
