import AVFoundation
import Foundation

/// The transcription pipeline.
///
///   Writing rules on (the default), under ten minutes:
///   CAF → FLAC → flash model with the cleanup prompt and the audio, one call
///       → ReplacementEngine → inserted text.
///   Otherwise, or when that call fails:
///   CAF → FLAC → interactions (mode: smart, custom_vocabulary)
///       → [writing rules] flash cleanup → validation gate
///       → ReplacementEngine → inserted text.
///   On OpenAI's own API the writing model cannot hear the audio, so a
///   single-chunk dictation also gets whisper-1's transcript as SECOND,
///   fetched in parallel, for cleanup to repair misheard stretches of RAW.
///   With ElevenLabs, MAI Transcribe 2 or Sarvam picked as the transcription
///   source, every chunk goes to that model instead, and neither the one-call
///   path nor SECOND runs: the writing model gets its transcript as RAW. With
///   Sarvam as the writing model the same holds: it cannot hear audio.
///
/// The one-call path has no separate raw transcript, so there is nothing for
/// the validation gate to compare against; the raw column holds the same text.
///
/// Rules unchanged: one silent retry on transient transcribe failures; cleanup
/// has a hard deadline and NEVER blocks a good transcript; every failure is a
/// typed TranscriptionError mapping to the failure matrix.
public struct GeminiTranscriptionService: TranscriptionServicing {
    static let untranslatableToken = "<<UNTRANSLATABLE>>"
    let client: GeminiClient
    let settings: SettingsStore

    /// Cleanup budget. The pass reads the whole transcript and writes it back, so
    /// the budget grows with the text: a one-line dictation gets ~12 s, a
    /// ten-minute one (~8k characters) ~35 s. Capped so a stalled request still
    /// falls back to the raw transcript in bounded time.
    /// MEASURED 2026-09-26: the full cleanup prompt (rules + seed instructions,
    /// ~15 k characters) on gemini-3.8-flash at thinkingLevel low took 1.7–4.9 s
    /// for a 170-character transcript, with or without a screenshot. The old
    /// 3 s floor tripped "cleanup unavailable (timeout)" on ordinary dictations,
    /// which pasted RAW text and made every formatting rule look ignored.
    static func cleanupDeadline(forCharacters count: Int) -> TimeInterval {
        min(60, 12 + Double(count) / 350)
    }

