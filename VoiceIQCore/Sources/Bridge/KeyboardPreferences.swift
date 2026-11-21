import Foundation

/// Typing settings the app writes and the keyboard reads. The keyboard hands
/// them to Hex's keys (iOS/Keyboard/Sources/HexGlue/HexKeyboardSettings.swift).
public struct KeyboardPreferences: Codable, Equatable, Sendable {
    public var autocorrect = true
    public var autocapitalize = true
    public var slideToType = true
    /// When the user last asked to forget learned words. The keyboard clears
    /// the words it kept when this is newer.
    public var learningResetAt: Date?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeyboardPreferences()
        autocorrect = (try? c.decode(Bool.self, forKey: .autocorrect)) ?? d.autocorrect
        autocapitalize = (try? c.decode(Bool.self, forKey: .autocapitalize)) ?? d.autocapitalize
        slideToType = (try? c.decode(Bool.self, forKey: .slideToType)) ?? d.slideToType
        learningResetAt = try? c.decode(Date.self, forKey: .learningResetAt)
    }
}
