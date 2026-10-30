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
        learningResetAt = try? c.decode(Date.self, forKey: .learningResetAt)
    }
}