    public init(client: GeminiClient, settings: SettingsStore = SettingsStore()) {
        self.client = client
        self.settings = settings
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let config = settings.geminiConfig
        let policy = settings.formattingPolicy
        // Read once per dictation: a toggle flipped mid-flight must not change
        // the rules this transcript is being produced under.
        let vocabulary = Self.vocabularyIfEnabled()
        let source = settings.transcriptionSource
        let names = modelNames(source)

        // One request per chunk. A short dictation is one chunk, so this is the
        // old single-request path for everything under ten minutes. Leading and
        // trailing silence is left out of every request.
        let (ranges, fileFrames) = try AudioChunker.ranges(cafURL: audioURL)

        // A dictation with writing rules on goes to the flash model in one
        // call, which hears the audio and writes the cleaned text. Anything
        // that stops it (an error, a timeout, "no speech") falls through to
        // transcription then cleanup below, so it can only cost time.
        if context.mode == .dictate, policy.cleanupPass, ranges.count == 1, context.speechHeard,
           source == .provider, settings.writingSource == .provider, settings.activeRoute.provider.writingModelHearsAudio,
           !Self.oneCallRefused.contains(settings.activeRoute),
           let text = await transcribeInOneCall(audioURL: audioURL, range: ranges[0],
                                                durationSeconds: durationSeconds, context: context, config: config) {
            return TranscriptionResult(rawTranscript: text, cleanedTranscript: text,
                                       modelID: "\(config.cleanupModel)/one-call")
        }
        // A multi-chunk upload can fail half way (Tier 1 meters ~400 s of audio
        // per minute, so chunk 1 is often refused right after chunk 0). Finished
        // chunks are kept next to the audio so a retry sends only the rest.
        let cacheURL = FileLayout.chunkTranscripts(in: audioURL.deletingLastPathComponent())
        var done = ranges.count > 1 ? ChunkTranscripts.read(from: cacheURL) : ChunkTranscripts()
        if ranges.count > 1 {
            Log.transcription.info("long recording (\(Int(durationSeconds))s) split into \(ranges.count) chunks, \(done.count) already transcribed")
        }
        var pieces: [String] = []
        var secondOpinion: Task<String?, Never>?
        defer { secondOpinion?.cancel() }
        for (index, range) in ranges.enumerated() {
            if let earlier = done[range] {
                if !earlier.isEmpty { pieces.append(earlier) }
                continue
            }
            let flacData = try encodeChunk(audioURL: audioURL, range: range, index: index)
            let seconds = durationSeconds * Double(range.count) / Double(max(1, fileFrames))
            let deadline = TimeoutPolicy.overallDeadline(audioDuration: seconds)
            if ranges.count == 1, context.mode == .dictate, policy.cleanupPass, source == .provider,
               settings.writingSource == .provider {
                let client = client
                secondOpinion = Task { try? await client.secondOpinionTranscript(flacData: flacData, deadline: deadline) }
            }
            var raw = try await transcribeWithRetry(
                flacData: flacData, seconds: seconds, source: source, config: config, policy: policy,
                vocabulary: vocabulary, deadline: deadline
            )
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, seconds >= 0.6 {
                // F9a second chance: an empty result on real audio is sometimes model
                // nondeterminism — one re-send before surfacing anything (audit L25).
                Log.transcription.info("empty transcript on \(String(format: "%.1f", seconds))s audio — one re-send")
                // NB: goes through the same policy-aware call as the primary path.
                // Sending this one down the old endpoint would leave a rare branch
                // silently on a different pipeline.
                raw = (try? await sendTranscribe(
                    flacData: flacData, seconds: seconds, source: source, config: config, policy: policy,
                    vocabulary: vocabulary, deadline: deadline
                )) ?? ""
                trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !trimmed.isEmpty { pieces.append(trimmed) }
            if ranges.count > 1 {
                done[range] = trimmed
                done.write(to: cacheURL)
            }
        }
        if ranges.count > 1 {
            try? FileManager.default.removeItem(at: cacheURL)
        }

        let trimmedRaw = pieces.joined(separator: " ")
        guard !trimmedRaw.isEmpty else {
            // The coordinator classifies silence vs dropped-transcript by energy.
            throw TranscriptionError.emptyTranscript
        }

        if context.mode != .dictate {
            let cleaned = try await transform(raw: trimmedRaw, context: context, config: config)
            return TranscriptionResult(
                rawTranscript: trimmedRaw,
                cleanedTranscript: cleaned,
                modelID: "\(names.transcribe)+\(names.writing)"
            )
        }

        guard policy.cleanupPass else {
            // Dictionary rules are a HARD guarantee — they apply on every path
            // (audit L9). The gate is deliberately NOT run here: with no second
            // model there is no independent reference, and validate(raw:X, cleaned:X)
            // passes trivially, so running it would be theatre rather than safety.
            let rules = DictionaryStore().replacementRules()
            let text = ReplacementEngine.apply(rules, to: trimmedRaw)
            return TranscriptionResult(
                rawTranscript: trimmedRaw,
                cleanedTranscript: text,
                modelID: names.transcribe
            )
        }

        let second = await Self.awaitSecondOpinion(secondOpinion, raw: trimmedRaw, audioSeconds: durationSeconds)
        let cleanup = await cleanupOrFallback(
            raw: trimmedRaw, context: context, config: config, second: second,
            rawHasFillers: transcriptKeepsFillers(source: source, policy: policy)
        )
        return TranscriptionResult(
            rawTranscript: trimmedRaw,
            cleanedTranscript: cleanup.text,
            modelID: "\(names.transcribe)+\(names.writing)",
            cleanupNote: cleanup.note
        )
    }

    /// The second transcript runs alongside the primary one; once RAW is in,
    /// waits at most `grace` more for it. MEASURED 2026-09-28: whisper-1 took
    /// 1.4–2.3 s on a 21 s dictation (gpt-transcribe 2.3–2.9 s) and 5.8–6.1 s
    /// on 84 s (gpt-transcribe 3.1 s), so the wait only shows on long ones.
    static func awaitSecondOpinion(_ task: Task<String?, Never>?, raw: String, audioSeconds: Double) async -> String? {
        guard let task else { return nil }
        let grace = min(5, max(1.5, audioSeconds * 0.04))
        let text = try? await GeminiClient.withDeadline(seconds: grace) { await task.value }
        task.cancel()
        guard let text, !text.isEmpty else {
            Log.transcription.info("second transcript not used (late or failed after \(String(format: "%.1f", grace))s grace)")
            return nil
        }
        return text.caseInsensitiveCompare(raw) == .orderedSame ? nil : text
    }

    /// The one-call dictation path. Returns nil when the caller should fall
    /// back to the two-call pipeline.
    private func transcribeInOneCall(
        audioURL: URL, range: Range<AVAudioFramePosition>, durationSeconds: Double,
        context: DictationContext, config: GeminiConfig
    ) async -> String? {
        let dictionary = DictionaryStore()
        let prompt = PromptV1.dictationPrompt(
            vocabulary: dictionary.sanitizedVocabulary(),
            spellings: dictionary.spellings(),
            instructions: settings.customInstructions,
            imagesAttached: !context.screenshots.isEmpty
        )
        do {
            let flac = try encodeChunk(audioURL: audioURL, range: range, index: 0)
            // Measured at 2–4 s for up to three minutes of audio. Tighter than
            // the transcription deadline because a miss still has the two-call
            // path to run.
            let deadline = 15 + durationSeconds / 8 + Double(context.screenshots.count * 2)
            let response = try await client.cleanup(
                prompt: prompt, images: context.screenshots, audioFLAC: flac,
                model: config.cleanupModel, endpoint: config.endpoint, deadline: deadline, stage: .transcribe,
                jsonSchema: PromptV1.dictationSchema
            )
            guard let answer = PromptV1.dictationText(fromJSON: response) else {
                // Not the object the schema asked for: never paste the model's
                // working. The two-call path has a validation gate.
                Log.transcription.warning("one call returned something other than the JSON answer — transcribing, then cleaning up")
                return nil
            }
            let text = ValidationGate.stripArtifacts(answer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.contains(PromptV1.noSpeechToken) else {
                Log.transcription.info("one call heard no speech — checking with the transcription model")
                return nil
            }
            return ReplacementEngine.apply(dictionary.replacementRules(), to: text)
        } catch {
            if case .modelUnavailable = error as? TranscriptionError {
                // A Vercel free-tier key is refused the flash model on every
                // call; stop paying for the refusal until the app restarts.
                Self.oneCallRefused.insert(settings.activeRoute)
            }
            Log.transcription.info("one call failed (\(String(describing: error), privacy: .public)) — transcribing, then cleaning up")
            return nil
        }
    }

    /// The models that run, for History's model column. OpenAI's
    /// transcription model has no smart mode, so no mode is named.
    private func modelNames(_ source: TranscriptionSource) -> (transcribe: String, writing: String) {
        var names: (transcribe: String, writing: String)
        if settings.activeRoute.provider == .openAI {
            let openAI = settings.openAIConfig
            names = (openAI.transcribeModel, openAI.writingModel)
        } else {
            let config = settings.geminiConfig
            names = ("\(config.transcribeModel)/\(settings.formattingPolicy.mode.rawValue)", config.cleanupModel)
        }
        if settings.writingSource == .sarvam { names.writing = Sarvam.chatModel }
        switch source {
        case .provider: return names
        case .elevenLabs: return (ElevenLabs.batchModel, names.writing)
        case .maiTranscribe: return (GeminiClient.maiTranscribeModel, names.writing)
        case .sarvam: return (Sarvam.sttModel, names.writing)
        }
    }

    /// Routes whose key was refused the flash model this run.
    private static let oneCallRefused = ProviderSet()
    final class ProviderSet: @unchecked Sendable {
        private let lock = NSLock()
        private var providers: Set<ModelRoute> = []
        func contains(_ provider: ModelRoute) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return providers.contains(provider)
        }
        func insert(_ provider: ModelRoute) {
            lock.lock(); defer { lock.unlock() }
            providers.insert(provider)
        }
    }

    // MARK: - Stages

    private func transform(raw: String, context: DictationContext, config: GeminiConfig) async throws -> String {
        let dictionary = DictionaryStore()
        let prompt: String
        switch context.mode {
        case .dictate:
            return raw
        case .agent:
            // The command goes to the agent model as spoken; only the
            // dictionary's hard replacements apply.
            return ReplacementEngine.apply(dictionary.replacementRules(), to: raw)
        case .askAnything(let selectedText):
            var webContext: WebContext?
            if KeychainStore.loadTinyFishKey() != nil {
                webContext = await WebContext.gather(
                    instruction: raw,
                    selectedText: selectedText,
                    gemini: client,
                    tinyFish: TinyFishClient(apiKey: { KeychainStore.loadTinyFishKey() }),
                    config: config
                )
            }
            prompt = PromptV1.askAnythingPrompt(
                instruction: raw,
                selectedText: selectedText,
                vocabulary: dictionary.sanitizedVocabulary(),
                webContext: webContext
            )
        case .translate(let target):
            prompt = PromptV1.translatePrompt(
                raw: raw, target: target, vocabulary: dictionary.sanitizedVocabulary()
            )
        }
        let stage: UsageStage = { if case .translate = context.mode { return .translate }; return .answer }()
        let response = try await client.cleanup(
            prompt: prompt,
            model: config.cleanupModel,
            endpoint: config.endpoint,
            // Web context can make the prompt far larger than the transcript;
            // the model has to read it all, so the budget follows the prompt.
            deadline: Self.cleanupDeadline(forCharacters: max(raw.count, prompt.count / 3)),
            stage: stage
        )
        var cleaned = ValidationGate.stripArtifacts(response).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TranscriptionError.emptyTranscript }
        if case .translate = context.mode, cleaned == Self.untranslatableToken {
            throw TranscriptionError.emptyTranscript
        }
        if case .askAnything = context.mode { cleaned = Self.separateSources(cleaned) }
        return cleaned
    }

