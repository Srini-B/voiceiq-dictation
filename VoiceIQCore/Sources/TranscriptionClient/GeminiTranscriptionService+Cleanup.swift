import Foundation
import VoiceIQBridge

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
    }

    func cleanupOrFallback(
        raw: String, context: DictationContext, config: GeminiConfig, rawHasFillers: Bool,
        normalized: String? = nil
    ) async -> SettledCleanup {
        settle(await runCleanup(raw: raw, context: context, config: config, normalized: normalized),
               raw: raw, rawHasFillers: rawHasFillers)
    }

    /// Whether the transcript can still carry "uh" and "um". Gemini's
    /// verbatim mode writes every one it hears; OpenAI's transcription model
    /// has no smart mode; Scribe drops them only when asked not to be verbatim.
    func transcriptKeepsFillers(source: TranscriptionSource, provider: ModelProvider,
                                policy: SettingsStore.FormattingPolicy) -> Bool {
        switch source {
        case .elevenLabs: return policy.mode != .smart
        case .onDevice, .provider: return provider == .openAI || policy.mode != .smart
        }
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
        let prompt = PromptV1.cleanupPrompt(
            raw: raw,
            vocabulary: dictionary.sanitizedVocabulary(),
            spellings: dictionary.spellings(),
            instructions: settings.customInstructions,
            spelling: settings.spellingVariant.promptLine,
            imagesAttached: !screenshots.isEmpty,
            surroundingText: settings.fitToExistingText ? context.focusedField?.surroundingText : nil,
            place: place,
            normalized: normalized
        )
        do {
            let deadline = min(
                60,
                Self.cleanupDeadline(forCharacters: raw.count)
                    + Double(screenshots.count * 2)
            )
            let response = try await client.cleanupWithFreshRetry(
                prompt: prompt, images: screenshots,
                model: config.cleanupModel, endpoint: config.endpoint, deadline: deadline
            )
            let cleaned = ValidationGate.stripArtifacts(response)
            let verdict = ValidationGate.validate(raw: raw, cleaned: cleaned)
            guard verdict.accepted else { return .rejected(reason: verdict.reason ?? "?") }
            return .accepted(cleaned)
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
