import CoreML
import FluidAudio
import Foundation
import VoiceIQSpeech

/// Transcribes and diarizes one saved meeting mix with the two on-device
/// models, one after the other so only one model is in memory at a time.
enum LocalMeetingJob {
    enum Failure: LocalizedError {
        case noTimings
        var errorDescription: String? {
            switch self {
            case .noTimings: return "The speech model returned no word timings."
            }
        }
    }

    static func run(_ request: LocalMeetingRequest) async throws -> LocalMeetingResult {
        let started = Date()
        var words: [LocalMeetingResult.Word] = []
        if let speech = request.speechDirectory { words = try await transcribe(request.audio, models: speech) }
        try Task.checkCancellation()
        let spoken = Date()
        guard let diarizerDirectory = request.diarizerDirectory else {
            Log.transcription.notice("Local meeting: \(words.count) words in \(spoken.timeIntervalSince(started), format: .fixed(precision: 1))s, no diarizer")
            return LocalMeetingResult(words: words, segments: [])
        }
        let segments = try await diarize(request.audio, models: diarizerDirectory)
        Log.transcription.notice("Local meeting: \(words.count) words in \(spoken.timeIntervalSince(started), format: .fixed(precision: 1))s, \(segments.count) speaker stretches in \(Date().timeIntervalSince(spoken), format: .fixed(precision: 1))s")
        return LocalMeetingResult(words: words, segments: segments)
    }

    private static func transcribe(_ audio: URL, models directory: URL) async throws -> [LocalMeetingResult.Word] {
        let models = try await AsrModels.loadLocal(from: directory, version: .v3)
        let manager = AsrManager(config: .default, models: models)
        var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result: ASRResult
        do {
            // No language hint: with Fluid Speech Pro's top-K joint it filters
            // tokens by script, which breaks non-Latin speech.
            result = try await manager.transcribeDiskBacked(audio, decoderState: &decoder)
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
    /// leading space starts a word. Fluid Speech Mini also emits the boundary
    /// as a token of its own before digits (" " then "12"), so a space-only
    /// token starts the next word too; joining across it gave "by12%".
    /// Timings are encoder-frame emissions and run up to two frames (160 ms)
    /// ahead of the audio, which the join by time tolerates.
    static func words(_ timings: [TokenTiming]) -> [LocalMeetingResult.Word] {
        var out: [LocalMeetingResult.Word] = []
        var boundary = true
        for timing in timings {
            let piece = timing.token
            let text = piece.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { boundary = true; continue }
            if boundary || piece.hasPrefix(" ") {
                out.append(.init(text: text, start: timing.startTime, end: max(timing.endTime, timing.startTime)))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].end = max(out[out.count - 1].end, timing.endTime)
            }
            boundary = false
        }
        return out
    }

    /// pyannote community-1 at FluidAudio's defaults, then more speakers while
    /// their voices stay clearly apart: the defaults merge two similar voices
    /// (Samantha and Karen) into one. MEASURED 2026-11-06 on 33 files, the
    /// threshold tuned on half and checked on the other half: exact speaker
    /// count on 31 by leave-one-out, against 28 at the defaults; no
    /// single-voice file split; one person recorded in two sessions split in
    /// two. See `activities/2026-11-06-offline-speaker-diarizer.md`.
    private static func diarize(_ audio: URL, models directory: URL) async throws -> [LocalMeetingResult.Segment] {
        let models = try loadDiarizer(from: directory)
        func manager(speakers: Int?) -> OfflineDiarizerManager {
            var config = OfflineDiarizerConfig.default
            config.exposeChunkEmbeddings = true
            config.clustering.numSpeakers = speakers
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)
            return manager
        }
        let (source, _) = try AudioSourceFactory().makeDiskBackedSource(
            from: audio, targetSampleRate: OfflineDiarizerConfig.default.segmentation.sampleRate)
        defer { source.cleanup() }
        do {
            let defaults = manager(speakers: nil)
            let prepared = try await defaults.prepare(audioSource: source)
            var best = try defaults.cluster(prepared)
            let found = Set(best.segments.map(\.speakerId)).count
            for count in stride(from: found + 1, through: min(found + extraSpeakers, maxSpeakers), by: 1) {
                let candidate = try manager(speakers: count).cluster(prepared)
                guard voicesApart(candidate.chunkEmbeddings ?? [], speakers: count) else { break }
                best = candidate
            }
            return slots(best.segments)
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
    }

    static let extraSpeakers = 3
    static let maxSpeakers = 8
    /// Cosine distance between the two closest speakers' mean voices, tuned
    /// the same in every leave-one-out fold. A single voice forced into two
    /// scored at most 0.111.
    static let closestVoices: Float = 0.275
    static let embeddingsPerSpeaker = 3

    static func voicesApart(_ chunks: [ChunkEmbedding], speakers: Int) -> Bool {
        var sums: [String: [Float]] = [:], counts: [String: Int] = [:]
        for chunk in chunks {
            let norm = chunk.embedding256.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm.isFinite, norm > 0 else { continue }
            var sum = sums[chunk.speakerId] ?? [Float](repeating: 0, count: chunk.embedding256.count)
            for index in sum.indices { sum[index] += chunk.embedding256[index] / norm }
            sums[chunk.speakerId] = sum
            counts[chunk.speakerId, default: 0] += 1
        }
        guard sums.count == speakers, let fewest = counts.values.min(), fewest >= embeddingsPerSpeaker else { return false }
        let centroids = sums.values.map { sum -> [Float] in
            let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return sum.map { $0 / norm }
        }
        var closest = Float.infinity
        for i in centroids.indices {
            for j in centroids.indices where j > i {
                closest = min(closest, 1 - zip(centroids[i], centroids[j]).reduce(0) { $0 + $1.0 * $1.1 })
            }
        }
        return closest >= closestVoices
    }

    /// The diarizer's ids ("S1", "S2", ...) as slots numbered in order of
    /// first appearance; its cluster numbers follow no such order.
    private static func slots(_ segments: [TimedSpeakerSegment]) -> [LocalMeetingResult.Segment] {
        var seen: [String: Int] = [:]
        return segments.map { segment in
            let slot = seen[segment.speakerId] ?? seen.count
            seen[segment.speakerId] = slot
            return .init(speaker: slot, start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds))
        }
    }

