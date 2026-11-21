import Combine
import UIKit
import VoiceIQBridge

// What Hex's keyboard (iOS/Keyboard/Hex) reads from the rest of Hex, for VoiceiQ.
// Hex's keys sit under VoiceiQ's own dictation UI, so everything about Hex's own
// dictation (its recording panel, styles, languages, translation) stays switched
// off here: VoiceiQ records in its app and the keyboard shows its own mic bar.

enum KeyboardBridge {
    static let appGroup = SharedStore.appGroupID
}

/// The dictation side of Hex's keyboard. `KeyboardController` sets the callbacks:
/// the strip's mic (`DictationKeyControl`) calls them as Hex's key did; the
/// Hex key itself is removed (`TypingController.makeKeyboard`).
@MainActor
final class KeyboardViewModel: ObservableObject {
    enum StagePhase: Equatable { case idle, recording, transcribing, failed }

    /// Always true, so Hex never shows its own Full Access hint; VoiceiQ's mic
    /// action asks for Full Access when it's off.
    let hasFullAccess = true
    @Published var needsGlobeKey = true
    /// Never recording: VoiceiQ shows its own recording strip above the keys, so
    /// Hex's recording panel never opens.
    let stagePhase: StagePhase = .idle
    let statusMessage: String? = nil
    let isWarmAvailable = true
    let isLoggingTyping = false
    let offeredDictation: String? = nil
    let style: DictationStyle = .polished
    let dictationLanguage: String? = nil
    let automaticLanguage: String? = nil
    let languageChoices: [String] = []
    let translationNote: TranslationFailure? = nil
    let translationLanguage: String? = nil
    let translationTargetChoices: [String] = []
    let liveLoudnessDB: Float = -62
    let coldStartURL = BridgeURL.app

    var showsLanguageSwitch: Bool { false }
    var showsTranslationSwitch: Bool { false }
    var isTranslating: Bool { false }
    var translatingTo: String? { nil }
    var languageSummary: String? { nil }

    var onDictateTap: (() -> Void)?
    var onStopTap: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    let onLocalDictateTap: (() -> Void)? = nil
    let onHexKeyPress: ((TimeInterval) -> Void)? = nil
    let onHexKeyAbandon: (() -> Void)? = nil
    let onCancelTap: (() -> Void)? = nil
    let onStyleSelected: ((DictationStyle) -> Void)? = nil
    let onLanguageSelected: ((String?) -> Void)? = nil
    let onTranslationToggled: ((Bool) -> Void)? = nil
    let onTranslationTargetSelected: ((String) -> Void)? = nil
    let onPasteDictation: (() -> Void)? = nil
}

/// Where Hex's keyboard sends people: VoiceiQ's setup in both cases.
enum KeyboardLaunchRequest {
    case setup, translationSettings

    var url: URL { BridgeURL.setup }
}

/// Hex's dictation styles. VoiceiQ has its own modes; Hex's menu never opens.
enum DictationStyle: String, CaseIterable, Sendable {
    case polished

    var label: String { "Polished" }
    var shortHint: String { "" }
    var next: DictationStyle { self }
}

/// Hex's translation of dictations; off in VoiceiQ.
struct TranslationPasteChoice {
    static func toggleTitle(target: String) -> String { target }
    static func badge(target: String) -> String { target.uppercased() }
    static func translatingLabel(target: String) -> String { target }
    static func name(of identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

struct TranslationFailure: Equatable, Sendable {
    static var note: String { "" }
    var fix: String { "" }
}

enum DictationLanguageSwitch {
    static func nativeName(for identifier: String) -> String {
        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
    }

    static func nativeNames(for identifiers: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: identifiers.map { ($0, nativeName(for: $0)) })
    }
}

// Hex's Metal recording panel never opens here (`KeyboardViewModel.stagePhase`
// stays idle), so its scope is an empty view.

enum DotScopePhase: Equatable, Sendable { case hidden, idle, recording, processing, failed }

struct DotScopeTuning: Equatable, Sendable {
    var height: Float = 0

    static func bar(leadingInset: Float = 0, trailingInset: Float = 0, fade: Float = 0, spacing: Float = 0) -> DotScopeTuning {
        DotScopeTuning()
    }
}

@MainActor
final class DotScopeHostView: UIView {
    var phase: DotScopePhase = .hidden
    var drawPlate = false
    var loudnessProvider: (() -> Float)?
    var reduceMotion = false
    var useDemoVoice = false
    var isDark = false

    init(tuning: DotScopeTuning, maximumDrawableCount: Int) {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func tearDown() {}
}

// Hex's custom vocabulary, which its dictation-correction helpers name. The
// keyboard never calls those helpers (they feed Hex's speech recognizer).

enum CustomVocabularySettings {
    static let maxTermCount = 100
}

enum VocabularySpelling {
    static func normalizedKey(_ term: String) -> String {
        term.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
