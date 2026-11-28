import AVFoundation
import Foundation
import VoiceIQBridge
import VoiceIQSpeech

/// The dictation pipeline.
///
///   microphone → STT-3.7-Realtime while the user speaks → transcript at
///   key-up → the writing model on the LLM Gateway writes it by the writing
///   rules, the Dictionary and any screen text → ReplacementEngine → inserted
///   text.
///
/// When the stream failed, or for a retry from History, the recording on disk
/// goes to pre-recorded STT-3.7 (Universal-2 for languages STT-3.7 lacks).
/// When the writing model fails, including an account without a gateway
/// balance, the transcript goes in tidied on the device, with a note on the
/// pill: a dictation is never lost to the writing step.
public struct AssemblyAITranscriptionService: TranscriptionServicing {
    let client: AssemblyAIClient
    let settings: SettingsStore

    public init(client: AssemblyAIClient, settings: SettingsStore = SettingsStore()) {
        self.client = client
        self.settings = settings
    }

    public func listen(context: DictationContext) -> RealtimeTranscription? {
        guard let key = KeychainStore.loadAPIKey() else { return nil }
        let language = settings.dictationLanguage
        guard language.streams else { return nil }
        return RealtimeTranscription(apiKey: key, languageCode: language.code)
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, durationSeconds: durationSeconds, context: context, live: nil)
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext,
                           live: RealtimeTranscription?) async throws -> TranscriptionResult {
        let clock = ContinuousClock()
        let started = clock.now
        var heard: (text: String, model: String)?
        if let live {
            do {
                let text = try await live.finish()
                // A stream that heard nothing is checked against the
                // recording: the file can hold speech the stream missed.
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    heard = (text, AssemblyAIConfig.realtimeModel)
                } else {
                    Log.transcription.notice("realtime transcript empty, transcribing the recording")
                }
            } catch {
                try Task.checkCancellation()
                Log.transcription.notice("realtime transcript unavailable (\(String(describing: error), privacy: .public)), transcribing the recording")
            }
        }
        if heard == nil {
            heard = try await transcribeRecording(audioURL: audioURL, durationSeconds: durationSeconds)
        }
        guard let heard, !heard.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // The coordinator classifies silence vs dropped-transcript by energy.
            throw TranscriptionError.emptyTranscript
        }
        func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }
        Log.transcription.notice("timing: transcript \(ms(clock.now - started))ms (\(heard.model, privacy: .public)), \(String(format: "%.1f", durationSeconds), privacy: .public)s audio")
        let transcript = TranscriptionResult(rawTranscript: heard.text, cleanedTranscript: heard.text, modelID: heard.model)
        let written = try await write(transcript, context: context)
        Log.transcription.notice("timing: key-up to text \(ms(clock.now - started))ms")
        return written
    }

    /// The recording without its leading and trailing silence, as FLAC, through
    /// pre-recorded transcription.
    private func transcribeRecording(audioURL: URL, durationSeconds: Double) async throws -> (text: String, model: String) {
        let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatInt16, interleaved: true)
        let range = SpeechRange.speechRange(in: file)
        let flacURL = audioURL.deletingLastPathComponent().appendingPathComponent("audio.flac")
        let encoded = try FLACEncoder.encode(cafURL: audioURL, flacURL: flacURL, frameRange: range)
        // Derived data, re-encoded from the CAF on any retry.
        defer { try? FileManager.default.removeItem(at: encoded.url) }
        let flac = try Data(contentsOf: encoded.url)
        let language = settings.dictationLanguage
        let request = AssemblyAIClient.TranscriptRequest(
            speechModels: language.streams
                ? [AssemblyAIConfig.transcribeModel, AssemblyAIConfig.fallbackModel] : [AssemblyAIConfig.fallbackModel],
            languageCode: language.code)
        let transcript = try await withTransientRetry {
            try await client.transcribe(audio: flac, request: request,
                                        deadline: TimeoutPolicy.transcriptDeadline(audioDuration: durationSeconds),
                                        stage: .transcribe)
        }
        return (transcript.text, transcript.model)
    }

    /// Writes a transcript, from STT-3.7 or the on-device model. With writing
    /// Off it is tidied on the device in the chosen style (`Tidy`), and one
    /// left with no words (only "um" and "uh") is an empty dictation. With a
    /// key stored, the writing model writes it by the writing rules; when that
    /// fails (no gateway balance, offline, a refusal) it is tidied on the
    /// device instead and the result carries a note for the pill. The
    /// dictionary's replacement rules and sound-alike spellings apply on every
    /// path; the writing model gets the transcript as heard and the
    /// replacements apply after.
    public func write(_ transcript: TranscriptionResult, context: DictationContext) async throws -> TranscriptionResult {
        let rules = DictionaryStore().replacementRules()
        let raw = transcript.cleanedTranscript
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptionError.emptyTranscript }
        let heardInCloud = transcript.modelID.hasPrefix("assemblyai") || transcript.modelID.hasPrefix("universal")
        func tidied(notice: String?) throws -> TranscriptionResult {
            // The language the transcript was heard in: AssemblyAI's setting,
            // or the on-device model's ("um" is a word in Portuguese).
            let language = heardInCloud ? settings.dictationLanguage.code : settings.localSpeechLanguage.code
            let terms = DictionaryStore().entries().map(\.term)
            // Dictionary names spelled another way ("Stacy" for "Stacey") take the Dictionary's spelling.
            let corrected = { (text: String) in
                SoundAlikeSpelling.apply(terms, to: ReplacementEngine.apply(rules, to: text), language: language ?? "en")
            }
            let style = settings.tidyStyle
            var result = transcript
            result.cleanedTranscript = Tidy.styled(corrected(Tidy.spoken(raw, style: style, language: language)),
                                                   style: style, language: language)
            result.notice = notice
            guard !result.cleanedTranscript.isEmpty else { throw TranscriptionError.emptyTranscript }
            return result
        }
        // Writing Off is an on-device choice: the picker shows only with On
        // device dictation, so it never skips the writer for AssemblyAI's transcripts.
        guard heardInCloud || settings.cleanupSource != .none else { return try tidied(notice: nil) }
        guard KeychainStore.loadAPIKey() != nil else { return try tidied(notice: nil) }
        let model = settings.assemblyAIConfig.writingModel
        let prompt = dictationPrompt(context: context, transcript: raw)
        do {
            // Luna answers in about 1 s (p90 under 2 s on the eval). A second
            // attempt starts after 5 s or a lost connection, and the tidied
            // transcript goes in once both have had 15 s.
            let attempt: @Sendable () async throws -> String = { [client] in
                try await client.write(prompt: prompt, model: model, deadline: 15)
            }
            let written = try await AssemblyAIClient.firstSuccess(retryAfter: 5, first: attempt, retry: attempt)
            let text = ValidationGate.stripArtifacts(written).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
            return TranscriptionResult(rawTranscript: transcript.rawTranscript,
                                       cleanedTranscript: ReplacementEngine.apply(rules, to: text),
                                       modelID: "\(transcript.modelID)+\(model)/writing-rules")
        } catch TranscriptionError.emptyTranscript {
            throw TranscriptionError.emptyTranscript
        } catch {
            try Task.checkCancellation()
            Log.transcription.error("Writing rules skipped: \(String(describing: error), privacy: .public)")
            return try tidied(notice: Self.notice(for: error))
        }
    }

    /// The pill's note for a dictation that went in without the writing rules.
    static func notice(for error: Error) -> String {
        switch error as? TranscriptionError {
        case .noBalance: return "Inserted as heard: writing needs an AssemblyAI balance"
        case .auth: return "Inserted as heard: AssemblyAI rejected the key"
        case .offline: return "Inserted as heard: offline"
        default: return "Inserted as heard: the writing model didn't answer"
        }
    }

    func dictationPrompt(context: DictationContext, transcript: String) -> String {
        let dictionary = DictionaryStore()
        let place = DictationPlace(appName: context.targetAppName,
                                   windowTitle: context.focusedField?.windowTitle,
                                   pageURL: context.focusedField?.pageURL)
        return PromptV1.dictationPrompt(
            vocabulary: dictionary.sanitizedVocabulary(), spellings: dictionary.spellings(),
            customRules: settings.customWritingRules, spelling: SpellingVariant.system.promptLine,
            screenText: settings.screenContextEnabled ? context.screenText : [],
            surroundingText: context.focusedField?.surroundingText,
            place: place,
            transcript: transcript
        )
    }

    /// One silent retry for transient failures; a per-minute throttle is
    /// waited out once when it names a short wait.
    private func withTransientRetry<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as TranscriptionError {
            switch error {
            // Not a timeout: the job may still finish, and another would bill again.
            case .network:
                Log.transcription.notice("retrying after \(String(describing: error), privacy: .public)")
                try await Task.sleep(nanoseconds: 500_000_000)
                return try await body()
            case .rateLimitedTransient(let retryAfter):
                let wait = retryAfter ?? TimeoutPolicy.rateLimitWait
                guard wait >= 0, wait <= TimeoutPolicy.rateLimitWait else { throw error }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                return try await body()
            default:
                throw error
            }
        }
    }
}
