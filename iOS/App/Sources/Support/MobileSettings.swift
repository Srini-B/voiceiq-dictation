import Foundation
import UIKit
import VoiceIQBridge

/// Settings that exist only on iOS. Everything shared with macOS lives in
/// `SettingsStore`.
enum MobileSettings {
    private static let defaults = UserDefaults.standard

    /// Record from the iPhone's microphone even when AirPods are connected, so
    /// their audio stays in high quality. Default on, like Typeless.
    static var preferBuiltInMic: Bool {
        get { defaults.object(forKey: "preferBuiltInMic") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "preferBuiltInMic") }
    }

    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "mobileOnboardingDone") }
        set { defaults.set(newValue, forKey: "mobileOnboardingDone") }
    }

    /// The onboarding page the user last reached. iOS can end the app while
    /// they are in Settings turning on the keyboard, so setup resumes here
    /// instead of starting over.
    static var onboardingStep: Int {
        get { defaults.integer(forKey: "mobileOnboardingStep") }
        set { defaults.set(newValue, forKey: "mobileOnboardingStep") }
    }

    /// How long the session keeps the mic open after a dictation, so the next
    /// keyboard tap records in place. When it runs out the session ends, and
    /// the next tap opens VoiceiQ once.
    enum WarmWindow: Int, CaseIterable, Identifiable {
        case never = 0, fiveSeconds = 5, tenSeconds = 10, thirtySeconds = 30, oneMinute = 60
        case fiveMinutes = 300, oneHour = 3600, twelveHours = 43_200

        var id: Int { rawValue }
        var seconds: TimeInterval { TimeInterval(rawValue) }
        var label: String {
            switch self {
            case .never: return "Never"
            case .oneMinute: return "1 minute"
            case .fiveMinutes: return "5 minutes"
            case .oneHour: return "1 hour"
            case .twelveHours: return "12 hours"
            default: return "\(rawValue) seconds"
            }
        }
    }

    static var warmWindow: WarmWindow {
        get {
            (defaults.object(forKey: "warmWindowSeconds") as? Int).flatMap(WarmWindow.init(rawValue:)) ?? .thirtySeconds
        }
        set { defaults.set(newValue.rawValue, forKey: "warmWindowSeconds") }
    }

    static let keyboardBundleID = "io.blue.voiceiq.ios.keyboard"

    /// The keyboard is in Settings › General › Keyboard › Keyboards.
    static var keyboardAdded: Bool {
        (defaults.object(forKey: "AppleKeyboards") as? [String])?.contains(keyboardBundleID) ?? false
    }

    /// The keyboard has run with Full Access at least once. It can only write
    /// to the App Group when Full Access is on, so this is proof, not a guess.
    static var keyboardHasFullAccess: Bool {
        SharedStore.shared.keyboardSeenAt != nil
    }
}
