import Foundation

/// A language the user speaks, by its ISO 639-3 code: the main language and
/// the others in `SettingsStore.spokenLanguages`. The dictation call gets
/// them as a hint (`promptLine`). Meetings get none: gemini-3.5-transcribe
/// detects each language and every switch itself.
public struct SpokenLanguage: Hashable, Identifiable, Sendable {
    public let code: String
    public let name: String
    public var id: String { code }

    /// The languages Settings offers, by English name (the list ElevenLabs'
    /// speech to text page gave on 2026-11-12, kept so saved choices still
    /// read).
    public static let all: [SpokenLanguage] = [
        SpokenLanguage(code: "afr", name: "Afrikaans"),
        SpokenLanguage(code: "amh", name: "Amharic"),
        SpokenLanguage(code: "ara", name: "Arabic"),
        SpokenLanguage(code: "hye", name: "Armenian"),
        SpokenLanguage(code: "asm", name: "Assamese"),
        SpokenLanguage(code: "ast", name: "Asturian"),
        SpokenLanguage(code: "aze", name: "Azerbaijani"),
        SpokenLanguage(code: "bel", name: "Belarusian"),
        SpokenLanguage(code: "ben", name: "Bengali"),
        SpokenLanguage(code: "bos", name: "Bosnian"),
        SpokenLanguage(code: "bul", name: "Bulgarian"),
        SpokenLanguage(code: "mya", name: "Burmese"),
        SpokenLanguage(code: "yue", name: "Cantonese"),
        SpokenLanguage(code: "cat", name: "Catalan"),
        SpokenLanguage(code: "ceb", name: "Cebuano"),
        SpokenLanguage(code: "nya", name: "Chichewa"),
        SpokenLanguage(code: "hrv", name: "Croatian"),
        SpokenLanguage(code: "ces", name: "Czech"),
        SpokenLanguage(code: "dan", name: "Danish"),
        SpokenLanguage(code: "nld", name: "Dutch"),
        SpokenLanguage(code: "eng", name: "English"),
        SpokenLanguage(code: "est", name: "Estonian"),
        SpokenLanguage(code: "fil", name: "Filipino"),
        SpokenLanguage(code: "fin", name: "Finnish"),
        SpokenLanguage(code: "fra", name: "French"),
        SpokenLanguage(code: "ful", name: "Fulah"),
        SpokenLanguage(code: "glg", name: "Galician"),
        SpokenLanguage(code: "lug", name: "Ganda"),
        SpokenLanguage(code: "kat", name: "Georgian"),
        SpokenLanguage(code: "deu", name: "German"),
        SpokenLanguage(code: "ell", name: "Greek"),
        SpokenLanguage(code: "guj", name: "Gujarati"),
        SpokenLanguage(code: "hau", name: "Hausa"),
        SpokenLanguage(code: "heb", name: "Hebrew"),
        SpokenLanguage(code: "hin", name: "Hindi"),
        SpokenLanguage(code: "hun", name: "Hungarian"),
        SpokenLanguage(code: "isl", name: "Icelandic"),
        SpokenLanguage(code: "ibo", name: "Igbo"),
        SpokenLanguage(code: "ind", name: "Indonesian"),
        SpokenLanguage(code: "gle", name: "Irish"),
        SpokenLanguage(code: "ita", name: "Italian"),
        SpokenLanguage(code: "jpn", name: "Japanese"),
        SpokenLanguage(code: "jav", name: "Javanese"),
        SpokenLanguage(code: "kea", name: "Kabuverdianu"),
        SpokenLanguage(code: "kan", name: "Kannada"),
        SpokenLanguage(code: "kaz", name: "Kazakh"),
        SpokenLanguage(code: "khm", name: "Khmer"),
        SpokenLanguage(code: "kor", name: "Korean"),
        SpokenLanguage(code: "kur", name: "Kurdish"),
        SpokenLanguage(code: "kir", name: "Kyrgyz"),
        SpokenLanguage(code: "lao", name: "Lao"),
        SpokenLanguage(code: "lav", name: "Latvian"),
        SpokenLanguage(code: "lin", name: "Lingala"),
        SpokenLanguage(code: "lit", name: "Lithuanian"),
        SpokenLanguage(code: "luo", name: "Luo"),
        SpokenLanguage(code: "ltz", name: "Luxembourgish"),
        SpokenLanguage(code: "mkd", name: "Macedonian"),
        SpokenLanguage(code: "msa", name: "Malay"),
        SpokenLanguage(code: "mal", name: "Malayalam"),
        SpokenLanguage(code: "mlt", name: "Maltese"),
        SpokenLanguage(code: "zho", name: "Mandarin Chinese"),
        SpokenLanguage(code: "mri", name: "Māori"),
        SpokenLanguage(code: "mar", name: "Marathi"),
        SpokenLanguage(code: "mon", name: "Mongolian"),
        SpokenLanguage(code: "nep", name: "Nepali"),
        SpokenLanguage(code: "nso", name: "Northern Sotho"),
        SpokenLanguage(code: "nor", name: "Norwegian"),
        SpokenLanguage(code: "oci", name: "Occitan"),
        SpokenLanguage(code: "ori", name: "Odia"),
        SpokenLanguage(code: "pus", name: "Pashto"),
        SpokenLanguage(code: "fas", name: "Persian"),
        SpokenLanguage(code: "pol", name: "Polish"),
        SpokenLanguage(code: "por", name: "Portuguese"),
        SpokenLanguage(code: "pan", name: "Punjabi"),
        SpokenLanguage(code: "ron", name: "Romanian"),
        SpokenLanguage(code: "rus", name: "Russian"),
        SpokenLanguage(code: "srp", name: "Serbian"),
        SpokenLanguage(code: "sna", name: "Shona"),
        SpokenLanguage(code: "snd", name: "Sindhi"),
        SpokenLanguage(code: "sin", name: "Sinhala"),
        SpokenLanguage(code: "slk", name: "Slovak"),
        SpokenLanguage(code: "slv", name: "Slovenian"),
        SpokenLanguage(code: "som", name: "Somali"),
        SpokenLanguage(code: "spa", name: "Spanish"),
        SpokenLanguage(code: "swa", name: "Swahili"),
        SpokenLanguage(code: "swe", name: "Swedish"),
        SpokenLanguage(code: "tgk", name: "Tajik"),
        SpokenLanguage(code: "tam", name: "Tamil"),
        SpokenLanguage(code: "tel", name: "Telugu"),
        SpokenLanguage(code: "tha", name: "Thai"),
        SpokenLanguage(code: "tur", name: "Turkish"),
        SpokenLanguage(code: "ukr", name: "Ukrainian"),
        SpokenLanguage(code: "umb", name: "Umbundu"),
        SpokenLanguage(code: "urd", name: "Urdu"),
        SpokenLanguage(code: "uzb", name: "Uzbek"),
        SpokenLanguage(code: "vie", name: "Vietnamese"),
        SpokenLanguage(code: "cym", name: "Welsh"),
        SpokenLanguage(code: "wol", name: "Wolof"),
        SpokenLanguage(code: "xho", name: "Xhosa"),
        SpokenLanguage(code: "yor", name: "Yoruba"),
        SpokenLanguage(code: "zul", name: "Zulu"),
    ]

