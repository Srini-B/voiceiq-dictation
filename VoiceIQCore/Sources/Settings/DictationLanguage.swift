import Foundation

/// The language dictation is transcribed in. STT-3.7 covers 32 languages and
/// streams while the user speaks; the rest go to Universal-2 after key-up,
/// which takes a few seconds longer.
public struct DictationLanguage: Hashable, Sendable, Identifiable {
    /// ISO code sent to AssemblyAI; nil lets STT-3.7 detect and code-switch
    /// among its 32 languages.
    public let code: String?
    public let name: String
    /// STT-3.7 Realtime covers it; false means Universal-2.
    public let streams: Bool
    /// Spoken mixed with English: a second Universal-2 pass in English gives
    /// the writer the English words in Latin letters (Universal-2 Tamil
    /// respells them in Tamil script).
    public var latinCompanion = false

    public var id: String { code ?? "auto" }

    public static let english = DictationLanguage(code: "en", name: "English", streams: true)

    /// STT-3.7's languages first (assemblyai.com/llms/models.md, 2026-11-17),
    /// then the Universal-2 languages most asked for in India.
    public static let all: [DictationLanguage] = [english, DictationLanguage(code: nil, name: "Detect (STT-3.7 languages)", streams: true)]
        + [("hi", "Hindi"), ("mr", "Marathi"), ("ur", "Urdu"), ("ar", "Arabic"), ("zh", "Mandarin"), ("ja", "Japanese"),
           ("ko", "Korean"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
           ("nl", "Dutch"), ("ru", "Russian"), ("tr", "Turkish"), ("vi", "Vietnamese"), ("fa", "Persian"), ("he", "Hebrew")]
            .map { DictationLanguage(code: $0.0, name: $0.1, streams: true) }
        + [DictationLanguage(code: "ta", name: "Tamil-English (Universal-2, slower)", streams: false, latinCompanion: true)]
        + [("te", "Telugu"), ("kn", "Kannada"), ("ml", "Malayalam"), ("bn", "Bengali"),
           ("gu", "Gujarati"), ("pa", "Punjabi")]
            .map { DictationLanguage(code: $0.0, name: "\($0.1) (Universal-2, slower)", streams: false) }
}

public extension SettingsStore {
    var dictationLanguage: DictationLanguage {
        let stored = Self.defaults.string(forKey: "dictationLanguage") ?? DictationLanguage.english.id
        return DictationLanguage.all.first { $0.id == stored } ?? .english
    }

    func setDictationLanguage(_ language: DictationLanguage) {
        Self.set(language.id, forKey: "dictationLanguage")
    }
}
