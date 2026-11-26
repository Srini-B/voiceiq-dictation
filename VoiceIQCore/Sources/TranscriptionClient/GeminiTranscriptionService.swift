import AVFoundation
import Foundation
import VoiceIQBridge
import VoiceIQSpeech

/// The dictation pipeline.
///
///   CAF → FLAC → gemini-3.8-flash, one call that hears the recording and
///   writes the text by the writing rules (or, with them off, writes down
///   what was said), with any screen text → ReplacementEngine → inserted text.
///
/// Recordings over ten minutes go in chunks, one call each, then one text
/// call joins the written chunks so a correction spoken in a later chunk
/// reaches an earlier one. Rules unchanged:
/// one silent retry on transient failures, a second attempt on a fresh
/// connection when the first is slow, and every failure is a typed
/// TranscriptionError mapping to the failure matrix.
public struct GeminiTranscriptionService: TranscriptionServicing {
    let client: GeminiClient
    let settings: SettingsStore
    /// The on-device writer, for "Writing rules" set to On device. Nil where
    /// the app does not link it (tests).
    let localWriter: LocalWriteRunner?

    public init(client: GeminiClient, settings: SettingsStore = SettingsStore(), localWriter: LocalWriteRunner? = nil) {
        self.client = client
        self.settings = settings
        self.localWriter = localWriter
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let config = settings.geminiConfig
        // Built once per dictation: a rule edited mid-flight must not change
        // the rules this text is being written under.
        let prompt = dictationPrompt(context: context)
        let clock = ContinuousClock()
        let started = clock.now
        var encoded = Duration.zero

        // One request per chunk. A short dictation is one chunk. Leading and
        // trailing silence is left out of every request.
        let (ranges, fileFrames) = try AudioChunker.ranges(cafURL: audioURL)

        // A multi-chunk upload can fail half way (a per-minute quota often
        // refuses chunk 1 right after chunk 0). Finished chunks are kept next
        // to the audio so a retry sends only the rest.
        let cacheURL = FileLayout.chunkTranscripts(in: audioURL.deletingLastPathComponent())
        var done = ranges.count > 1 ? ChunkTranscripts.read(from: cacheURL) : ChunkTranscripts()
        if ranges.count > 1 {
            Log.transcription.info("long recording (\(Int(durationSeconds))s) split into \(ranges.count) chunks, \(done.count) already transcribed")
        }
        var pieces: [String] = []
        for (index, range) in ranges.enumerated() {
            if let earlier = done[range] {
                if !earlier.isEmpty { pieces.append(earlier) }
                continue
            }
            let encodeStart = clock.now
            let flac = try encodeChunk(audioURL: audioURL, range: range, index: index)
            encoded += clock.now - encodeStart
            let seconds = durationSeconds * Double(range.count) / Double(max(1, fileFrames))
            var text = try await sendWithRetry(flac: flac, prompt: prompt, config: config, speechSeconds: seconds)
            if text.isEmpty, seconds >= 0.6 {
                // F9a second chance: an empty result on real audio is sometimes model
                // nondeterminism — one re-send before surfacing anything (audit L25).
                Log.transcription.info("empty dictation on \(String(format: "%.1f", seconds))s audio — one re-send")
                text = (try? await send(flac: flac, prompt: prompt, config: config, speechSeconds: seconds)) ?? ""
            }
            if !text.isEmpty { pieces.append(text) }
            if ranges.count > 1 {
                done[range] = text
                done.write(to: cacheURL)
            }
        }
        func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }
        let words = pieces.joined(separator: " ").split(whereSeparator: \.isWhitespace).count
        Log.transcription.notice("timing: encode \(ms(encoded))ms, dictation call \(ms(clock.now - started - encoded))ms (\(config.writingModel, privacy: .public)), \(words) words, \(String(format: "%.1f", durationSeconds), privacy: .public)s audio")

