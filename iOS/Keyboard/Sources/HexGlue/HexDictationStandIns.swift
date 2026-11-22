import Combine
import SwiftUI
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
    /// The strip's mic always reaches VoiceiQ's dictation.
    var dictatesThroughHex: Bool { true }
    let isLoggingTyping = false
    let offeredDictation: String? = nil
    let style: DictationStyle = .polished
    let dictationLanguage: String? = nil
    let automaticLanguage: String? = nil
    let languageChoices: [String] = []
    let moreLanguages: [String] = []
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
    let onLanguageRemoved: ((String) -> Void)? = nil
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

/// Hex's colours the keyboard's own views name.
enum HexTheme {
    static let danger = Color(red: 0xE5 / 255.0, green: 0x4D / 255.0, blue: 0x42 / 255.0)
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

    static func nativeName(for identifier: String, supported: [String]) -> String {
        nativeName(for: identifier)
    }

    static func nativeNames(for identifiers: [String], supported: [String] = []) -> [String: String] {
        Dictionary(uniqueKeysWithValues: identifiers.map { ($0, nativeName(for: $0)) })
    }

    // Spanish's keyboard regions; VoiceiQ ships English only, so these name the
    // language without Apple Speech's list.
    static func spanish(forRegion region: String?) -> String {
        region.map { "es-\($0)" } ?? "es-ES"
    }

    static func supportedMatch(for identifier: String, in supported: [String], region: String? = nil) -> String? {
        supported.first { $0.hasPrefix(identifier) } ?? identifier
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

/// Hex's vocabulary list is VoiceiQ's Dictionary: the keys never autocorrect its
/// words away, and the strip's Add to vocabulary queues a word for the app, as the
/// dictionary offer does (`SharedStore.requestDictionaryAddition`). Without Full
/// Access nothing reaches the app, so a word added then lasts for this session.
@MainActor
struct CustomVocabularySettings {
    nonisolated static let maxTermCount = 100
    private static var addedThisSession: [String] = []

    var terms: [String] {
        get { Self.sanitize(SharedStore.shared.dictionaryWords + Self.addedThisSession) }
        nonmutating set {
            let saved = Set(terms.map(VocabularySpelling.normalizedKey))
            for term in Self.sanitize(newValue) where !saved.contains(VocabularySpelling.normalizedKey(term)) {
                SharedStore.shared.requestDictionaryAddition(term)
                Self.addedThisSession.append(term)
            }
        }
    }

    /// Hex's rule: trimmed, two letters or digits at least, one per spelling, at most 100.
    static func sanitize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        let kept = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { term in
            let key = VocabularySpelling.normalizedKey(term)
            return key.count >= 2 && term.count <= 64 && seen.insert(key).inserted
        }
        return Array(kept.prefix(maxTermCount))
    }
}

enum VocabularySpelling {
    static func normalizedKey(_ term: String) -> String {
        term.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
