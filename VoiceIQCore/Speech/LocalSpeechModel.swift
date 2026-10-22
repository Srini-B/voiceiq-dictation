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

    /// The languages dictation with this model transcribes, offered in
    /// Settings under the selected model. Fluid Speech Mini is trained on
    /// English only. Nemotron gets the 32 locales NVIDIA's model card rates
    /// transcription-ready or broad-coverage; the card's eight
    /// adaptation-ready locales need fine-tuning first and are left out.
    public var languages: [LocalSpeechLanguage] {
        switch self {
        case .parakeet: return [LocalSpeechLanguage(code: "en-US", name: "English")]
        case .nemotron: return LocalSpeechLanguage.nemotron
        }
    }

    /// The stored choice when this model has it, else English.
    public func language(code: String?) -> LocalSpeechLanguage {
        languages.first { $0.code == code } ?? languages.first { $0.code == "en-US" } ?? languages[0]
    }

    /// Recorded with each transcript and in usage tracking.
    public var modelID: String {
        switch self {
        case .parakeet: return "fluid-speech-mini-local"
        case .nemotron: return "nemotron-3.5-multilingual-local"
        }
    }
}

/// A language an on-device model transcribes. `code` is the locale the
/// decoder is prompted with.
public struct LocalSpeechLanguage: Hashable, Sendable {
    public let code: String
    public let name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    /// The English tools (speech detection, number formatting) apply only here.
    public var isEnglish: Bool { code.hasPrefix("en") }

    /// Codes from the model's `prompt_dictionary`, names written out because
    /// `ar-AR` reads as Argentina to `Locale`.
    static let nemotron: [LocalSpeechLanguage] = [
        ("ar-AR", "Arabic"), ("bg-BG", "Bulgarian"), ("zh-CN", "Chinese (Mandarin)"),
        ("hr-HR", "Croatian"), ("cs-CZ", "Czech"), ("da-DK", "Danish"), ("nl-NL", "Dutch"),
        ("en-GB", "English (UK)"), ("en-US", "English (US)"), ("et-EE", "Estonian"),
        ("fi-FI", "Finnish"), ("fr-CA", "French (Canada)"), ("fr-FR", "French (France)"),
        ("de-DE", "German"), ("hi-IN", "Hindi"), ("hu-HU", "Hungarian"), ("it-IT", "Italian"),
        ("ja-JP", "Japanese"), ("ko-KR", "Korean"), ("nb-NO", "Norwegian Bokmål"),
        ("pl-PL", "Polish"), ("pt-BR", "Portuguese (Brazil)"), ("pt-PT", "Portuguese (Portugal)"),
        ("ro-RO", "Romanian"), ("ru-RU", "Russian"), ("sk-SK", "Slovak"),
        ("es-ES", "Spanish (Spain)"), ("es-US", "Spanish (US)"), ("sv-SE", "Swedish"),
        ("tr-TR", "Turkish"), ("uk-UA", "Ukrainian"), ("vi-VN", "Vietnamese"),
    ].map { LocalSpeechLanguage(code: $0.0, name: $0.1) }
}
