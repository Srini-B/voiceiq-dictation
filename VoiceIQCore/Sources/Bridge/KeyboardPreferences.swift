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

public enum KeyboardHeight: String, Codable, CaseIterable, Sendable {
    case short, standard, tall

    public var title: String {
        switch self {
        case .short: return "Short"
        case .standard: return "Default"
        case .tall: return "Tall"
        }
    }
}

/// What sliding along the space bar does.
public enum KeyboardSpaceSlide: String, Codable, CaseIterable, Sendable {
    case cursor, off

    public var title: String { self == .cursor ? "Move Cursor" : "Off" }
}

/// What sliding left from delete removes; sliding back puts it back.
public enum KeyboardDeleteSlide: String, Codable, CaseIterable, Sendable {
    case words, characters, off

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
    public var theme: KeyboardTheme = .standard
    public var numberRow = false
    public var height: KeyboardHeight = .standard
    public var keyTone: KeyboardKeyTone = .automatic
    public var spaceSlide: KeyboardSpaceSlide = .cursor
    public var deleteSlide: KeyboardDeleteSlide = .words
    /// An emoji for the word just typed ("pizza" → 🍕) in the bar.
    public var emojiSuggestions = true
    /// Never suggested, corrected to or slid to. Keys of `TypingEngine.key(of:)`.
    public var blockedWords: [String] = []
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
        theme = (try? c.decode(KeyboardTheme.self, forKey: .theme)) ?? d.theme
        numberRow = (try? c.decode(Bool.self, forKey: .numberRow)) ?? d.numberRow
        height = (try? c.decode(KeyboardHeight.self, forKey: .height)) ?? d.height
        keyTone = (try? c.decode(KeyboardKeyTone.self, forKey: .keyTone)) ?? d.keyTone
        spaceSlide = (try? c.decode(KeyboardSpaceSlide.self, forKey: .spaceSlide)) ?? d.spaceSlide
        deleteSlide = (try? c.decode(KeyboardDeleteSlide.self, forKey: .deleteSlide)) ?? d.deleteSlide
        emojiSuggestions = (try? c.decode(Bool.self, forKey: .emojiSuggestions)) ?? d.emojiSuggestions
        blockedWords = (try? c.decode([String].self, forKey: .blockedWords)) ?? d.blockedWords
        learningResetAt = try? c.decode(Date.self, forKey: .learningResetAt)
    }
}

extension KeyboardPreferences {
    /// The keyboard's height: the bar plus four rows of keys, as tall as the
    /// iOS keyboard by default. The number row adds a row; Short and Tall
    /// resize the keys. The keyboard and the app's preview both use it.
    public func keyboardHeight(compact: Bool) -> CGFloat {
        let extraRow: CGFloat = numberRow ? (compact ? 34 : 50) : 0
        if compact { return 196 + extraRow }
        switch height {
        case .short: return 238 + extraRow
        case .standard: return 262 + extraRow
        case .tall: return 290 + extraRow
        }
    }
}
