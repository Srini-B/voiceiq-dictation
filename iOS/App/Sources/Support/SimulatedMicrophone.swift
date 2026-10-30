#if DEBUG
import AVFoundation
import VoiceIQCore

/// Debug builds only: plays a recorded file as the microphone, so the whole
/// keyboard → app → model → keyboard path can run in a Simulator on a Mac with
/// no microphone. Set `VOICEIQ_SIMULATED_MIC` to an audio file path at launch
/// (`SIMCTL_CHILD_VOICEIQ_SIMULATED_MIC=… xcrun simctl launch …`).
final class SimulatedMicrophone: AudioCapturing {
    var onLevel: ((Float) -> Void)?
    var onDeviceChange: ((String) -> Void)?
    var onWriteFailure: (() -> Void)?
    var onEngineDied: ((String) -> Void)?

    private let source: URL
    private var target: URL?
    private var timer: Timer?

    static func make() -> AudioCapturing? {
        guard let path = ProcessInfo.processInfo.environment["VOICEIQ_SIMULATED_MIC"],
              FileManager.default.fileExists(atPath: path) else { return nil }
        return SimulatedMicrophone(source: URL(fileURLWithPath: path))
    }

    private init(source: URL) {
        self.source = source
    }

    func start(writingTo url: URL) throws {
        target = url
        // The file's own loudness, 50 ms at a time and looping, so the
        // keyboard's waveform follows real speech.
        let levels = (try? Self.converted(source)).flatMap { $0 }.map(Self.levels) ?? [0.3]
        var index = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.onLevel?(levels[index % levels.count])
            index += 1
        }
    }

    private static func levels(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let samples = buffer.int16ChannelData?[0] else { return [0.3] }
        let chunk = 800, count = Int(buffer.frameLength)
        return stride(from: 0, to: count, by: chunk).map { start in
            let end = min(start + chunk, count)
            let sum = (start..<end).reduce(Float(0)) { $0 + pow(Float(samples[$1]) / 32_768, 2) }
            return AudioLevelCurve.level(fromRMS: sqrt(sum / Float(end - start)))
        }
    }

    func stop() async -> AudioCaptureResult {
        timer?.invalidate()
        timer = nil
        guard let target, let frames = try? convert(source, to: target) else {
            return AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
        }
        return AudioCaptureResult(framesWritten: frames, durationSeconds: Double(frames) / 16_000,
                                  peakLevel: 0.5, writtenPeakLevel: 0.5)
    }

    private func convert(_ input: URL, to output: URL) throws -> Int64 {
        guard let buffer = try Self.converted(input) else { return 0 }
        try? FileManager.default.removeItem(at: output)
        let out = try AVAudioFile(forWriting: output, settings: buffer.format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try out.write(from: buffer)
        return Int64(buffer.frameLength)
    }

    /// The file as 16 kHz mono Int16, the format the capture engine writes.
    private static func converted(_ input: URL) throws -> AVAudioPCMBuffer? {
        let file = try AVAudioFile(forReading: input)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return nil
        }
        try file.read(into: inBuffer)
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        converter.convert(to: outBuffer, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuffer
        }
        return outBuffer
    }
}
#endif
