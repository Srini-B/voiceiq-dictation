import Foundation
import VoiceIQBridge
import VoiceIQCore

/// Hex's cleanup tagger (iOS/App/Hex/Cleanup, vendored unmodified) as VoiceiQ
/// runs it: on a verbatim transcript that reaches the user without the writing
/// model, in the app and never in the keyboard. English only, as in Hex; it
/// misses its budget and leaves the text to `FillerStripper` otherwise.
enum HexCleanup {
    static let cleaner = VerbatimCleaner(
        prepare: {
            guard speaksOnlyEnglish else { return }
            CleanupTagger.shared.prepare()
        },
        clean: { text in
            guard speaksOnlyEnglish else { return text }
            return await CleanupTagger.shared.clean(
                text, within: CleanupTagger.timeBudget,
                protectedTerms: SharedStore.shared.dictionaryWords
            )
        }
    )

    /// Settings › Languages lists English alone, or nothing (detect), which
    /// Hex also counts as English.
    private static var speaksOnlyEnglish: Bool {
        SettingsStore().spokenLanguages.allSatisfy { $0 == "eng" }
    }
}

// MARK: - What Hex's cleanup files expect from the rest of Hex

/// Hex's App Group: the tagger's on/off switch lives there.
enum KeyboardBridge {
    static let appGroup = SharedStore.appGroupID
}

/// Hex's dictation styles. VoiceiQ has its own modes and never passes `.verbatim`.
nonisolated enum DictationStyle: String, Sendable {
    case polished, verbatim
}

/// Hex's dictation formatter. Only `SpokenCleanupRules.clean`, Hex's cleanup for
/// languages other than English, reads it, and VoiceiQ never calls that.
nonisolated enum TranscriptFormatter {
    static func fillerPattern(for language: String?) -> String? { nil }
}

/// Hex's language check: nil (detect) counts as English.
nonisolated enum SpeechLanguagePicker {
    static func isEnglish(_ identifier: String?) -> Bool {
        guard let identifier else { return true }
        return Locale(identifier: identifier).language.languageCode?.identifier == "en"
    }
}
