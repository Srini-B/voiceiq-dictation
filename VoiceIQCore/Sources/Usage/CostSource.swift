import Foundation

/// Whose bill a usage record lands on, for the Cost pane: either provider,
/// ElevenLabs or MAI Transcribe 2 when it transcribes, and Sarvam when it
/// transcribes or writes. Records store only the model ID, so the source is
/// read off its prefix.
public enum CostSource: String, CaseIterable, Sendable, Identifiable {
    case gemini
    case openAI
    case elevenLabs
    case mai
    case sarvam

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
        case .mai: return "MAI"
        case .sarvam: return "Sarvam"
        }
    }

    /// For SQL `LIKE` filters on the stored model ID.
    public var modelPrefixes: [String] {
        switch self {
        case .gemini: return ModelProvider.gemini.modelPrefixes
        case .openAI: return ModelProvider.openAI.modelPrefixes
        case .elevenLabs: return ["scribe", "elevenlabs/"]
        case .mai: return ["microsoft/", "mai-"]
        case .sarvam: return ["saaras", "sarvam"]
        }
    }

    /// Where this source's prices come from. For the selected provider that
    /// is the active gateway's reporting; for the other, its own price page.
    public func pricingNote(activeRoute: ModelRoute) -> String {
        switch self {
        case .gemini, .openAI:
            let provider: ModelProvider = self == .gemini ? .gemini : .openAI
            return ModelRoute(provider: provider, gateway: provider == activeRoute.provider ? activeRoute.gateway : .direct).pricingNote
        case .elevenLabs:
            return "List prices from the ElevenLabs API pricing page: Scribe v2 $0.22 an hour, plus $0.05 an hour when dictionary terms are sent. Hours included in your plan are not subtracted."
        case .mai:
            return "Costs reported by OpenRouter or Vercel AI Gateway for each call."
        case .sarvam:
            return "List prices from the Sarvam pricing page, in rupees: Saaras V4 ₹30 an hour, ₹45 with speaker labels; Sarvam 105B ₹29.28 in and ₹73.20 out per million tokens. Converted to dollars at the ECB rate of the day of the call (Frankfurter)."
        }
    }
}
