import Foundation
import VoiceIQBridge
import VoiceIQSpeech

/// The writing-rules pass of a dictation, and what is inserted when it fails.
extension GeminiTranscriptionService {
    private enum CleanupOutcome {
        case accepted(String)
        case rejected(reason: String)
        case unavailable(reason: String)
    }

    /// The text to insert, and why the writing rules did not shape it when
    /// they did not. The skip's note is kept in History so a raw paste explains itself.
    struct SettledCleanup {
        var text: String
        var skip: CleanupSkip?
        /// The on-device writer's model ID when it wrote, or tried to.
        var localWriter: String?
    }

    func cleanupOrFallback(
        raw: String, context: DictationContext, config: GeminiConfig, rawHasFillers: Bool,
        normalized: String? = nil
    ) async -> SettledCleanup {
        if let local = await runLocalCleanup(raw: raw, context: context) {
            var settled = settle(local.outcome, raw: raw, rawHasFillers: rawHasFillers)
            settled.localWriter = local.model.modelID
            return settled
        }
        return settle(await runCleanup(raw: raw, context: context, config: config, normalized: normalized),
                      raw: raw, rawHasFillers: rawHasFillers)
    }

    /// VoiceIQ Writer, when on-device writing is on and the selected size is
    /// downloaded; nil leaves the dictation to the provider. The output goes
    /// through the same gate as the cloud's. There is no reminder retry: the
    /// model learned the default rules only, so a dictated question it
    /// answered inserts the transcript.
    private func runLocalCleanup(raw: String, context: DictationContext) async -> (model: LocalWriterModel, outcome: CleanupOutcome)? {
        guard settings.writingSource == .onDevice, let makeWriter else { return nil }
        let model = settings.localWriterModel
        let id = UUID()
        let session = makeWriter(model)
        guard let directory = await MainActor.run(body: {
            LocalModelStore.store(for: model).acquireSession(id: id, cancel: { await session.stop() })
        }) else { return nil }
        let field = settings.fitToExistingText ? context.focusedField?.surroundingText : nil
        let user = LocalWriterPrompt.user(
            raw: raw, vocabulary: DictionaryStore().sanitizedVocabulary(), app: context.targetAppName,
            title: context.focusedField?.windowTitle, page: context.focusedField?.pageURL,
            before: field?.before, after: field?.after
        )
        let request = LocalWriterRequest(user: user, maxTokens: LocalWriterPrompt.maxTokens(raw: raw))
        #if os(iOS)
        // The speech model is already released (`LocalTranscriber.finish`).
        // Holding warm-ups and the next dictation's load until the writer is
        // freed keeps the two models out of memory together.
        let output = await LocalModelWarmup.alone {
            Log.transcription.notice("Writer loading; footprint \(ProcessFootprint.bytes / 1_048_576, privacy: .public) MB")
            let output = await session.write(request, directory: directory)
            await session.stop()
            Log.transcription.notice("Writer released; footprint \(ProcessFootprint.bytes / 1_048_576, privacy: .public) MB")
            return output
        } ?? nil
        #else
        let output = await session.write(request, directory: directory)
        await session.stop()
        #endif
        await MainActor.run { LocalModelStore.store(for: model).releaseSession(id: id) }
        guard let output else { return (model, .unavailable(reason: "failed (on-device writer)")) }
        Log.transcription.notice("Writer \(model.modelID, privacy: .public): load \(output.loadSeconds.map { String(format: "%.2fs", $0) } ?? "warm", privacy: .public), first token \(output.firstTokenSeconds, format: .fixed(precision: 2))s, total \(output.totalSeconds, format: .fixed(precision: 2))s, \(output.promptTokens) prompt + \(output.generatedTokens) generated tokens, memory \(output.memoryBytes / 1_048_576) MB")
        UsageMeter.record(stage: .cleanup, model: model.modelID,
                          usage: TokenUsage(textIn: output.promptTokens, textOut: output.generatedTokens, reportedCostUSD: 0))
        let cleaned = ValidationGate.stripArtifacts(output.text)
        let verdict = ValidationGate.validate(raw: raw, cleaned: cleaned)
        guard verdict.accepted else { return (model, .rejected(reason: verdict.reason ?? "?")) }
        return (model, .accepted(cleaned))
    }

    /// Whether the transcript can still carry "uh" and "um". Gemini's
    /// verbatim mode writes every one it hears; OpenAI's transcription model
    /// and the on-device models have no smart mode.
    func transcriptKeepsFillers(provider: ModelProvider, policy: SettingsStore.FormattingPolicy) -> Bool {
        provider != .gemini || policy.mode != .smart
    }

