import Foundation

/// The vendor a model id names. Caching rules follow the model, not the
/// host: a Claude model behind CLIProxyAPI or another proxy still wants
/// Anthropic breakpoints, and a GPT model behind a proxy still wants its
/// cache key.
public enum ModelFamily: String, Equatable, Sendable {
    case openAI
    case anthropic
    case google
    case other

    /// From the id's prefix, after any `vendor/` routing prefix such as
    /// `openai/gpt-4.1`. The Anthropic and Gemini request
    /// formats name their vendor outright.
    public static func infer(modelID: String, format: AgentAPIFormat) -> ModelFamily {
        switch format {
        case .anthropicMessages: return .anthropic
        case .googleGenerativeAI: return .google
        case .openAIChat, .openAIResponses: break
        }
        var name = modelID.lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.hasPrefix("claude") { return .anthropic }
        if name.hasPrefix("gemini") || name.hasPrefix("gemma") { return .google }
        if name.hasPrefix("gpt") || name.hasPrefix("chatgpt") || name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") {
            return .openAI
        }
        return .other
    }
}

/// What one session sends so the host can reuse its prefix. Decided once
/// from the endpoint, then applied by every adapter.
///
/// - OpenAI models: `prompt_cache_key`, one per session. Models before
///   GPT-5.6 use it to route every call to the machine holding the cache
///   (measured: three of four calls missed without it); 5.6 and later route
///   automatically and treat it as accounting. Retention and TTL fields are
///   left at their defaults: 24h is already the default for earlier models,
///   and 30m is the only value for 5.6 and later.
/// - Claude models: Anthropic `cache_control` breakpoints. The static
///   prefix (tools, system) is written with a one-hour TTL, so a user who
///   comes back after a pause still reads it; the moving breakpoint on the
///   newest turn uses the five-minute TTL, since the next call usually
///   follows within seconds. Anthropic requires the longer TTL to come
///   first, which this order satisfies.
/// - Gemini models: nothing to send. Caching is implicit above the model's
///   minimum (4,096 tokens on Gemini 3.x, 2,048 on 2.5), and the explicit
///   cache needs the same minimum plus storage fees, which a short agent
///   prefix cannot earn back.
struct AgentCachePolicy: Equatable, Sendable {
    var family: ModelFamily
    var sendsPromptCacheKey: Bool
    var sendsAnthropicBreakpoints: Bool

    init(endpoint: AgentEndpoint) {
        family = ModelFamily.infer(modelID: endpoint.modelID, format: endpoint.format)
        sendsPromptCacheKey = family == .openAI && (endpoint.format == .openAIChat || endpoint.format == .openAIResponses)
        sendsAnthropicBreakpoints = family == .anthropic
    }

    static let staticTTL: [String: Any] = ["type": "ephemeral", "ttl": "1h"]
    static let movingTTL: [String: Any] = ["type": "ephemeral"]

    /// A 400 that names one of the cache fields. Other 400s (a bad image,
    /// a wrong model id) are the caller's problem and are not retried.
    static func rejectsCacheFields(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        let markers = ["prompt_cache", "cache_control", "ttl", "unrecognized", "unknown parameter", "unknown field",
                       "unexpected field", "extra fields", "additional propert", "not permitted", "unsupported parameter"]
        return markers.contains { message.contains($0) }
    }
}
