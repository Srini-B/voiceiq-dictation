import Foundation

/// Whose bill a usage record lands on, for the Cost pane: Gemini, OpenAI, or
/// Claude. Claude is no longer a provider (removed 2026-11-10); its source
/// stays so rows booked under it (on Anthropic, and on DeepInfra while Claude
/// transcribed with Nemotron there) still show and price.
/// Records store only the model ID, so the source is read off its prefix.
public enum CostSource: String, CaseIterable, Sendable, Identifiable {
    case gemini
    case openAI
    case anthropic

    public init(_ provider: ModelProvider) {
        switch provider {
        case .gemini: self = .gemini
        case .openAI: self = .openAI
        }
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .openAI: return "OpenAI"
        case .anthropic: return "Claude"
        }
    }

    /// Whether the source belongs to a provider the app still offers. A
    /// retired source is offered on the Cost pane only while it has rows.
    public var isCurrent: Bool { self != .anthropic }

    /// For SQL `LIKE` filters on the stored model ID. The `google/` and
    /// `openai/` prefixes match rows booked before the gateways were removed,
    /// and `nvidia/` rows booked while Claude transcribed with Nemotron on
    /// DeepInfra.
    public var modelPrefixes: [String] {
        switch self {
        case .gemini: return ["gemini", "google/"]
        case .openAI: return ["gpt", "whisper", "openai/"]
        case .anthropic: return ["claude", "nvidia/", "anthropic/"]
        }
    }

    /// Where this source's prices come from.
    public var pricingNote: String {
        switch self {
        case .gemini: return "Paid-tier Standard prices from the Gemini API pricing page. A free-tier key is billed nothing."
        case .openAI: return "Standard prices from the OpenAI API pricing page."
        case .anthropic: return "Standard prices from Anthropic's pricing page."
        }
    }
}
