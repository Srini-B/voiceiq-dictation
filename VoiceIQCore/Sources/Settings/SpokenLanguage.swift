import Foundation

/// A language the user speaks, by its ISO 639-3 code: the main language and
/// the others in `SettingsStore.spokenLanguages`, used by every provider for
/// dictation and meetings. Each provider takes them its own way:
/// ElevenLabs as `language_code` plus secondary codes, OpenAI as
/// `languages[]` plus `transcriptionPrompt`. Gemini's transcribe models get
/// none: they detect the language and its switches themselves, and
/// `language_codes` silently turns smart mode off (see
/// `GeminiClient.transcriptionConfig`).
public struct SpokenLanguage: Hashable, Identifiable, Sendable {
    public let code: String
    public let name: String
    public var id: String { code }

    /// Every language on the ElevenLabs speech to text page (read
    /// 2026-11-12), by English name. Settings offers only these; OpenAI and
    /// Gemini list fewer, see `openAICodes`.
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
    /// detection, which also clears the others: Scribe v3 refuses other
    /// languages without a main one).
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

    /// OpenAI's `languages[]` (ISO 639-1) for `codes`, or none when one of
    /// them has no two-letter code (Cantonese, Cebuano and the like): the
    /// list limits what the model listens for, so a partial one would shut
    /// out that language. `Locale` hands back the three-letter code when
    /// there is no two-letter one, hence the length check. OpenAI refuses a
    /// request with a code it does not know, and
    /// `GeminiClient.openAITranscribe` then retries without it.
    public static func openAICodes(_ codes: [String]) -> [String] {
        let short = codes.compactMap { Locale.LanguageCode($0).identifier(.alpha2) }.filter { $0.count == 2 }
        return short.count == codes.count ? short : []
    }

    /// What OpenAI's transcription models are told about the speaker
    /// (`prompt`) when they speak more than one language; nil otherwise,
    /// where `openAICodes` says it all. It describes the recording, as
    /// OpenAI's guide asks, and carries only what a transcriber can act on
    /// from the writing rules: which languages to expect and that they
    /// switch mid-sentence. Vocabulary goes in `keywords[]`; rewording,
    /// layout, tone and number style stay with the writing model. Each
    /// language is also named in itself ("Japanese (日本語)"), since OpenAI
    /// asks for a prompt in the audio's language. MEASURED 2026-11-13 with
    /// gpt-transcribe: adding the writing rules' script line ("Each language
    /// is written in its own script, never translated or romanized.") made
    /// a short accented Japanese dictation come back part Devanagari ("Now
    /// मिस on.") in 4 of 6 runs; this prompt, like `languages[]` alone, in
    /// none (with neither, in Devanagari in 3 of 4 runs). Clear
    /// Japanese, Tamil and English-Tamil code-switched clips came back in
    /// their own scripts either way.
    public static func transcriptionPrompt(_ codes: [String]) -> String? {
        guard codes.count > 1 else { return nil }
        let names = codes.map { code -> String in
            let name = all.first { $0.code == code }?.name ?? code
            guard let native = Locale(identifier: code).localizedString(forLanguageCode: code),
                  native.lowercased() != name.lowercased() else { return name }
            return "\(name) (\(native))"
        }
        let list = names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "Dictation in \(list), sometimes switching language mid-sentence."
    }
}
