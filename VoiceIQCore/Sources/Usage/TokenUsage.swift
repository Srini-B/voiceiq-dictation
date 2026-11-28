import Foundation

/// Token counts for one model call, split the way providers price them.
///
/// The parser is defensive: a missing field is zero, never a thrown error,
/// because billing bookkeeping must not be able to fail a dictation. Rows
/// booked by older builds keep their audio and image counts.
public struct TokenUsage: Equatable, Sendable, Codable {
    public var textIn: Int = 0
    public var audioIn: Int = 0
    public var imageIn: Int = 0
    public var cachedIn: Int = 0
    /// Anthropic cache writes, already counted in `textIn`. Billed at 1.25x
    /// input for the five-minute cache and 2x for the one-hour cache; only
    /// the booked cost carries the surcharge, so they are not stored.
    public var cacheWrite5m: Int = 0
    public var cacheWrite1h: Int = 0
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
                cacheWrite5m: Int = 0, cacheWrite1h: Int = 0,
                textOut: Int = 0, audioOut: Int = 0, thoughtOut: Int = 0, isEstimated: Bool = false,
                reportedCostUSD: Double? = nil, audioSeconds: Double? = nil) {
        self.textIn = textIn; self.audioIn = audioIn; self.imageIn = imageIn; self.cachedIn = cachedIn
        self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
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
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m, cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            textOut: lhs.textOut + rhs.textOut, audioOut: lhs.audioOut + rhs.audioOut,
            thoughtOut: lhs.thoughtOut + rhs.thoughtOut,
            isEstimated: lhs.isEstimated || rhs.isEstimated,
            reportedCostUSD: lhs.reportedCostUSD == nil && rhs.reportedCostUSD == nil
                ? nil : (lhs.reportedCostUSD ?? 0) + (rhs.reportedCostUSD ?? 0),
            audioSeconds: lhs.audioSeconds == nil && rhs.audioSeconds == nil
                ? nil : (lhs.audioSeconds ?? 0) + (rhs.audioSeconds ?? 0)
        )
    }

    // MARK: - LLM Gateway chat completions

    /// `usage` of a chat completion (OpenAI's shape, which the AssemblyAI LLM
    /// Gateway returns for every model): `prompt_tokens` including
    /// `prompt_tokens_details.cached_tokens`, `completion_tokens` including
    /// `completion_tokens_details.reasoning_tokens`.
    public static func fromChatCompletion(_ data: Data) -> TokenUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["usage"] as? [String: Any] else { return nil }
        let cached = int(meta["prompt_tokens_details"] as? [String: Any] ?? [:], "cachedTokens", "cached_tokens")
        let reasoning = int(meta["completion_tokens_details"] as? [String: Any] ?? [:], "reasoningTokens", "reasoning_tokens")
        let completion = int(meta, "completionTokens", "completion_tokens")
        return TokenUsage(textIn: max(0, int(meta, "promptTokens", "prompt_tokens") - cached), cachedIn: cached,
                          textOut: max(0, completion - reasoning), thoughtOut: reasoning)
    }

    // MARK: - Helpers

    private static func int(_ node: [String: Any], _ camel: String, _ snake: String) -> Int {
        ((node[camel] ?? node[snake]) as? NSNumber)?.intValue ?? 0
    }
}