    /// Puts the "Sources" line the answer prompt asks for on its own paragraph.
    /// The model writes it inline about half the time ("…$84,413.Sources: …"),
    /// and the card shows exactly what comes back, so the break is made here.
    static func separateSources(_ answer: String) -> String {
        guard let match = answer.range(
            of: #"[ \t]*\n*[ \t]*\**Sources?\**[ \t]*:?\**[ \t]*(?=\S)"#,
            options: [.regularExpression, .caseInsensitive, .backwards]
        ), match.lowerBound > answer.startIndex else { return answer }
        return answer[..<match.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\nSources: " + answer[match.upperBound...]
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

    /// Vocabulary is suppressed once it has PROVABLY broken a request.
    ///
    /// Keyed on the vocabulary itself rather than a bare flag: editing the
    /// Dictionary changes the key and we try again, so one bad entry cannot
    /// disable the feature until relaunch with nothing telling the user why.
    private static let vocabularySuppressed = Suppression()
    final class Suppression: @unchecked Sendable {
        private let lock = NSLock()
        private var blocked: Int?
        func isBlocked(_ vocabulary: [String]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return blocked != nil && blocked == vocabulary.hashValue
        }
        func block(_ vocabulary: [String]) {
            lock.lock(); blocked = vocabulary.hashValue; lock.unlock()
        }
    }

    private static func vocabularyIfEnabled() -> [String] {
        let vocabulary = DictionaryStore().sanitizedVocabulary()
        return vocabularySuppressed.isBlocked(vocabulary) ? [] : vocabulary
    }

    /// The ONE place a transcription request is sent. Every caller — primary,
    /// silent retry, and the empty-transcript second chance — goes through here.
    private func sendTranscribe(
        flacData: Data, seconds: Double, source: TranscriptionSource,
        config: GeminiConfig, policy: SettingsStore.FormattingPolicy,
        vocabulary: [String], deadline: TimeInterval
    ) async throws -> String {
        try await UsageMeter.$audioSeconds.withValue(seconds) {
            try await sendTranscribeRequest(flacData: flacData, seconds: seconds, source: source, config: config,
                                            policy: policy, vocabulary: vocabulary, deadline: deadline)
        }
    }

    private func sendTranscribeRequest(
        flacData: Data, seconds: Double, source: TranscriptionSource,
        config: GeminiConfig, policy: SettingsStore.FormattingPolicy,
        vocabulary: [String], deadline: TimeInterval
    ) async throws -> String {
        // No dictionary terms: neither gateway documents keyword biasing for
        // this model. The writing rules still get the dictionary.
        if source == .maiTranscribe, let endpoint = settings.maiTranscribeEndpoint {
            return try await client.gatewayTranscribe(audio: flacData, model: GeminiClient.maiTranscribeModel,
                                                      deadline: deadline, stage: .transcribe, via: endpoint,
                                                      maiStyle: settings.maiTranscribeStyle)
        }
        // The transport decision lives in ONE place so the fail-open retry below
        // cannot silently switch endpoints half way through a recovery.
        func send(_ terms: [String]) async throws -> String {
            if source == .elevenLabs {
                return try await client.elevenLabsTranscribe(
                    audio: flacData, keyterms: terms, noVerbatim: policy.mode == .smart,
                    audioSeconds: seconds, deadline: deadline
                )
            }
            if source == .sarvam {
                return try await client.sarvamTranscribe(
                    audio: flacData, audioSeconds: seconds, keyterms: terms, verbatim: policy.mode != .smart,
                    language: settings.sarvamLanguage, deadline: deadline
                )
            }
            if settings.usesLegacyTranscribeEndpoint {
                // Verbatim only — `mode` returns an empty transcript on this
                // endpoint. The tone pass, if enabled, still runs on top.
                return try await client.transcribe(
                    flacData: flacData, model: config.transcribeModel,
                    endpoint: config.endpoint, deadline: deadline, customVocabulary: terms
                )
            }
            return try await client.transcribeInteraction(
                audio: flacData, model: config.transcribeModel, endpoint: config.endpoint,
                mode: policy.mode, customVocabulary: terms, deadline: deadline
            )
        }

        do {
            return try await send(vocabulary)
        } catch TranscriptionError.badRequest(let message) where !vocabulary.isEmpty {
            // Fail open. badRequest is deliberately terminal everywhere else, but
            // one strange dictionary entry must never be able to break a user's
            // own dictation. Covers BOTH transports — the legacy endpoint carries
            // vocabulary too.
            Log.transcription.error("transcribe rejected with vocabulary (\(message, privacy: .private)) — retrying without it")
            let text = try await send([])
            // Only latch once the vocabulary-free retry SUCCEEDS. If it also
            // fails, the vocabulary was innocent — and a bad API key returns 400
            // here, not 401, so latching eagerly would disable the Dictionary for
            // the rest of the launch over an auth problem.
            Self.vocabularySuppressed.block(vocabulary)
            return text
        }
    }

    private func transcribeWithRetry(
        flacData: Data, seconds: Double, source: TranscriptionSource,
        config: GeminiConfig, policy: SettingsStore.FormattingPolicy,
        vocabulary: [String], deadline: TimeInterval
    ) async throws -> String {
        do {
            return try await sendTranscribe(
                flacData: flacData, seconds: seconds, source: source, config: config, policy: policy,
                vocabulary: vocabulary, deadline: deadline
            )
        } catch let error as TranscriptionError {
            switch error {
            case .network, .timeout:
                // One silent retry for transient classes (audio is safe on disk).
                // Every request has its own connection, so a timeout retries at
                // once; a server error waits half a second first.
                Log.transcription.notice("transcribe retrying after \(String(describing: error), privacy: .public)")
                if case .network = error { try await Task.sleep(nanoseconds: 500_000_000) }
                return try await sendTranscribe(
                    flacData: flacData, seconds: seconds, source: source, config: config, policy: policy,
                    vocabulary: vocabulary, deadline: deadline
                )
            case .rateLimitedTransient(let retryAfter):
                // A per-minute throttle names its own wait. Sitting it out once
                // keeps a long dictation on the pill instead of failing it to
                // History, where the retry would hit the same wall.
                let wait = retryAfter ?? TimeoutPolicy.rateLimitWait
                guard wait <= TimeoutPolicy.rateLimitWait else { throw error }
                Log.transcription.info("transcribe rate limited — waiting \(Int(wait))s once")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                return try await sendTranscribe(
                    flacData: flacData, seconds: seconds, source: source, config: config, policy: policy,
                    vocabulary: vocabulary, deadline: deadline
                )
            default:
                throw error
            }
        }
    }
}
