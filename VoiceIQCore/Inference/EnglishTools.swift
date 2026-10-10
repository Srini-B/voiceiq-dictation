import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Optional components from the installed English tools pack (`vqe`, `vad`,
/// `ctc` under one root). Every load is local; a missing or broken component
/// disables only itself and the base model still runs.
struct EnglishTools: Sendable {
    var enhancer: LocalVqeManager?
    var vad: VadManager?
    var vocabulary: ParakeetVocabulary?

    static func load(root: URL?, vocabulary terms: [CustomVocabularyTerm] = []) async throws -> EnglishTools {
        guard let root else {
            Log.transcription.notice("English tools not installed; using base model audio path")
            return EnglishTools()
        }
        var tools = EnglishTools()
        do {
            tools.enhancer = try LocalVqeManager(
                config: LocalVqeConfig(variant: .v13, chunk: .batch256ms),
                modelDirectory: root.appendingPathComponent("vqe", isDirectory: true)
            )
        } catch {
            Log.transcription.notice("Speech enhancement unavailable; using raw audio: \(error.localizedDescription, privacy: .public)")
        }
        try Task.checkCancellation()
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(
                contentsOf: root.appendingPathComponent("vad", isDirectory: true)
                    .appendingPathComponent(ModelNames.VAD.sileroVadFile),
                configuration: configuration
            )
            tools.vad = VadManager(config: VadConfig(defaultThreshold: SpeechBoundaries.threshold), vadModel: model)
        } catch {
            Log.transcription.notice("Voice activity detection unavailable: \(error.localizedDescription, privacy: .public)")
        }
        try Task.checkCancellation()
        if !terms.isEmpty {
            do {
                tools.vocabulary = try await ParakeetVocabulary.load(
                    from: root.appendingPathComponent("ctc", isDirectory: true), terms: terms
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.transcription.notice("Vocabulary spotting unavailable; using base transcript: \(error.localizedDescription, privacy: .public)")
            }
        }
        try Task.checkCancellation()
        return tools
    }
}

/// One LocalVQE clip. Output lags input by the model delay; `finish()` drains
/// the tail and proves every input sample came back exactly once.
actor SpeechEnhancerStream {
    private let stream: LocalVqeStream
    private var received = 0
    private var delivered = 0

    init(_ manager: LocalVqeManager) async throws {
        stream = try await manager.makeStream()
    }

    func push(_ samples: [Float]) async throws -> [Float] {
        received += samples.count
        let out = try await stream.enhance(mic: samples, reference: [Float](repeating: 0, count: samples.count))
        delivered += out.count
        guard delivered <= received else { throw LocalVqeError.modelProcessingFailed("enhanced output overran input") }
        return out
    }

    func finish() async throws -> [Float] {
        let tail = try await stream.flush()
        delivered += tail.count
        guard delivered == received else {
            throw LocalVqeError.modelProcessingFailed("enhanced \(delivered) of \(received) samples")
        }
        return tail
    }

    /// Enhances a whole recording; the result is sample-aligned with `samples`.
    static func enhance(_ samples: [Float], with manager: LocalVqeManager) async throws -> [Float] {
        let stream = try await SpeechEnhancerStream(manager)
        var out = try await stream.push(samples)
        out += try await stream.finish()
        return out
    }
}

enum SpeechAudio {
    /// Recordings up to five minutes (19.2 MB per Float copy) are processed
    /// whole in memory with enhancement, VAD trimming and vocabulary
    /// rescoring. Longer recordings stream from disk so memory stays bounded.
    static let wholeFileFrames: Int64 = 5 * 60 * 16_000

    static func fitsInMemory(_ frames: Int64) -> Bool { frames <= wholeFileFrames }

    /// Reads the raw 16 kHz mono recording, rejecting any length mismatch.
    @discardableResult
    static func validate(_ url: URL, frames: Int64) throws -> AVAudioFile {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length == frames, file.fileFormat.sampleRate == 16_000, file.fileFormat.channelCount == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return file
    }

    static func read(_ url: URL, frames: Int64) throws -> [Float] {
        let file = try validate(url, frames: frames)
        guard frames >= 0, fitsInMemory(frames) else { throw CocoaError(.fileReadTooLarge) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if frames > 0 { try file.read(into: buffer, frameCount: AVAudioFrameCount(frames)) }
        guard Int64(buffer.frameLength) == frames else { throw CocoaError(.fileReadCorruptFile) }
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// Delivers every frame of the validated recording in order, at most
    /// `size` frames at a time.
    static func forEachChunk(
        _ url: URL, frames: Int64, size: Int, _ body: ([Float]) async throws -> Void
    ) async throws {
        let file = try validate(url, frames: frames)
        guard size > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(size)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var delivered: Int64 = 0
        while delivered < frames {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(size), frames - delivered)))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
            delivered += Int64(buffer.frameLength)
            try await body(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
        }
    }

    /// Whole-file enhancement. No output has been shown yet, so a failure
    /// falls back to the raw audio instead of rejecting the transcript.
    static func enhanced(_ samples: [Float], with manager: LocalVqeManager?) async throws -> [Float] {
        guard let manager, !samples.isEmpty else { return samples }
        do {
            let out = try await SpeechEnhancerStream.enhance(samples, with: manager)
            return out
        } catch {
            try Task.checkCancellation()
            Log.transcription.notice("Speech enhancement failed; using raw audio: \(error.localizedDescription, privacy: .public)")
            return samples
        }
    }
}