    /// Turns a cleanup outcome into the text to insert. The dictionary's hard
    /// guarantee applies on every branch: explicit wrong→right rules always win.
    private func settle(_ outcome: CleanupOutcome, raw: String, rawHasFillers: Bool) -> SettledCleanup {
        let rules = DictionaryStore().replacementRules()
        let cause: CleanupSkip.Cause
        let reason: String
        switch outcome {
        case .accepted(let cleaned):
            return SettledCleanup(text: ReplacementEngine.apply(rules, to: cleaned))
        case .rejected(let why):
            // Writing rules stay on: only the user turns them off. One bad
            // rewrite costs that dictation its formatting, nothing more.
            cause = .rewriteRejected
            reason = "Writing rules skipped: the rewrite was rejected (\(why))"
        case .unavailable(let why):
            cause = .requestFailed
            reason = "Writing rules skipped: cleanup \(why)"
        }
        // Without the writing model nothing else removes hesitation sounds
        // from a verbatim transcript.
        let base = rawHasFillers ? FillerStripper.strip(raw) : raw
        let fillersRemoved = base != raw
        let note = fillersRemoved ? reason + "; filler words removed" : reason
        Log.transcription.error("\(note, privacy: .public). Inserting the transcript.")
        return SettledCleanup(text: ReplacementEngine.apply(rules, to: base),
                              skip: CleanupSkip(cause: cause, fillersRemoved: fillersRemoved, note: note))
    }

    private func runCleanup(
        raw: String, context: DictationContext, config: GeminiConfig, normalized: String?
    ) async -> CleanupOutcome {
        let dictionary = DictionaryStore()
        let screenshots = context.screenshots
        let place = DictationPlace(appName: context.targetAppName,
                                   windowTitle: context.focusedField?.windowTitle,
                                   pageURL: context.focusedField?.pageURL)
        Log.transcription.info("cleanup place: app=\(place.appName ?? "-", privacy: .public) title=\(place.windowTitle ?? "-", privacy: .private) page=\(place.pageURL ?? "-", privacy: .private) (page \(place.pageURL?.count ?? 0, privacy: .public) chars)")
        let vocabulary = dictionary.sanitizedVocabulary(), spellings = dictionary.spellings()
        let surrounding = settings.fitToExistingText ? context.focusedField?.surroundingText : nil
        let deadline = min(60, Self.cleanupDeadline(forCharacters: raw.count) + Double(screenshots.count * 2))
        func attempt(reminder: String?) async throws -> CleanupOutcome {
            let prompt = PromptV1.cleanupPrompt(
                raw: raw, vocabulary: vocabulary, spellings: spellings,
                customRules: settings.customWritingRules, spelling: settings.spellingVariant.promptLine,
                imagesAttached: !screenshots.isEmpty, surroundingText: surrounding, place: place,
                normalized: normalized, reminder: reminder
            )
            let response = try await client.cleanupWithFreshRetry(
                prompt: prompt, images: screenshots,
                model: config.cleanupModel, endpoint: config.endpoint, deadline: deadline
            )
            let cleaned = ValidationGate.stripArtifacts(response)
            let verdict = ValidationGate.validate(raw: raw, cleaned: cleaned)
            guard verdict.accepted else { return .rejected(reason: verdict.reason ?? "?") }
            return .accepted(cleaned)
        }
        do {
            let first = try await attempt(reminder: nil)
            // The model answered a dictated question instead of writing it
            // down. Ask once more with a reminder; a second answer, or a failed
            // request, keeps the first rejection.
            guard case .rejected(reason: ValidationGate.questionAnswered) = first else { return first }
            Log.transcription.info("cleanup answered a dictated question; retrying with a reminder")
            guard let second = try? await attempt(reminder: PromptV1.questionReminder),
                  case .accepted = second else { return first }
            return second
        } catch {
            // Deadline miss / network hiccup on cleanup never costs the dictation —
            // and the dictionary guarantee still holds (audit L9).
            return .unavailable(reason: Self.describeCleanupFailure(error))
        }
    }

    static func describeCleanupFailure(_ error: Error) -> String {
        switch error as? TranscriptionError {
        case .timeout: return "timed out"
        case .offline: return "could not connect"
        case .network(let detail): return "failed (network: \(detail))"
        case .some(let other): return "failed (\(other))"
        case .none: return "failed (\(error.localizedDescription))"
        }
    }
}
