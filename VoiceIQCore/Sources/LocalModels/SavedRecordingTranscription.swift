import AVFoundation
import Foundation
import VoiceIQSpeech

/// How History's Retry, the retry queue and crash recovery transcribe a saved
/// recording. Claude has no speech model, so with it the recording is
/// transcribed on device and then cleaned up the way a dictation is; every
/// other provider transcribes it in the cloud as before.
public struct SavedRecordingTranscription: TranscriptionServicing {
    private let cloud: any TranscriptionServicing
    private let makeSession: LocalSpeechSessionFactory

    /// On iOS the app passes `LocalSpeechInference.makeSession`, so inference
    /// runs in-process.
    public init(cloud: any TranscriptionServicing, makeSession: @escaping LocalSpeechSessionFactory) {
        self.cloud = cloud
        self.makeSession = makeSession
    }

    #if os(macOS)
    /// The Mac UI never links inference: local sessions run in the speech helper.
    public init(cloud: any TranscriptionServicing) {
        self.init(cloud: cloud, makeSession: {
            LocalRemoteSession(audioURL: $1, model: $0, streaming: $2, options: $3)
        })
    }
    #endif

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let settings = SettingsStore()
        guard !settings.providerTranscribes else {
            return try await cloud.transcribe(audioURL: audioURL, durationSeconds: durationSeconds, context: context)
        }
        // A crashed session's CAF can have no readable length; it can't be decoded on device.
        guard let frames = (try? AVAudioFile(forReading: audioURL))?.length, frames > 0 else {
            throw TranscriptionError.emptyTranscript
        }
        let model = settings.localSpeechModel, language = settings.localSpeechLanguage, makeSession = makeSession
        let clock = ContinuousClock(), deadline = clock.now + LocalMeetingTranscriber.busyWait
        let decode: Task<TranscriptionResult?, Never>
        while true {
            let (started, ready) = await MainActor.run { () -> (Task<TranscriptionResult?, Never>?, Bool) in
                guard let local = LocalTranscriber(audioURL: audioURL, model: model, language: language, realtime: false,
                                                   cloudOnColdLoad: false, makeSession: makeSession) else {
                    return (nil, LocalModelStore.store(for: model).state == .ready)
                }
                let decode = Task { await local.finish(framesWritten: frames) }
                // Held like a warm-up: a dictation that starts meanwhile takes the
                // model and loads once this decode ends, instead of failing.
                LocalModelWarmup.adopt(id: local.id, model: model, load: Task { _ = await decode.value }, stop: {})
                return (decode, true)
            }
            if let started {
                decode = started
                break
            }
            // Not downloaded: `.auth` keeps queued rows queued, and the queue
            // drains again once it is (`RetryQueue.start`).
            guard ready else { throw TranscriptionError.auth }
            // Downloaded but held by a dictation or meeting: wait for it, as
            // on-device meetings do. `.timeout` keeps queued rows queued too.
            guard clock.now < deadline else { throw TranscriptionError.timeout }
            try await Task.sleep(for: .seconds(2))
        }
        guard let raw = await decode.value else { throw TranscriptionError.emptyTranscript }
        return try await cloud.process(raw, durationSeconds: durationSeconds, context: context)
    }

    public func process(_ transcript: TranscriptionResult, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        try await cloud.process(transcript, durationSeconds: durationSeconds, context: context)
    }
}
