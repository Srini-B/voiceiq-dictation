import AVFoundation
import FluidAudio
import Foundation
import VoiceIQSpeech

/// Transcribes and diarizes one saved meeting mix with the two on-device
/// models, one after the other so only one model is in memory at a time.
/// Both read the file from disk in pieces, so a two-hour meeting costs no
/// more memory than a short one.
enum LocalMeetingJob {
    enum Failure: LocalizedError {
        case noTimings
        var errorDescription: String? {
            switch self {
            case .noTimings: return "Fluid Speech Mini returned no word timings."
            }
        }
    }

    /// Diarizer input per read: one minute of 16 kHz audio.
    static let diarizerChunk = 60 * 16_000

    static func run(_ request: LocalMeetingRequest) async throws -> LocalMeetingResult {
        let started = Date()
        let words = try await transcribe(request.audio, models: request.speechDirectory)
        try Task.checkCancellation()
        let spoken = Date()
        let segments = try await diarize(request.audio, models: request.diarizerDirectory)
        Log.transcription.notice("Local meeting: \(words.count) words in \(spoken.timeIntervalSince(started), format: .fixed(precision: 1))s, \(segments.count) speaker stretches in \(Date().timeIntervalSince(spoken), format: .fixed(precision: 1))s")
        return LocalMeetingResult(words: words, segments: segments)
    }

    private static func transcribe(_ audio: URL, models directory: URL) async throws -> [LocalMeetingResult.Word] {
        let models = try await AsrModels.loadLocal(from: directory, version: .v3)
        let manager = AsrManager(config: .default, models: models)
        var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await manager.transcribeDiskBacked(audio, decoderState: &decoder, language: .english)
        } catch {
            await manager.cleanup()
            throw error
        }
        // Released before the diarizer loads, so the two never share memory.
        await manager.cleanup()
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noTimings }
            return []
        }
        return words(timings)
    }

    /// Tokens joined into words at SentencePiece boundaries: a token with a
    /// leading space starts a word. Timings are encoder-frame emissions and
    /// run up to two frames (160 ms) ahead of the audio, which the join by
    /// time tolerates.
    static func words(_ timings: [TokenTiming]) -> [LocalMeetingResult.Word] {
        var out: [LocalMeetingResult.Word] = []
        for timing in timings {
            let piece = timing.token
            if piece.hasPrefix(" ") || out.isEmpty {
                let text = piece.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                out.append(.init(text: text, start: timing.startTime, end: max(timing.endTime, timing.startTime)))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].end = max(out[out.count - 1].end, timing.endTime)
            }
        }
        return out
    }

    private static func diarize(_ audio: URL, models directory: URL) async throws -> [LocalMeetingResult.Segment] {
        let config = Nemotron3Config.offline
        let models = try await Nemotron3Models.load(config: config, directory: directory)
        let diarizer = Nemotron3Diarizer(config: config, models: models)
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        var probabilities: [Float] = []
        var frames = 0
        var speakers = 8
        func collect(_ results: [Nemotron3ChunkResult]) {
            for result in results {
                probabilities += result.probabilities
                frames += result.frameCount
                speakers = result.numSpeakers
            }
        }
        try await SpeechAudio.forEachChunk(audio, frames: file.length, size: diarizerChunk) { samples in
            diarizer.appendAudio(samples)
            collect(try diarizer.processBufferedAudio())
        }
        collect(try diarizer.finishStream())
        return Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames, numSpeakers: speakers).map {
            .init(speaker: $0.speakerIndex, start: Double($0.startSeconds), end: Double($0.endSeconds))
        }
    }
}
