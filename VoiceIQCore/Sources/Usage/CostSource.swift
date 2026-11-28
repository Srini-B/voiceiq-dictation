import Foundation

/// Whose bill a usage record lands on, for the Cost pane. AssemblyAI is the
/// only provider since 0.7.19. Gemini (removed in 0.7.19), OpenAI and
/// ElevenLabs (removed in 0.7.12) and Claude (removed 2026-11-10) stay so rows
/// booked under them still show and price. Records store only the model ID,
/// so the source is read off its prefix; AssemblyAI rows carry "assemblyai/".
public enum CostSource: String, CaseIterable, Sendable, Identifiable {
    case assemblyAI
    case gemini
    case openAI
    case elevenLabs
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .assemblyAI: return "AssemblyAI"
        case .gemini: return "Gemini"
        case .openAI: return "OpenAI"
        case .elevenLabs: return "ElevenLabs"
        case .anthropic: return "Claude"
        }
    }

    /// Whether the Cost pane always offers the source. A retired one is
    /// offered only while it has rows.
    public var isCurrent: Bool { self == .assemblyAI }

    /// For SQL `LIKE` filters on the stored model ID. The `google/` and
    /// `openai/` prefixes match rows booked before the gateways were removed,
    /// and `nvidia/` rows booked while Claude transcribed with Nemotron on
    /// DeepInfra.
    public var modelPrefixes: [String] {
        switch self {
        case .assemblyAI: return ["assemblyai/"]
        case .gemini: return ["gemini", "google/"]
        case .openAI: return ["gpt", "whisper", "openai/"]
        case .elevenLabs: return ["scribe"]
        case .anthropic: return ["claude", "nvidia/", "anthropic/"]
        }
    }

    /// Where this source's prices come from.
    public var pricingNote: String {
        switch self {
        case .assemblyAI:
            return "List prices from AssemblyAI's pricing page: streaming $0.30 an hour of open session, STT-3.7 $0.21 an hour plus its add-ons, and the LLM Gateway per token. Free credit is not subtracted."
        case .gemini: return "Paid-tier Standard prices from the Gemini API pricing page. A free-tier key is billed nothing."
        case .openAI: return "Standard prices from the OpenAI API pricing page."
        case .elevenLabs:
            return "List prices from the ElevenLabs API pricing page: Scribe v3 $0.20 an hour, plus its add-ons; Scribe v3 Live $0.22 an hour. Hours included in your plan are not subtracted."
        case .anthropic: return "Standard prices from Anthropic's pricing page."
        }
    }
}
