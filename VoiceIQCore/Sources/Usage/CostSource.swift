import Foundation

/// Whose bill a usage record lands on, for the Cost pane: Gemini or OpenAI.
/// Records store only the model ID, so the source is read off its prefix.
public enum CostSource: String, CaseIterable, Sendable, Identifiable {
    case gemini
    case openAI

    public init(_ provider: ModelProvider) {
        switch provider {
        case .gemini: self = .gemini
        case .openAI: self = .openAI
        }
    }

    public var id: String { rawValue }

    var provider: ModelProvider {
        switch self {
        case .gemini: return .gemini
        case .openAI: return .openAI
        }
    }

    public var displayName: String { provider.displayName }

    /// For SQL `LIKE` filters on the stored model ID.
    public var modelPrefixes: [String] { provider.modelPrefixes }

    /// Where this source's prices come from.
    public var pricingNote: String { provider.pricingNote }
}
