import Foundation

/// An on-device speech model the user can download and select. The raw value
/// is the stored `localSpeechModel` setting, so `parakeet` keeps its name for
/// Fluid Speech Mini, the Parakeet v3 fine-tune that replaced it.
public enum LocalSpeechModel: String, CaseIterable, Codable, Sendable {
    case parakeet
    case nemotron

    public var displayName: String {
        switch self {
        case .parakeet: return "Fluid Speech Mini"
        case .nemotron: return "Nemotron 3.5"
        }
    }

    /// Recorded with each transcript and in usage tracking.
    public var modelID: String {
        switch self {
        case .parakeet: return "fluid-speech-mini-local"
        case .nemotron: return "nemotron-3.5-multilingual-local"
        }
    }
}
