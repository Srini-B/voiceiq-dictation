import Foundation

/// Token counts for one model call, split the way Gemini prices them.
///
/// Three response envelopes carry usage and none of them agree on field
/// names, so each has its own parser here. Every parser is defensive: a
/// missing field is zero, never a thrown error, because billing bookkeeping
/// must not be able to fail a dictation.
public struct TokenUsage: Equatable, Sendable, Codable {
    public var textIn: Int = 0
    public var audioIn: Int = 0
    public var imageIn: Int = 0
    public var cachedIn: Int = 0
    public var textOut: Int = 0
    public var audioOut: Int = 0
    public var thoughtOut: Int = 0
    /// True when the server never reported counts and these are derived from
    /// audio length and output characters.
    public var isEstimated: Bool = false
    /// USD charged for the call when it is known without the token price
    /// book: a per-minute model's list price, or a host that states its
    /// charge. Takes precedence over the price book.
    public var reportedCostUSD: Double? = nil
    /// Seconds of audio the call was billed for, on models priced by audio
    /// length instead of tokens.
    public var audioSeconds: Double? = nil

    public init(textIn: Int = 0, audioIn: Int = 0, imageIn: Int = 0, cachedIn: Int = 0,
                textOut: Int = 0, audioOut: Int = 0, thoughtOut: Int = 0, isEstimated: Bool = false,
                reportedCostUSD: Double? = nil, audioSeconds: Double? = nil) {
        self.textIn = textIn; self.audioIn = audioIn; self.imageIn = imageIn; self.cachedIn = cachedIn
        self.textOut = textOut; self.audioOut = audioOut; self.thoughtOut = thoughtOut
        self.isEstimated = isEstimated
        self.reportedCostUSD = reportedCostUSD
        self.audioSeconds = audioSeconds
    }

