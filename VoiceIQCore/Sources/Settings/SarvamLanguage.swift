import Foundation

/// The languages Sarvam Saaras V4 transcribes, as `language_code` values
/// (docs.sarvam.ai/api-reference-docs/speech-to-text/transcribe, read
/// 2026-10-03). `auto` sends `unknown`, which the API documents as
/// auto-detection and which answered Hindi and English clips correctly when
/// probed; the response then carries `language_probability`. Picking a
/// language skips detection.
public enum SarvamLanguage: String, CaseIterable, Sendable, Identifiable {
    case auto = "unknown"
    case english = "en-IN"
    case hindi = "hi-IN"
    case bengali = "bn-IN"
    case gujarati = "gu-IN"
    case kannada = "kn-IN"
    case malayalam = "ml-IN"
    case marathi = "mr-IN"
    case odia = "od-IN"
    case punjabi = "pa-IN"
    case tamil = "ta-IN"
    case telugu = "te-IN"
    case assamese = "as-IN"
    case bodo = "brx-IN"
    case dogri = "doi-IN"
    case kashmiri = "ks-IN"
    case konkani = "kok-IN"
    case maithili = "mai-IN"
    case manipuri = "mni-IN"
    case nepali = "ne-IN"
    case sanskrit = "sa-IN"
    case santali = "sat-IN"
    case sindhi = "sd-IN"
    case urdu = "ur-IN"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Detect automatically"
        case .english: return "English"
        case .hindi: return "Hindi"
        case .bengali: return "Bengali"
        case .gujarati: return "Gujarati"
        case .kannada: return "Kannada"
        case .malayalam: return "Malayalam"
        case .marathi: return "Marathi"
        case .odia: return "Odia"
        case .punjabi: return "Punjabi"
        case .tamil: return "Tamil"
        case .telugu: return "Telugu"
        case .assamese: return "Assamese"
        case .bodo: return "Bodo"
        case .dogri: return "Dogri"
        case .kashmiri: return "Kashmiri"
        case .konkani: return "Konkani"
        case .maithili: return "Maithili"
        case .manipuri: return "Manipuri"
        case .nepali: return "Nepali"
        case .sanskrit: return "Sanskrit"
        case .santali: return "Santali"
        case .sindhi: return "Sindhi"
        case .urdu: return "Urdu"
        }
    }

    /// `auto` first, then the languages by name.
    public static let menuOrder: [SarvamLanguage] =
        [.auto] + allCases.filter { $0 != .auto }.sorted { $0.displayName < $1.displayName }
}
