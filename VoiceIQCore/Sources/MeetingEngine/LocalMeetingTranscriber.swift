import AVFoundation
import Foundation
import os
import VoiceIQSpeech

/// A meeting transcribed on device: Fluid Speech Mini for the words, Nemotron
/// 3 Diarization for who spoke when, joined by time. This is how FluidMeet
/// does it; the cloud path (`MeetingTranscriber`) asks one model for both.
///
/// Both tracks are mixed onto one timeline the way the cloud path mixes a
/// request (`CallAudio.samples`), written as one file so both models read it
/// from disk, and removed after. The result is cached beside the audio, so a
/// retry after the notes fail never decodes the same meeting twice.
public struct LocalMeetingTranscriber: Sendable {
    enum Failure: LocalizedError {
        case busy
        case timedOut
        var errorDescription: String? {
            switch self {
            case .busy: return "The on-device models were busy with a dictation."
            case .timedOut: return "On-device transcription took too long."
            }
        }
    }

    /// v2: words split at Fluid Speech Mini's lone space tokens; v1 caches glued digits to the word before.
    static let cacheName = "local-words-v2.json"
    static let mixName = "local-mix.caf"
    /// The mix is written a minute at a time.
    static let piece = 60.0
    /// A dictation keeps the models for seconds; a meeting waits this long for one.
    static let busyWait: Duration = .seconds(600)

    /// The Mac labels speakers with Nemotron 3 Diarization. iPhone and iPad
    /// record the microphone only and skip the diarizer: one speaker.
    #if os(macOS)
    public static let diarizes = true
    #else
    public static let diarizes = false
    #endif

    private let runner: LocalMeetingRunner
    private let speech: URL
    private let diarizer: URL?
    private let id: UUID
    private let job: Job