    public var totalIn: Int { textIn + audioIn + imageIn + cachedIn }
    public var totalOut: Int { textOut + audioOut + thoughtOut }
    public var isEmpty: Bool { totalIn == 0 && totalOut == 0 }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            textIn: lhs.textIn + rhs.textIn, audioIn: lhs.audioIn + rhs.audioIn,
            imageIn: lhs.imageIn + rhs.imageIn, cachedIn: lhs.cachedIn + rhs.cachedIn,
            textOut: lhs.textOut + rhs.textOut, audioOut: lhs.audioOut + rhs.audioOut,
            thoughtOut: lhs.thoughtOut + rhs.thoughtOut,
            isEstimated: lhs.isEstimated || rhs.isEstimated,
            reportedCostUSD: lhs.reportedCostUSD == nil && rhs.reportedCostUSD == nil
                ? nil : (lhs.reportedCostUSD ?? 0) + (rhs.reportedCostUSD ?? 0),
            audioSeconds: lhs.audioSeconds == nil && rhs.audioSeconds == nil
                ? nil : (lhs.audioSeconds ?? 0) + (rhs.audioSeconds ?? 0)
        )
    }

    // MARK: - OpenAI-shaped envelopes

    /// `usage` from OpenAI-shaped responses: token counts plus `cost` in USD
    /// when the host states it. Audio and cached prompt tokens come from
    /// `prompt_tokens_details`, reasoning tokens from
    /// `completion_tokens_details`; a transcription endpoint reports
    /// `input_tokens`/`output_tokens` instead, all of its input being audio.
    public static func fromOpenAI(_ data: Data) -> TokenUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["usage"] as? [String: Any] else { return nil }
        var usage = TokenUsage()
        let promptDetails = meta["prompt_tokens_details"] as? [String: Any] ?? [:]
        let outDetails = meta["completion_tokens_details"] as? [String: Any] ?? [:]
        usage.cachedIn = int(promptDetails, "cached_tokens", "cachedTokens")
        usage.audioIn = int(promptDetails, "audio_tokens", "audioTokens")
        usage.thoughtOut = int(outDetails, "reasoning_tokens", "reasoningTokens")
        usage.audioOut = int(outDetails, "audio_tokens", "audioTokens")
        if meta["prompt_tokens"] != nil {
            usage.textIn = max(0, int(meta, "prompt_tokens", "promptTokens") - usage.cachedIn - usage.audioIn)
            usage.textOut = max(0, int(meta, "completion_tokens", "completionTokens") - usage.thoughtOut - usage.audioOut)
        } else {
            usage.audioIn = int(meta, "input_tokens", "inputTokens")
            usage.textOut = int(meta, "output_tokens", "outputTokens")
        }
        usage.reportedCostUSD = (meta["cost"] as? NSNumber)?.doubleValue
        return usage
    }

    /// OpenAI's transcription models bill per minute and report
    /// `usage: {type: "duration", seconds}`. There are no tokens to count, so
    /// the charge is the list price for those seconds.
    public static func fromOpenAIDuration(_ data: Data, model: String) -> TokenUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["usage"] as? [String: Any], meta["type"] as? String == "duration",
              let seconds = (meta["seconds"] as? NSNumber)?.doubleValue else { return nil }
        return fromAudioMinutes(seconds: seconds, model: model)
    }

    public static func fromAudioMinutes(seconds: Double, model: String) -> TokenUsage? {
        guard let perMinute = PriceBook.perMinutePrice(for: model) else { return nil }
        return TokenUsage(reportedCostUSD: seconds / 60 * perMinute, audioSeconds: seconds)
    }

    // MARK: - Agent mode hosts

    /// Anthropic Messages `usage`: `input_tokens` excludes the cached part,
    /// which arrives as `cache_read_input_tokens`; `cache_creation_input_tokens`
    /// is billed as input at the write rate, so it counts as text in.
    public static func fromAnthropic(_ data: Data) -> TokenUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["usage"] as? [String: Any] else { return nil }
        var usage = TokenUsage()
        usage.cachedIn = int(meta, "cache_read_input_tokens", "cacheReadInputTokens")
        usage.textIn = int(meta, "input_tokens", "inputTokens") + int(meta, "cache_creation_input_tokens", "cacheCreationInputTokens")
        usage.textOut = int(meta, "output_tokens", "outputTokens")
        return usage
    }

    /// OpenAI Responses `usage`: `input_tokens` includes the cached part
    /// reported under `input_tokens_details.cached_tokens`.
    public static func fromOpenAIResponses(_ data: Data) -> TokenUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["usage"] as? [String: Any] else { return nil }
        var usage = TokenUsage()
        let inDetails = meta["input_tokens_details"] as? [String: Any] ?? [:]
        let outDetails = meta["output_tokens_details"] as? [String: Any] ?? [:]
        usage.cachedIn = int(inDetails, "cached_tokens", "cachedTokens")
        usage.thoughtOut = int(outDetails, "reasoning_tokens", "reasoningTokens")
        usage.textIn = max(0, int(meta, "input_tokens", "inputTokens") - usage.cachedIn)
        usage.textOut = max(0, int(meta, "output_tokens", "outputTokens") - usage.thoughtOut)
        return usage
    }

    // MARK: - Estimation

    /// Gemini bills audio at 32 tokens per second and text at roughly four
    /// characters per token. Used only when the server sent no counts.
    public static let audioTokensPerSecond = 32.0

    public static func estimated(audioSeconds: Double, outputCharacters: Int,
                                 audioTokensPerSecond rate: Double = audioTokensPerSecond) -> TokenUsage {
        TokenUsage(
            audioIn: Int((audioSeconds * rate).rounded()),
            textOut: Int((Double(outputCharacters) / 4).rounded()),
            isEstimated: true
        )
    }

    // MARK: - `:generateContent`

    /// `usageMetadata` as returned by `models/*:generateContent` (probed 2026-09-26):
    /// `promptTokenCount`, `candidatesTokenCount`, optional `thoughtsTokenCount`,
    /// `cachedContentTokenCount`, and per-modality `promptTokensDetails` /
    /// `candidatesTokensDetails` as `[{modality, tokenCount}]`.
    public static func fromGenerateContent(_ data: Data) -> TokenUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["usageMetadata"] as? [String: Any] else { return nil }
        return fromUsageMetadata(meta)
    }

    /// REST `usageMetadata`; also accepts `responseTokenCount` /
    /// `responseTokensDetails` in place of the candidates fields.
    static func fromUsageMetadata(_ meta: [String: Any]) -> TokenUsage {
        var usage = TokenUsage()
        let promptDetails = details(meta, "promptTokensDetails", "prompt_tokens_details", countKey: "tokenCount")
        let outDetails = details(meta, "candidatesTokensDetails", "candidates_tokens_details", countKey: "tokenCount")
            + details(meta, "responseTokensDetails", "response_tokens_details", countKey: "tokenCount")
        usage.cachedIn = int(meta, "cachedContentTokenCount", "cached_content_token_count")
        usage.thoughtOut = int(meta, "thoughtsTokenCount", "thoughts_token_count")
        if promptDetails.isEmpty {
            usage.textIn = max(0, int(meta, "promptTokenCount", "prompt_token_count") - usage.cachedIn)
        } else {
            apply(promptDetails, input: true, to: &usage)
            // Details include cached tokens under their modality; keep the split
            // additive so the total still matches the server's promptTokenCount.
            usage.textIn = max(0, usage.textIn - usage.cachedIn)
        }
        if outDetails.isEmpty {
            usage.textOut = int(meta, "candidatesTokenCount", "candidates_token_count")
                + int(meta, "responseTokenCount", "response_token_count")
        } else {
            apply(outDetails, input: false, to: &usage)
        }
        return usage
    }

    // MARK: - `v1beta/interactions`

    /// `usage` as returned by the interactions envelope (probed 2026-09-26).
    /// `total_output_tokens` came back 0 while `model_invocation_token_counts`
    /// carried 307 output tokens, so the per-invocation list is authoritative
    /// and the totals are only a fallback.
    public static func fromInteraction(_ data: Data) -> TokenUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["usage"] as? [String: Any] else { return nil }
        var usage = TokenUsage()
        usage.cachedIn = int(meta, "total_cached_tokens", "totalCachedTokens")
        usage.thoughtOut = int(meta, "total_thought_tokens", "totalThoughtTokens")
        let invocations = (meta["model_invocation_token_counts"] ?? meta["modelInvocationTokenCounts"]) as? [[String: Any]] ?? []
        if invocations.isEmpty {
            apply(details(meta, "input_tokens_by_modality", "inputTokensByModality", countKey: "tokens"), input: true, to: &usage)
            if usage.totalIn == 0 { usage.textIn = int(meta, "total_input_tokens", "totalInputTokens") }
            usage.textOut = int(meta, "total_output_tokens", "totalOutputTokens")
        } else {
            for invocation in invocations {
                apply(details(invocation, "prompt_tokens_details", "promptTokensDetails", countKey: "tokens"), input: true, to: &usage)
                apply(details(invocation, "candidates_tokens_details", "candidatesTokensDetails", countKey: "tokens"), input: false, to: &usage)
            }
        }
        return usage
    }

    // MARK: - Helpers

    private static func int(_ node: [String: Any], _ camel: String, _ snake: String) -> Int {
        ((node[camel] ?? node[snake]) as? NSNumber)?.intValue ?? 0
    }

    private static func details(_ node: [String: Any], _ camel: String, _ snake: String, countKey: String) -> [(String, Int)] {
        let list = (node[camel] ?? node[snake]) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let modality = entry["modality"] as? String else { return nil }
            let count = (entry[countKey] as? NSNumber)?.intValue
                ?? (entry["tokenCount"] as? NSNumber)?.intValue
                ?? (entry["tokens"] as? NSNumber)?.intValue ?? 0
            return (modality.uppercased(), count)
        }
    }

    private static func apply(_ details: [(String, Int)], input: Bool, to usage: inout TokenUsage) {
        for (modality, count) in details {
            switch (modality, input) {
            case ("AUDIO", true): usage.audioIn += count
            case ("IMAGE", true), ("VIDEO", true): usage.imageIn += count
            case (_, true): usage.textIn += count
            case ("AUDIO", false): usage.audioOut += count
            case (_, false): usage.textOut += count
            }
        }
    }
}
