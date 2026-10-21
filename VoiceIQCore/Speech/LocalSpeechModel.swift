import Foundation

/// An on-device speech model the user can download and select. The raw value
/// is the stored `localSpeechModel` setting, so `parakeet` keeps its name for
/// Fluid Speech Mini, the Parakeet v3 fine-tune that replaced it.
public enum LocalSpeechModel: String, CaseIterable, Codable, Sendable {
    case parakeet
    case nemotron

    /// The models offered on this platform. iPhone and iPad get Fluid Speech
    /// Mini only: Nemotron stalled on a physical iPhone, and the app has no
    /// live-text surface there that would justify its streaming decoder.
    public static var available: [LocalSpeechModel] {
        #if os(macOS)
        return allCases
        #else
        return [.parakeet]
        #endif
    }

    public var displayName: String {
        switch self {
        case .parakeet: return "Fluid Speech Mini"
        case .nemotron: return "Nemotron 3.5"
        }
    }

    /// The languages dictation with this model transcribes, shown under it in
    /// Settings. Fluid Speech Mini is trained on English only. Nemotron knows
    /// more, but `NemotronSession` locks it to `en-US` so the English tools and
    /// number formatting apply, so its other languages are not offered.
    public var languages: [String] { ["English"] }

    /// Recorded with each transcript and in usage tracking.
    public var modelID: String {
        switch self {
        case .parakeet: return "fluid-speech-mini-local"
        case .nemotron: return "nemotron-3.5-multilingual-local"
        }
    }
}
