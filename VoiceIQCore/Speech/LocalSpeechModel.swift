import Foundation

/// An on-device speech model the user can download and select. The raw value
/// is the stored `localSpeechModel` setting.
public enum LocalSpeechModel: String, CaseIterable, Codable, Sendable {
    case parakeet
    case nemotron

    public var displayName: String {
        switch self {
        case .parakeet: return "Parakeet v3"
        case .nemotron: return "Nemotron 3.5"
        }
    }

    /// Recorded with each transcript and in usage tracking.
    public var modelID: String {
        switch self {
        case .parakeet: return "parakeet-v3-local"
        case .nemotron: return "nemotron-3.5-multilingual-local"
        }
    }
}
