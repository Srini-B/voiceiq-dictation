import Foundation

/// An on-device speech model the user can download and select. The raw value
/// is the stored `localSpeechModel` setting, so `parakeet` keeps its name for
/// Fluid Speech Mini, the Parakeet v3 fine-tune that replaced it.
public enum LocalSpeechModel: String, CaseIterable, Codable, Sendable {
    case parakeet
    case fluidSpeechPro

    /// The models offered on this platform. iPhone and iPad get Fluid Speech
    /// Mini only; Fluid Speech Pro is a 16-bit build too large for them.
    public static var available: [LocalSpeechModel] {
        #if os(macOS)
        return allCases
        #else
        return [.parakeet]
        #endif
    }

    /// A stored choice of the retired on-device Nemotron reads as Fluid
    /// Speech Pro, which replaced it.
    public init?(stored: String) {
        self.init(rawValue: stored == "nemotron" ? Self.fluidSpeechPro.rawValue : stored)
    }

    public var displayName: String {
        switch self {
        case .parakeet: return "Fluid Speech Mini"
        case .fluidSpeechPro: return "Fluid Speech Pro"
        }
    }

    /// The languages dictation with this model transcribes, offered in
    /// Settings under the selected model. Fluid Speech Mini is trained on
    /// English only; Fluid Speech Pro keeps Parakeet v3's 25 European languages.
    public var languages: [LocalSpeechLanguage] {
        switch self {
        case .parakeet: return [LocalSpeechLanguage(code: "en-US", name: "English")]
        case .fluidSpeechPro: return LocalSpeechLanguage.parakeetV3
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
        case .fluidSpeechPro: return "fluid-speech-pro-local"
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

    /// The English tools (dictionary correction, number formatting) apply only here.
    public var isEnglish: Bool { code.hasPrefix("en") }

    /// Parakeet TDT 0.6B v3's languages. The decoder detects the language
    /// itself; the choice decides whether the English tools and number
    /// formatting run.
    static let parakeetV3: [LocalSpeechLanguage] = [
        ("bg-BG", "Bulgarian"), ("hr-HR", "Croatian"), ("cs-CZ", "Czech"), ("da-DK", "Danish"),
        ("nl-NL", "Dutch"), ("en-US", "English"), ("et-EE", "Estonian"), ("fi-FI", "Finnish"),
        ("fr-FR", "French"), ("de-DE", "German"), ("el-GR", "Greek"), ("hu-HU", "Hungarian"),
        ("it-IT", "Italian"), ("lv-LV", "Latvian"), ("lt-LT", "Lithuanian"), ("mt-MT", "Maltese"),
        ("pl-PL", "Polish"), ("pt-PT", "Portuguese"), ("ro-RO", "Romanian"), ("ru-RU", "Russian"),
        ("sk-SK", "Slovak"), ("sl-SI", "Slovenian"), ("es-ES", "Spanish"), ("sv-SE", "Swedish"),
        ("uk-UA", "Ukrainian"),
    ].map { LocalSpeechLanguage(code: $0.0, name: $0.1) }
}
