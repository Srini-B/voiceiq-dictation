import Foundation
import UIKit
import VoiceIQBridge
import VoiceIQCore

/// Settings that exist only on iOS. Everything shared with macOS lives in
/// `SettingsStore`.
enum MobileSettings {
    private static var defaults: UserDefaults { .standard }

    /// What a dictation records from while a headset, car or Bluetooth device
    /// is connected. `KeepAliveAudio` turns it into an input when each
    /// dictation starts.
    enum MicrophoneChoice: String, CaseIterable, Identifiable {
        /// A wired or USB headset's mic, the car's in CarPlay, otherwise the
        /// iPhone's. Bluetooth headphones keep playing in full quality.
        case automatic
        /// Always the iPhone's own mic.
        case iPhone
        /// Bluetooth hands-free mics too (AirPods, headsets, car kits), which
        /// switch to call audio while dictating.
        case bluetooth

        var id: String { rawValue }
        @MainActor var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .iPhone: return UIDevice.current.localizedModel
            case .bluetooth: return "Bluetooth"
            }
        }
    }

    /// Defaults to Automatic. Before this setting, a Bool `preferBuiltInMic`
    /// (default on) chose between the iPhone's mic and AirPods: on reads as
    /// Automatic, off as Bluetooth, until the user picks again.
    static var microphoneChoice: MicrophoneChoice {
        get {
            if let raw = defaults.string(forKey: "microphoneChoice"), let choice = MicrophoneChoice(rawValue: raw) {
                return choice
            }
            if let preferBuiltIn = defaults.object(forKey: "preferBuiltInMic") as? Bool, !preferBuiltIn {
                return .bluetooth
            }
            return .automatic
        }
        set {
            defaults.set(newValue.rawValue, forKey: "microphoneChoice")
            Log.ui.info("setting microphoneChoice changed to \(newValue.rawValue, privacy: .public)")
        }
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
        set {
            defaults.set(newValue.rawValue, forKey: "warmWindowSeconds")
            Log.ui.info("setting warmWindowSeconds changed to \(newValue.rawValue)")
        }
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