    public static func isListed(_ code: String) -> Bool { all.contains { $0.code == code } }

    /// `codes` with `main` as the main language ("" for automatic
    /// detection, which also clears the others).
    public static func choosing(main: String, in codes: [String]) -> [String] {
        main.isEmpty ? [] : [main] + codes.dropFirst().filter { $0 != main }
    }

    /// `codes` with `code` added to or removed from the other languages.
    public static func toggling(_ code: String, in codes: [String]) -> [String] {
        guard let main = codes.first, code != main else { return codes }
        let others = codes.dropFirst()
        return [main] + (others.contains(code) ? others.filter { $0 != code } : others + [code])
    }

    /// `codes` with `code`, one of them, as the main language and the old
    /// main language moved to the others: the menu bar's quick switch.
    public static func promoting(_ code: String, in codes: [String]) -> [String] {
        codes.contains(code) ? [code] + codes.filter { $0 != code } : codes
    }

    /// "Hindi, Tamil", or `none` when there are no other languages.
    public static func names(_ codes: some Collection<String>, none: String) -> String {
        codes.isEmpty ? none : codes.map { code in all.first { $0.code == code }?.name ?? code }.joined(separator: ", ")
    }

    /// What the dictation call is told about the speaker's languages, or nil
    /// for automatic detection. A hint only: Gemini hears every language
    /// and each switch, and the writing rules already keep each language in
    /// its own script.
    public static func promptLine(_ codes: [String]) -> String? {
        guard let main = codes.first else { return nil }
        let mainName = names([main], none: main)
        guard codes.count > 1 else { return "LANGUAGES: The speaker usually speaks \(mainName)." }
        return "LANGUAGES: The speaker usually speaks \(mainName) and may also speak \(names(codes.dropFirst(), none: "")), sometimes switching language mid-sentence. Write every language as it is spoken; never translate."
    }
}
