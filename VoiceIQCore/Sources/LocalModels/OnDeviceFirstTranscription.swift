import AVFoundation
import Foundation
import VoiceIQSpeech

/// History's Retry and launch recovery: the saved recording goes to the
/// on-device model when the settings pick it and it is downloaded, then to
/// Gemini's writing step; otherwise Gemini transcribes it. If the model
/// fails, Gemini hears it only when Writing rules and notes is Gemini. A live dictation
/// takes the same route through `DictationCoordinator`, which loads the model
/// while the user speaks.
public struct OnDeviceFirstTranscription: TranscriptionServicing {
    private let gemini: TranscriptionServicing
    private let makeSession: LocalSpeechSessionFactory

    public init(gemini: TranscriptionServicing, makeSession: @escaping LocalSpeechSessionFactory) {
        self.gemini = gemini
        self.makeSession = makeSession
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let frames = (try? AVAudioFile(forReading: audioURL))?.length ?? 0
        let makeSession = makeSession
        if frames > 0,
           let local = await MainActor.run(body: {
               LocalTranscriber.makeFromSettings(audioURL: audioURL, cloudOnColdLoad: false, makeSession: makeSession)
           }) {
            if let decoded = await local.finish(framesWritten: frames) {
                return try await gemini.write(decoded, context: context)
            }
            try Task.checkCancellation()
            guard SettingsStore().onDeviceFallsBackToGemini else { throw TranscriptionError.onDeviceFailed }
        }
        try Task.checkCancellation()
        return try await gemini.transcribe(audioURL: audioURL, durationSeconds: durationSeconds, context: context)
    }

    public func write(_ transcript: TranscriptionResult, context: DictationContext) async throws -> TranscriptionResult {
        try await gemini.write(transcript, context: context)
    }
}

public enum DictationRoute {
    /// Something can transcribe a dictation: a Gemini key, or the on-device
    /// model the settings pick, downloaded. Fully offline dictation needs no key.
    @MainActor public static var isAvailable: Bool {
        let settings = SettingsStore()
        return KeychainStore.hasModelKey
            || (settings.localTranscriptionEnabled && LocalModelStore.store(for: settings.localSpeechModel).state == .ready)
    }
}
