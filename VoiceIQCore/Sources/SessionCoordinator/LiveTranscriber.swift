import Foundation

/// A live result is usable only when the socket accepted the entire saved recording.
public final class LiveTranscriber: Sendable {
    private let session: LiveTranscriptionSession
    private let model: String
    private let startTask: Task<Void, Never>

    public init(session: LiveTranscriptionSession, model: String) {
        self.session = session
        self.model = model
        startTask = Task {
            do {
                try await session.start()
            } catch {
                Log.transcription.notice("live setup failed; saved audio will be uploaded: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func enqueue(_ pcm: Data) { session.enqueue(pcm) }

    public func finish(framesWritten: Int64) async -> TranscriptionResult? {
        let outcome = await session.finish(deadline: TimeoutPolicy.liveFinal)
        startTask.cancel()
        guard !Task.isCancelled else { return nil }
        guard case .completed(let text) = outcome else {
            Log.transcription.notice("live fallback: \(String(describing: outcome), privacy: .public)")
            return nil
        }
        let accepted = await session.acceptedBytes
        guard accepted == framesWritten * 2 else {
            Log.transcription.notice("live fallback: accepted \(accepted) of \(framesWritten * 2) PCM bytes")
            return nil
        }
        Log.transcription.notice("live complete: \(self.model, privacy: .public), \(accepted) PCM bytes")
        return TranscriptionResult(rawTranscript: text, cleanedTranscript: text, modelID: model)
    }

    public func abort() async {
        startTask.cancel()
        await session.abort()
    }

    @MainActor public static func makeFromSettings() -> LiveTranscriber? {
        let settings = SettingsStore()
        guard settings.liveTranscriptionEnabled else { return nil }
        let vocabulary = DictionaryStore().sanitizedVocabulary()
        switch settings.preferredProvider {
        case .gemini:
            // Endpoint overrides must not send their credentials to Google's socket.
            guard settings.geminiConfig.endpoint.host == "generativelanguage.googleapis.com",
                  let key = KeychainStore.loadAPIKey(), !key.isEmpty else { return nil }
            let model = "gemini-3.5-transcribe-live"
            return make(model: model, key: key, renewAfter: 480,
                        dialect: GeminiLiveDialect(setup: LiveSetup(model: model,
                            smart: settings.smartTranscriptionEnabled, customVocabulary: vocabulary)),
                        transport: { WebSocketTransport(apiKey: { key }) })
        case .openAI:
            guard let key = KeychainStore.loadOpenAIKey(), !key.isEmpty else { return nil }
            let model = "gpt-live-transcribe"
            return make(model: model, key: key, renewAfter: 3300,
                        dialect: OpenAILiveDialect(model: model, delay: .low, keywords: vocabulary),
                        transport: { WebSocketTransport.openAI(apiKey: { key }) })
        }
    }

    private static func make(model: String, key: String, renewAfter: TimeInterval,
                             dialect: LiveDialect, transport: @escaping @Sendable () -> LiveTransport) -> LiveTranscriber? {
        let identity = LiveAvailability.identity(model: model, key: key)
        guard LiveAvailability.shared.allows(identity) else {
            Log.transcription.notice("live temporarily unavailable; using saved-audio transcription")
            return nil
        }
        return LiveTranscriber(session: LiveTranscriptionSession(
            transport: transport(), dialect: dialect, transportFactory: transport, renewAfter: renewAfter,
            onFailure: { LiveAvailability.shared.refused($0, identity: identity) }
        ), model: model)
    }
}