    /// Nil when meetings are not set to stay on device or a needed model is
    /// missing. Otherwise holds a session on the models until `transcribe`
    /// returns, waiting out a dictation that has them first.
    @MainActor
    public static func acquire(runner: @escaping LocalMeetingRunner) async throws -> LocalMeetingTranscriber? {
        guard Self.isReady else { return nil }
        let id = UUID(), job = Job()
        let cancel: @Sendable () async -> Void = { await job.cancel() }
        let clock = ContinuousClock(), deadline = clock.now + busyWait
        while true {
            if let speech = LocalModelStore.store(for: .parakeet).acquireSession(id: id, cancel: cancel) {
                guard diarizes else {
                    return LocalMeetingTranscriber(runner: runner, speech: speech, diarizer: nil, id: id, job: job)
                }
                if let diarizer = LocalModelStore.speakerDiarizer.acquireSession(id: id, cancel: cancel) {
                    return LocalMeetingTranscriber(runner: runner, speech: speech, diarizer: diarizer, id: id, job: job)
                }
                LocalModelStore.store(for: .parakeet).releaseSession(id: id)
            }
            guard Self.isReady else { return nil }
            guard clock.now < deadline else { throw Failure.busy }
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// The setting is on and the needed models are downloaded.
    @MainActor public static var isReady: Bool {
        SettingsStore().localMeetingTranscriptionEnabled
            && LocalModelStore.store(for: .parakeet).state == .ready
            && (!diarizes || LocalModelStore.speakerDiarizer.state == .ready)
    }

    public func transcribe(folder: URL) async throws -> [TranscriptSegment] {
        let holdsDiarizer = diarizer != nil
        defer { Task { @MainActor in
            LocalModelStore.store(for: .parakeet).releaseSession(id: id)
            if holdsDiarizer { LocalModelStore.speakerDiarizer.releaseSession(id: id) }
        } }
        let audio = try MeetingTranscriber.callAudio(folder: folder)
        let result = try await decode(audio, folder: folder)
        UsageMeter.record(stage: .meetingTranscribe, model: LocalSpeechModel.parakeet.modelID,
                          usage: TokenUsage(reportedCostUSD: 0, audioSeconds: audio.duration))
        var words = Self.label(result.words, segments: result.segments)
        if audio.isOnline { words = MeetingTranscriber.markOwner(words, audio: audio) }
        words = Self.renumber(words)
        return SpeakerLinker.overlappingTurns(words).map { turn in
            TranscriptSegment(speaker: turn.speaker, text: turn.text, chunkIndex: 0, start: turn.start, end: turn.end)
        }
    }

    private func decode(_ audio: CallAudio, folder: URL) async throws -> LocalMeetingResult {
        let cache = folder.appendingPathComponent(Self.cacheName)
        if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(LocalMeetingResult.self, from: data) {
            return cached
        }
        let mix = folder.appendingPathComponent(Self.mixName)
        defer { try? FileManager.default.removeItem(at: mix) }
        try Self.writeMix(audio, to: mix)
        let request = LocalMeetingRequest(speechDirectory: speech, diarizerDirectory: diarizer, audio: mix)
        let result = try await job.run(deadline: TimeoutPolicy.localMeeting(audioSeconds: audio.duration)) {
            try await runner(request)
        }
        try JSONEncoder().encode(result).write(to: cache, options: .atomic)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("local-words-v1.json"))
        return result
    }

    /// The whole timeline, silence included, so the models' seconds are the
    /// meeting's seconds.
    static func writeMix(_ audio: CallAudio, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: TrackAudio.sampleRate, channels: 1, interleaved: true)!
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        var start = 0.0
        while start < audio.duration {
            try Task.checkCancellation()
            let samples = try audio.samples(start...min(audio.duration, start + piece))
            guard !samples.isEmpty else { start += piece; continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.int16ChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
            start += piece
        }
    }

    /// Each word takes the speaker talking at its middle; failing that, the
    /// one overlapping it most, then the nearest within two seconds, then the
    /// previous word's. Speaker slots become ids `s1`, `s2`, … by slot.
    static func label(_ words: [LocalMeetingResult.Word], segments: [LocalMeetingResult.Segment]) -> [TimedWord] {
        var out: [TimedWord] = []
        var previous = "s1"
        for word in words {
            let speaker = slot(for: word, in: segments).map { "s\($0 + 1)" } ?? previous
            previous = speaker
            out.append(TimedWord(text: word.text, speaker: speaker, start: word.start, end: word.end))
        }
        return out
    }

    private static func slot(for word: LocalMeetingResult.Word, in segments: [LocalMeetingResult.Segment]) -> Int? {
        let middle = (word.start + word.end) / 2
        if let hit = segments.first(where: { $0.start <= middle && middle <= $0.end }) { return hit.speaker }
        var bestOverlap = 0.0, overlapping: Int?
        var bestGap = 2.0, nearest: Int?
        for segment in segments {
            let overlap = min(segment.end, word.end) - max(segment.start, word.start)
            if overlap > bestOverlap { bestOverlap = overlap; overlapping = segment.speaker }
            let gap = segment.start > word.end ? segment.start - word.end : word.start - segment.end
            if gap <= bestGap { bestGap = gap; nearest = segment.speaker }
        }
        return overlapping ?? nearest
    }

    /// Ids other than the owner's renumbered in order of first appearance, so
    /// the list reads Speaker 1, Speaker 2 with no gaps.
    static func renumber(_ words: [TimedWord]) -> [TimedWord] {
        var mapping: [String: String] = [MeetingSpeaker.you: MeetingSpeaker.you]
        return words.map { word in
            if mapping[word.speaker] == nil { mapping[word.speaker] = "s\(mapping.count)" }
            var renamed = word; renamed.speaker = mapping[word.speaker]!; return renamed
        }
    }
}

/// The running decode, so a model deletion can stop it and wait for it.
private actor Job {
    private var task: Task<LocalMeetingResult, Error>?

    /// Core ML work cannot be cancelled, so a run that passes its deadline is
    /// abandoned instead of joined: the caller moves on to the cloud path and
    /// the work keeps its task until the next cancellation check between
    /// models. The Mac helper is killed at the same deadline first, so this
    /// fires only in-process (iOS).
    func run(deadline: TimeInterval,
             _ body: @escaping @Sendable () async throws -> LocalMeetingResult) async throws -> LocalMeetingResult {
        let task = Task { try await body() }
        self.task = task
        defer { self.task = nil }
        let settled = OSAllocatedUnfairLock(initialState: false)
        let claim: @Sendable () -> Bool = { settled.withLock { let first = !$0; $0 = true; return first } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(deadline)) } catch { return }
                    guard claim() else { return }
                    task.cancel()
                    continuation.resume(throwing: LocalMeetingTranscriber.Failure.timedOut)
                }
                Task {
                    let result = await task.result
                    timer.cancel()
                    if claim() { continuation.resume(with: result) }
                }
            }
        } onCancel: { task.cancel() }
    }

    func cancel() async {
        task?.cancel()
        _ = await task?.result
    }
}