    /// The same models and compute units `OfflineDiarizerModels.load` uses.
    /// That loader and `prepareModels` download, or purge the folder and
    /// download again, whenever FluidAudio's own revision marker is missing,
    /// which it always is in a verified install.
    private static func loadDiarizer(from directory: URL) throws -> OfflineDiarizerModels {
        let started = Date()
        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            configuration.allowLowPrecisionAccumulationOnGPU = true
            return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: configuration)
        }
        return OfflineDiarizerModels(
            segmentationModel: try model(ModelNames.OfflineDiarizer.segmentationFile, .all),
            fbankModel: try model(ModelNames.OfflineDiarizer.fbankFile, .cpuOnly),
            embeddingModel: try model(ModelNames.OfflineDiarizer.embeddingFile, .all),
            pldaRhoModel: try model(ModelNames.OfflineDiarizer.pldaRhoFile, .all),
            pldaPsi: try pldaPsi(from: directory.appendingPathComponent(ModelNames.OfflineDiarizer.pldaParameters)),
            compilationDuration: Date().timeIntervalSince(started)
        )
    }

    /// A copy of FluidAudio's private PLDA reader (`loadPLDAPsi`).
    private static func pldaPsi(from url: URL) throws -> [Double] {
        struct Parameters: Decodable {
            struct Tensor: Decodable {
                let base64: String
                enum CodingKeys: String, CodingKey { case base64 = "data_base64" }
            }
            let tensors: [String: Tensor]
        }
        let parameters = try JSONDecoder().decode(Parameters.self, from: Data(contentsOf: url))
        guard let encoded = parameters.tensors["psi"]?.base64,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              data.count >= MemoryLayout<Float>.size else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var psi = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = psi.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return psi.map(Double.init)
    }
}
