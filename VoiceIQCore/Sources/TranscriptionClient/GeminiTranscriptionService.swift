import AVFoundation
import Foundation

/// The transcription pipeline.
///
///   CAF → FLAC → transcription model (gemini-3.5-transcribe in smart mode
///   with custom_vocabulary, or gpt-transcribe)
///       → [writing rules] writing model cleanup, with any screenshots
///       → validation gate → ReplacementEngine → inserted text.
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
        let provider = settings.preferredProvider
        let names = modelNames(provider)

        // One request per chunk. A short dictation is one chunk, so this is the
        // old single-request path for everything under ten minutes. Leading and
        // trailing silence is left out of every request.
        let (ranges, fileFrames) = try AudioChunker.ranges(cafURL: audioURL)

        // A multi-chunk upload can fail half way (Tier 1 meters ~400 s of audio
        // per minute, so chunk 1 is often refused right after chunk 0). Finished
        // chunks are kept next to the audio so a retry sends only the rest.
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
            let flacData = try encodeChunk(audioURL: audioURL, range: range, index: index)
            let seconds = durationSeconds * Double(range.count) / Double(max(1, fileFrames))
            let deadline = TimeoutPolicy.overallDeadline(audioDuration: seconds)
            var raw = try await transcribeWithRetry(
                flacData: flacData, seconds: seconds, config: config, policy: policy,
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
                    flacData: flacData, seconds: seconds, config: config, policy: policy,
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
        return try await process(
            TranscriptionResult(rawTranscript: trimmedRaw, cleanedTranscript: trimmedRaw, modelID: names.transcribe),
            context: context, config: config, policy: policy, provider: provider, writingModel: names.writing
        )
    }

    public func process(_ transcript: TranscriptionResult, context: DictationContext) async throws -> TranscriptionResult {
        let provider = settings.preferredProvider
        return try await process(transcript, context: context, config: settings.geminiConfig,
                                 policy: settings.formattingPolicy, provider: provider,
                                 writingModel: modelNames(provider).writing)
    }

    private func process(
        _ transcript: TranscriptionResult, context: DictationContext,
        config: GeminiConfig, policy: SettingsStore.FormattingPolicy,
        provider: ModelProvider, writingModel: String
    ) async throws -> TranscriptionResult {
        let trimmedRaw = transcript.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            // The coordinator classifies silence vs dropped-transcript by energy.
            throw TranscriptionError.emptyTranscript
        }

        if context.mode != .dictate {
            let cleaned = try await transform(raw: trimmedRaw, context: context, config: config)
            return TranscriptionResult(
                rawTranscript: trimmedRaw,
                cleanedTranscript: cleaned,
                modelID: context.mode == .agent ? transcript.modelID : "\(transcript.modelID)+\(writingModel)"
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
                modelID: transcript.modelID
            )
        }

        let cleanup = await cleanupOrFallback(
            raw: trimmedRaw, context: context, config: config,
            rawHasFillers: transcriptKeepsFillers(provider: provider, policy: policy)
        )
        return TranscriptionResult(
            rawTranscript: trimmedRaw,
            cleanedTranscript: cleanup.text,
            modelID: "\(transcript.modelID)+\(writingModel)",
            cleanupNote: cleanup.note
        )
    }

    /// The models that run, for History's model column. OpenAI's
    /// transcription model has no smart mode, so no mode is named.
    private func modelNames(_ provider: ModelProvider) -> (transcribe: String, writing: String) {
        if provider == .openAI {
            let openAI = settings.openAIConfig
            return (openAI.transcribeModel, openAI.writingModel)
        }
        let config = settings.geminiConfig
        return ("\(config.transcribeModel)/\(settings.formattingPolicy.mode.rawValue)", config.cleanupModel)
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
        flacData: Data, seconds: Double,
        config: GeminiConfig, policy: SettingsStore.FormattingPolicy,
        vocabulary: [String], deadline: TimeInterval
    ) async throws -> String {
        try await UsageMeter.$audioSeconds.withValue(seconds) {
            try await sendTranscribeRequest(flacData: flacData, config: config,
                                            policy: policy, vocabulary: vocabulary, deadline: deadline)
        }
    }

    private func sendTranscribeRequest(
        flacData: Data,
        config: GeminiConfig, policy: SettingsStore.FormattingPolicy,
        vocabulary: [String], deadline: TimeInterval
    ) async throws -> String {
        func send(_ terms: [String]) async throws -> String {
            try await client.transcribeInteraction(
                audio: flacData, model: config.transcribeModel, endpoint: config.endpoint,
                mode: policy.mode, customVocabulary: terms, deadline: deadline
            )
        }

        do {
            return try await send(vocabulary)
        } catch TranscriptionError.badRequest(let message) where !vocabulary.isEmpty {
            // Fail open. badRequest is deliberately terminal everywhere else, but
            // one strange dictionary entry must never be able to break a user's
            // own dictation.
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
        flacData: Data, seconds: Double,
        config: GeminiConfig, policy: SettingsStore.FormattingPolicy,
        vocabulary: [String], deadline: TimeInterval
    ) async throws -> String {
        do {
            return try await sendTranscribe(
                flacData: flacData, seconds: seconds, config: config, policy: policy,
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
                    flacData: flacData, seconds: seconds, config: config, policy: policy,
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
                    flacData: flacData, seconds: seconds, config: config, policy: policy,
                    vocabulary: vocabulary, deadline: deadline
                )
            default:
                throw error
            }
        }
    }
}
