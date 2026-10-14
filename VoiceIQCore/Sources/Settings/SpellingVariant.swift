import Foundation

/// The regional spelling and conventions the writing model uses. The
/// recognizer cannot hear the difference between "colour" and "color", so
/// the choice is a setting. `automatic` leaves it to the model, which then
/// follows the words on screen and the speaker's own usage.
public enum SpellingVariant: String, CaseIterable, Sendable {
    case automatic = ""
    case englishUS = "en-US"
    case englishUK = "en-GB"
    case englishAU = "en-AU"
    case englishCA = "en-CA"
    case englishIN = "en-IN"
    case spanishSpain = "es-ES"
    case spanishLatinAmerica = "es-419"
    case frenchFrance = "fr-FR"
    case frenchCanada = "fr-CA"
    case portugueseBrazil = "pt-BR"
    case portuguesePortugal = "pt-PT"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"

    public var name: String {
        switch self {
        case .automatic: return "Automatic"
        case .englishUS: return "English (US)"
        case .englishUK: return "English (UK)"
        case .englishAU: return "English (Australia)"
        case .englishCA: return "English (Canada)"
        case .englishIN: return "English (India)"
        case .spanishSpain: return "Spanish (Spain)"
        case .spanishLatinAmerica: return "Spanish (Latin America)"
        case .frenchFrance: return "French (France)"
        case .frenchCanada: return "French (Canada)"
        case .portugueseBrazil: return "Portuguese (Brazil)"
        case .portuguesePortugal: return "Portuguese (Portugal)"
        case .chineseSimplified: return "Chinese (Simplified)"
        case .chineseTraditional: return "Chinese (Traditional)"
        }
    }

    /// The prompt line, or nil for `automatic`. Only spelling and
    /// conventions change; the language the speaker used stays.
    public var promptLine: String? {
        guard self != .automatic else { return nil }
        return "Spelling: when the dictation is in \(language), use \(name) spelling, vocabulary, and conventions for dates and units. Never translate into another language."
    }

    private var language: String {
        switch self {
        case .automatic: return ""
        case .englishUS, .englishUK, .englishAU, .englishCA, .englishIN: return "English"
        case .spanishSpain, .spanishLatinAmerica: return "Spanish"
        case .frenchFrance, .frenchCanada: return "French"
        case .portugueseBrazil, .portuguesePortugal: return "Portuguese"
        case .chineseSimplified, .chineseTraditional: return "Chinese"
        }
    }
}
