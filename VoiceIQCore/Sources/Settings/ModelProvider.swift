import Foundation

/// Whose models run: Gemini's or OpenAI's, each on its own API with its own
/// key. Settings calls this the provider. Both transcribe and write.
public enum ModelProvider: String, CaseIterable, Sendable, Codable, Identifiable {
    case gemini
    case openAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .openAI: return "OpenAI"
        }
    }

    /// The provider's own API, reached with its own key.
    public var directName: String {
        switch self {
        case .gemini: return "Google AI Studio"
        case .openAI: return "OpenAI API"
        }
    }

    /// Providers to try for a meeting, in order: the selected one, then the
    /// others, each only while `hasKey`. Empty when none has a key.
    public static func meetingOrder(selected: ModelProvider, hasKey: (ModelProvider) -> Bool) -> [ModelProvider] {
        ([selected] + allCases.filter { $0 != selected }).filter(hasKey)
    }
}

/// The host a request goes to, which decides its auth header, its usage
/// envelope and how its error bodies read. ElevenLabs transcribes only, so
/// it is never a `ModelProvider`: the provider's writing model still runs
/// after it. Raw values are the `TransportEvent.via` strings.
public enum ModelEndpoint: String, Sendable {
    case gemini
    case openAI
    case elevenLabs

    public init(_ provider: ModelProvider) {
        switch provider {
        case .gemini: self = .gemini
        case .openAI: self = .openAI
        }
    }

    public var directName: String {
        switch self {
        case .gemini: return ModelProvider.gemini.directName
        case .openAI: return ModelProvider.openAI.directName
        case .elevenLabs: return "ElevenLabs API"
        }
    }
}