        guard !pieces.isEmpty else {
            // The coordinator classifies silence vs dropped-transcript by energy.
            throw TranscriptionError.emptyTranscript
        }
        var written = pieces[0]
        if pieces.count > 1 {
            // A failure here leaves the chunk cache in place, so Retry sends only this call.
            let joinPrompt = dictationPrompt(context: context, writtenParts: pieces)
            let joined = try await sendWithRetry(flac: nil, prompt: joinPrompt, config: config,
                                                 speechSeconds: durationSeconds)
            written = joined.isEmpty ? pieces.joined(separator: "\n\n") : joined
        }
        if ranges.count > 1 {
            try? FileManager.default.removeItem(at: cacheURL)
        }
        // Dictionary rules are a HARD guarantee — they apply on every path (audit L9).
        let text = ReplacementEngine.apply(DictionaryStore().replacementRules(), to: written)
        let modelID = "\(config.writingModel)/writing-rules"
        return TranscriptionResult(rawTranscript: written, cleanedTranscript: text, modelID: modelID)
    }

    /// Writes an on-device transcript by the writing rules: with the
    /// on-device writer when the user picked it and it is downloaded, else
    /// with Gemini when a key is stored, so an on-device writer that is
    /// missing or fails hands the text to Gemini. With writing Off, no key,
    /// or Gemini failing, the transcript is inserted as transcribed. The dictionary's
    /// replacement rules apply either way. A transcript with no words, or one
    /// the writer finds holds no speech (only "um" and "uh"), is an empty
    /// dictation, as a Gemini transcription of the audio would be.
    public func write(_ transcript: TranscriptionResult, context: DictationContext) async throws -> TranscriptionResult {
        let rules = DictionaryStore().replacementRules()
        let raw = transcript.cleanedTranscript
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptionError.emptyTranscript }
        var asTranscribed = transcript
        // Dictionary names spelled another way ("Stacy" for "Stacey") take
        // the Dictionary's spelling; the writers get the transcript as heard.
        asTranscribed.cleanedTranscript = SoundAlikeSpelling.apply(
            DictionaryStore().entries().map(\.term), to: ReplacementEngine.apply(rules, to: raw),
            language: settings.localSpeechLanguage.code)
        if settings.cleanupSource == .onDevice, let written = try await writeOnDevice(transcript, context: context, rules: rules) {
            return written
        }
        guard settings.cleanupSource != .none, KeychainStore.loadAPIKey() != nil else { return asTranscribed }
        let config = settings.geminiConfig
        let prompt = dictationPrompt(context: context, transcript: raw)
        do {
            // About fifteen characters a second of speech.
            let written = try await sendWithRetry(flac: nil, prompt: prompt, config: config,
                                                  speechSeconds: Double(raw.count) / 15)
            guard !written.isEmpty else { throw TranscriptionError.emptyTranscript }
            return TranscriptionResult(rawTranscript: transcript.rawTranscript,
                                       cleanedTranscript: ReplacementEngine.apply(rules, to: written),
                                       modelID: "\(transcript.modelID)+\(config.writingModel)/writing-rules")
        } catch TranscriptionError.emptyTranscript {
            throw TranscriptionError.emptyTranscript
        } catch {
            try Task.checkCancellation()
            Log.transcription.error("Writing rules skipped for an on-device transcript: \(String(describing: error), privacy: .public)")
            return asTranscribed
        }
    }

    private func writeOnDevice(_ transcript: TranscriptionResult, context: DictationContext,
                               rules: [ReplacementEngine.Rule]) async throws -> TranscriptionResult? {
        guard let localWriter, await LocalWriter.isReady else { return nil }
        do {
            let written = try await LocalWriter.dictation(raw: transcript.cleanedTranscript, context: context, runner: localWriter)
            guard !written.isEmpty else { throw TranscriptionError.emptyTranscript }
            return TranscriptionResult(rawTranscript: transcript.rawTranscript,
                                       cleanedTranscript: ReplacementEngine.apply(rules, to: written),
                                       modelID: "\(transcript.modelID)+lfm3-omni-2b/writing-rules")
        } catch TranscriptionError.emptyTranscript {
            throw TranscriptionError.emptyTranscript
        } catch {
            try Task.checkCancellation()
            Log.transcription.error("On-device writing failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func dictationPrompt(context: DictationContext, writtenParts: [String]? = nil, transcript: String? = nil) -> String {
        let dictionary = DictionaryStore()
        let place = DictationPlace(appName: context.targetAppName,
                                   windowTitle: context.focusedField?.windowTitle,
                                   pageURL: context.focusedField?.pageURL)
        return PromptV1.dictationPrompt(
            vocabulary: dictionary.sanitizedVocabulary(), spellings: dictionary.spellings(),
            customRules: settings.customWritingRules, spelling: SpellingVariant.system.promptLine,
            // The spoken languages are a Gemini dictation setting. On device,
            // the model's own language applies, and a Gemini fallback or
            // writing step gets no hint.
            languages: settings.dictationSource == .gemini ? SpokenLanguage.promptLine(settings.spokenLanguages) : nil,
            screenText: writtenParts == nil ? context.screenText : [],
            surroundingText: context.focusedField?.surroundingText,
            place: place,
            writtenParts: writtenParts,
            transcript: transcript
        )
    }

    private func encodeChunk(audioURL: URL, range: Range<AVAudioFramePosition>, index: Int) throws -> Data {
        let flacURL = audioURL.deletingLastPathComponent().appendingPathComponent("audio-\(index).flac")
        let encoded = try FLACEncoder.encode(cafURL: audioURL, flacURL: flacURL, frameRange: range)
        Log.transcription.info("FLAC chunk \(index) \(encoded.byteCount) bytes in \(Int(encoded.encodeSeconds * 1000))ms")
        let data = try Data(contentsOf: encoded.url)
        // The FLAC is derived data (re-encoded from the CAF on any retry) — once
        // it's in memory the file is pure duplication. Storage policy: the CAF is
        // the only audio artifact that persists.
        try? FileManager.default.removeItem(at: encoded.url)
        return data
    }

    /// The ONE place a dictation request is sent, for `speechSeconds` of
    /// speech. A second attempt starts on its own connection when the first
    /// has not answered in time or lost its connection; the first answer wins.
    private func send(flac: Data?, prompt: String, config: GeminiConfig,
                      speechSeconds: TimeInterval) async throws -> String {
        let deadline = TimeoutPolicy.overallDeadline(audioDuration: speechSeconds)
        let attempt: @Sendable () async throws -> String = { [client] in
            try await client.dictate(prompt: prompt, audio: flac, model: config.writingModel,
                                     endpoint: config.endpoint, deadline: deadline)
        }
        let text = try await GeminiClient.firstSuccess(retryAfter: GeminiClient.hedgeDelay(speechSeconds: speechSeconds),
                                                       first: attempt, retry: attempt)
        return ValidationGate.stripArtifacts(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendWithRetry(flac: Data?, prompt: String, config: GeminiConfig,
                               speechSeconds: TimeInterval) async throws -> String {
        do {
            return try await send(flac: flac, prompt: prompt, config: config, speechSeconds: speechSeconds)
        } catch let error as TranscriptionError {
            switch error {
            case .network, .timeout:
                // One silent retry for transient classes (audio is safe on disk).
                // A server error waits half a second first.
                Log.transcription.notice("dictation retrying after \(String(describing: error), privacy: .public)")
                if case .network = error { try await Task.sleep(nanoseconds: 500_000_000) }
                return try await send(flac: flac, prompt: prompt, config: config, speechSeconds: speechSeconds)
            case .rateLimitedTransient(let retryAfter):
                // A per-minute throttle names its own wait. Sitting it out once
                // keeps a long dictation on the pill instead of failing it to
                // History, where the retry would hit the same wall.
                let wait = retryAfter ?? TimeoutPolicy.rateLimitWait
                guard wait <= TimeoutPolicy.rateLimitWait else { throw error }
                Log.transcription.info("dictation rate limited — waiting \(Int(wait))s once")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                return try await send(flac: flac, prompt: prompt, config: config, speechSeconds: speechSeconds)
            default:
                throw error
            }
        }
    }
}
