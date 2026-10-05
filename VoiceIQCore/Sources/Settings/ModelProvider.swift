import Foundation

/// Whose models run: Gemini's or OpenAI's, each on its own API with its own
/// key. Settings calls this the provider.
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

    /// The other provider, for meetings when this one has no key.
    public var other: ModelProvider { self == .gemini ? .openAI : .gemini }

    /// Whether the writing model can take the recording as input. The Gemini
    /// flash model hears audio, which is what the one-call dictation and the
    /// audio-checked cleanup rely on. GPT-6 Luna takes text and images only
    /// (and rejects FLAC even as `input_audio`, probed 2026-09-28).
    public var writingModelHearsAudio: Bool { self == .gemini }

    /// Usage records store only the model ID; the provider is read off it.
    /// The `google/` and `openai/` prefixes match rows booked before the
    /// gateways were removed.
    public init?(modelID: String) {
        let id = modelID.lowercased()
        if Self.gemini.modelPrefixes.contains(where: id.hasPrefix) { self = .gemini }
        else if Self.openAI.modelPrefixes.contains(where: id.hasPrefix) { self = .openAI }
        else { return nil }
    }

    /// Model ID prefixes, for `init(modelID:)` and SQL `LIKE` filters.
    public var modelPrefixes: [String] {
        switch self {
        case .gemini: return ["gemini", "google/"]
        case .openAI: return ["gpt", "whisper", "openai/"]
        }
    }

    /// Where the pricing on the Cost pane comes from.
    public var pricingNote: String {
        switch self {
        case .gemini: return "Paid-tier Standard prices from the Gemini API pricing page. A free-tier key is billed nothing."
        case .openAI: return "Standard prices from the OpenAI API pricing page."
        }
    }

    /// Providers a meeting is transcribed on, in order: the selected one,
    /// then the other, each only while its key is stored. Empty when neither
    /// has a key.
    public static func meetingOrder(selected: ModelProvider, hasKey: (ModelProvider) -> Bool) -> [ModelProvider] {
        [selected, selected.other].filter(hasKey)
    }
}
