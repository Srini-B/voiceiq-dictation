import Foundation

/// The writing-rules pass of a dictation, and what is inserted when it fails.
extension GeminiTranscriptionService {
    private enum CleanupOutcome {
        case accepted(String)
        case rejected(reason: String)
        case unavailable(reason: String)
    }

    /// The text to insert, and why the writing rules did not shape it when
    /// they did not. The note is kept in History so a raw paste explains itself.
    struct SettledCleanup {
        var text: String
        var note: String?
    }

    func cleanupOrFallback(
        raw: String, context: DictationContext, config: GeminiConfig, second: String? = nil, rawHasFillers: Bool
    ) async -> SettledCleanup {
        settle(await runCleanup(raw: raw, context: context, config: config, second: second),
               raw: raw, rawHasFillers: rawHasFillers)
    }

    /// Whether the transcript can still carry "uh" and "um". MAI Transcribe 2
    /// in its Verbatim style, and ElevenLabs and Sarvam in verbatim mode,
    /// write every one they hear, as does Gemini's verbatim mode; OpenAI's
    /// transcription model has no smart mode.
    func transcriptKeepsFillers(source: TranscriptionSource, policy: SettingsStore.FormattingPolicy) -> Bool {
        switch source {
        case .maiTranscribe: return settings.maiTranscribeStyle == .verbatim
        case .elevenLabs, .sarvam: return policy.mode != .smart
        case .provider:
            return settings.activeRoute.provider == .openAI
                || policy.mode != .smart
                || settings.usesLegacyTranscribeEndpoint
        }
    }

    /// Turns a cleanup outcome into the text to insert. The dictionary's hard
    /// guarantee applies on every branch: explicit wrong→right rules always win.
    private func settle(_ outcome: CleanupOutcome, raw: String, rawHasFillers: Bool) -> SettledCleanup {
        let rules = DictionaryStore().replacementRules()
        let reason: String
        switch outcome {
        case .accepted(let cleaned):
            return SettledCleanup(text: ReplacementEngine.apply(rules, to: cleaned))
        case .rejected(let why):
            // Writing rules stay on: only the user turns them off. One bad
            // rewrite costs that dictation its formatting, nothing more.
            reason = "Writing rules skipped: the rewrite was rejected (\(why))"
        case .unavailable(let why):
            reason = "Writing rules skipped: cleanup \(why)"
        }
        // Without the writing model nothing else removes hesitation sounds
        // from a verbatim transcript.
        let base = rawHasFillers ? FillerStripper.strip(raw) : raw
        let note = base == raw ? reason : reason + "; filler words removed"
        Log.transcription.error("\(note, privacy: .public). Inserting the transcript.")
        return SettledCleanup(text: ReplacementEngine.apply(rules, to: base), note: note)
    }

    private func runCleanup(
        raw: String, context: DictationContext, config: GeminiConfig, second: String? = nil
    ) async -> CleanupOutcome {
        let dictionary = DictionaryStore()
        // Sarvam's writing model takes text only, so the prompt must not
        // promise it screenshots it will never see.
        let screenshots = settings.writingSource == .sarvam ? [] : context.screenshots
        let prompt = PromptV1.cleanupPrompt(
            raw: raw,
            vocabulary: dictionary.sanitizedVocabulary(),
            spellings: dictionary.spellings(),
            instructions: settings.customInstructions,
            imagesAttached: !screenshots.isEmpty,
            secondTranscript: second
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
