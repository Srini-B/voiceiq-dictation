import Foundation

/// Whose bill a usage record lands on, for the Cost pane: Gemini, OpenAI or
/// ElevenLabs. Records store only the model ID, so the source is read off
/// its prefix.
public enum CostSource: String, CaseIterable, Sendable, Identifiable {
    case gemini
    case openAI
    case elevenLabs

    public init(_ provider: ModelProvider) {
        switch provider {
        case .gemini: self = .gemini
        case .openAI: self = .openAI
        }
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: return ModelProvider.gemini.displayName
        case .openAI: return ModelProvider.openAI.displayName
        case .elevenLabs: return "ElevenLabs"
        }
    }

    /// For SQL `LIKE` filters on the stored model ID.
    public var modelPrefixes: [String] {
        switch self {
        case .gemini: return ModelProvider.gemini.modelPrefixes
        case .openAI: return ModelProvider.openAI.modelPrefixes
        case .elevenLabs: return ["scribe", "elevenlabs/"]
        }
    }

    /// Where this source's prices come from.
    public var pricingNote: String {
        switch self {
        case .gemini: return ModelProvider.gemini.pricingNote
        case .openAI: return ModelProvider.openAI.pricingNote
        case .elevenLabs:
            return "List prices from the ElevenLabs API pricing page: Scribe v2 $0.22 an hour, plus $0.05 an hour when dictionary terms are sent. Hours included in your plan are not subtracted."
        }
    }
}
