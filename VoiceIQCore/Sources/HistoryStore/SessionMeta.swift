import Foundation

/// Per-dictation metadata, persisted as meta.json in the session folder.
/// Written at every status transition so crash recovery (M6 RecoveryScanner) can
/// tell exactly how far a session got. Terminal-status writes are the source of
/// truth for "was anything lost?"
public struct SessionMeta: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording
        /// Audio finalized on disk; transcription not yet complete.
        case recorded
        case transcribing
        case inserted
        case copiedToClipboard
        case awaitingChip
        case heldSecure
        case queuedForRetry
        /// Transcribed after a crash/offline drain. Never inserted, so no chip
        /// may promise "Ready to paste"; the text reaches the clipboard only
        /// when the user turned on copying recovered dictations.
        case recovered
        case silent
        case cancelled
        case failed
    }

    public var id: UUID
    public var startedAt: Date
    public var status: Status
    public var targetAppBundleID: String?
    public var targetAppName: String?
    public var audioDurationSeconds: Double?
    /// Device-change gap markers: seconds-from-start where audio may have a seam.
    public var gapMarkers: [Double]
    public var rawTranscript: String?
    public var cleanedTranscript: String?
    public var errorCode: String?
    /// Human-relevant API error detail (e.g. the 404 body naming the model).
    public var errorMessage: String?
    public var modelID: String?
    /// Key-up → terminal-state latency, for the local stats overlay.
    public var pipelineSeconds: Double?
    /// Where `pipelineSeconds` went, step by step. Nil on failed dictations
    /// and on those finished before 0.7.10.
    public var steps: DictationSteps?
    /// How loud the room was (10th-percentile level, dBFS) and how loud the
    /// speech got. Recorded on EVERY session regardless of settings: these are
    /// the numbers that let the noise thresholds be calibrated from real
    /// dictations instead of guessed, and they make a History row diagnostic
    /// ("it was −38 dB in there") rather than merely descriptive.
    /// Optional, so meta.json written by older builds still decodes.
    public var noiseFloorDBFS: Double?
    public var speechPeakDBFS: Double?

    public init(id: UUID, startedAt: Date, status: Status) {
        self.id = id
        self.startedAt = startedAt
        self.status = status
        self.gapMarkers = []
    }

    // MARK: - Disk I/O (atomic)

    public func write(to folder: URL) {
        let url = FileLayout.metaJSON(in: folder)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.history.error("SessionMeta: write failed for \(self.id, privacy: .public): \(error)")
        }
    }

    public static func read(from folder: URL) -> SessionMeta? {
        let url = FileLayout.metaJSON(in: folder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionMeta.self, from: data)
    }
}

/// One dictation's time after key-up, step by step. The steps run one after
/// another, so they add up to `SessionMeta.pipelineSeconds` within a few
/// milliseconds of local work between them.
public struct DictationSteps: Codable, Equatable, Sendable {
    /// Trailing speech kept after key-up, then the microphone teardown.
    public var finishRecording: TimeInterval
    /// Encoding and the one model request that hears the audio and writes
    /// the text.
    public var transcription: TimeInterval
    /// The separate writing request: Gemini writing an on-device transcript,
    /// and dictations from before 0.7.12, which transcribed and then cleaned
    /// up in two calls.
    public var writing: TimeInterval?
    /// Saving the result and typing it.
    public var insert: TimeInterval?

    public init(finishRecording: TimeInterval, transcription: TimeInterval, insert: TimeInterval? = nil) {
        self.finishRecording = finishRecording
        self.transcription = transcription
        self.insert = insert
    }
}

public extension DictationSteps {
    struct Row: Hashable, Sendable {
        public let label: String
        public let value: String
    }

    /// History's rows under Pipeline, the same on Mac and iPhone.
    var rows: [Row] {
        func seconds(_ value: TimeInterval) -> String { String(format: "%.2fs", value) }
        var rows = [
            Row(label: "Finish recording", value: seconds(finishRecording)),
            Row(label: "Transcription", value: seconds(transcription)),
        ]
        if let writing { rows.append(Row(label: "Writing model", value: seconds(writing))) }
        if let insert { rows.append(Row(label: "Insert", value: seconds(insert))) }
        return rows
    }
}
