import Foundation

/// The letter arrangement of the typing keyboard. English only.
public enum KeyboardLetterLayout: String, Codable, CaseIterable, Sendable {
    case qwerty, qwertz, azerty, dvorak, colemak

    public var title: String {
        switch self {
        case .qwerty: return "QWERTY"
        case .qwertz: return "QWERTZ"
        case .azerty: return "AZERTY"
        case .dvorak: return "Dvorak"
        case .colemak: return "Colemak"
        }
    }
}

/// How the typing keys look. The names follow the Raycast keyboard's themes.
public enum KeyboardTheme: String, Codable, CaseIterable, Sendable {
    case standard, clear, physical, mechanical, classic

    public var title: String {
        switch self {
        case .standard: return "Default"
        case .clear: return "Clear"
        case .physical: return "Physical"
        case .mechanical: return "Mechanical"
        case .classic: return "iOS 5"
        }
    }

    /// Physical and Mechanical can be forced light or dark.
    public var hasKeyTone: Bool { self == .physical || self == .mechanical }
}

public enum KeyboardKeyTone: String, Codable, CaseIterable, Sendable {
    case automatic, light, dark

    public var title: String { rawValue.capitalized }
}

/// Typing settings the app writes and the keyboard reads.
public struct KeyboardPreferences: Codable, Equatable, Sendable {
    public var layout: KeyboardLetterLayout = .qwerty
    public var autocorrect = true
    public var autocapitalize = true
    public var predictions = true
    public var slideToType = true
    /// Two spaces type a period and a space.
    public var periodShortcut = true
    public var keySound = true
    public var haptics = false
    public var theme: KeyboardTheme = .standard
    public var keyTone: KeyboardKeyTone = .automatic
    /// When the user last asked to forget learned words. The keyboard keeps
    /// its own learned words and clears them when this is newer.
    public var learningResetAt: Date?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeyboardPreferences()
        layout = (try? c.decode(KeyboardLetterLayout.self, forKey: .layout)) ?? d.layout
        autocorrect = (try? c.decode(Bool.self, forKey: .autocorrect)) ?? d.autocorrect
        autocapitalize = (try? c.decode(Bool.self, forKey: .autocapitalize)) ?? d.autocapitalize
        predictions = (try? c.decode(Bool.self, forKey: .predictions)) ?? d.predictions
        slideToType = (try? c.decode(Bool.self, forKey: .slideToType)) ?? d.slideToType
        periodShortcut = (try? c.decode(Bool.self, forKey: .periodShortcut)) ?? d.periodShortcut
        keySound = (try? c.decode(Bool.self, forKey: .keySound)) ?? d.keySound
        haptics = (try? c.decode(Bool.self, forKey: .haptics)) ?? d.haptics
        theme = (try? c.decode(KeyboardTheme.self, forKey: .theme)) ?? d.theme
        keyTone = (try? c.decode(KeyboardKeyTone.self, forKey: .keyTone)) ?? d.keyTone
        learningResetAt = try? c.decode(Date.self, forKey: .learningResetAt)
    }
}
