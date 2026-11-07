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
        // Nil while the model is not downloaded: `.auth` keeps queued rows
        // queued, so they retry once it is.
        guard let local = await LocalTranscriber(audioURL: audioURL, model: settings.localSpeechModel,
                                                 language: settings.localSpeechLanguage, realtime: false,
                                                 cloudOnColdLoad: false, makeSession: makeSession) else {
            throw TranscriptionError.auth
        }
        guard let raw = await local.finish(framesWritten: frames) else {
            throw TranscriptionError.emptyTranscript
        }
        return try await cloud.process(raw, durationSeconds: durationSeconds, context: context)
    }

    public func process(_ transcript: TranscriptionResult, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        try await cloud.process(transcript, durationSeconds: durationSeconds, context: context)
    }
}
