import Combine
import SwiftUI
import UIKit
import VoiceIQBridge

// Stand-ins for Hex types referenced by iOS/Keyboard/Hex outside FullKeyboard.
// VoiceiQ owns dictation hand-off, its top shortcut row and its LevelGlow
// recording strip, so Hex's in-keyboard recording, Metal DotScope, style menu,
// translation and model notices stay permanently off here.

enum KeyboardBridge {
    static let appGroup = SharedStore.appGroupID
}

nonisolated struct KeyboardDictationBlock: Equatable, Sendable {
    var line: String = ""
    var opensHex: Bool = false
}

nonisolated enum HexDictationRoute: Equatable, Sendable {
    case setUp
    case warm
    case inKeyboard
    case needsModel
    case opensHex

    var dictatesInPlace: Bool { self == .warm || self == .inKeyboard }
}

@MainActor
final class KeyboardViewModel: ObservableObject {
    enum StagePhase: Equatable { case idle, starting, recording, transcribing, failed }

    /// Always true so Hex's Full Access strip never replaces VoiceiQ's own bar.
    var hasFullAccess = true
    @Published var needsGlobeKey = true
    /// Always idle: VoiceiQ renders its own LevelGlow RecordingStrip above the keys,
    /// so Hex's recording panel and Metal DotScope never mount.
    let stagePhase: StagePhase = .idle
    let statusMessage: String? = nil
    let failureMessage: String? = nil
    let dictationBlock: KeyboardDictationBlock? = nil
    let stoppedNote: (title: String, detail: String)? = nil
    let isWarmAvailable = true
    var route: HexDictationRoute { .warm }
    var dictatesThroughHex: Bool { true }
    var dictationTapOpensHex: Bool { false }
    var dotScopePhase: DotScopePhase { .hidden }
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
    let onDismissTranslationNote: (() -> Void)? = nil
    let onPasteDictation: (() -> Void)? = nil

    func dictateWhereUnavailable() {}
    func dismissDictationBlock() {}
    func openHexForDictationBlock() {}
}

enum KeyboardLaunchRequest {
    case setup, pasteSettings, home, translationSettings

    var url: URL {
        switch self {
        case .setup: BridgeURL.setup
        case .pasteSettings, .home, .translationSettings: BridgeURL.app
        }
    }
}

enum DictationStyle: String, CaseIterable, Sendable {
    case polished

    var label: String { "Polished" }
    var shortHint: String { "" }
    var next: DictationStyle { self }
}

enum HexTheme {
    static let danger = Color(red: 0xE5 / 255.0, green: 0x4D / 255.0, blue: 0x42 / 255.0)
}

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

    static func spanish(forRegion region: String?) -> String {
        region.map { "es-\($0)" } ?? "es-ES"
    }

    static func supportedMatch(for identifier: String, in supported: [String], region: String? = nil) -> String? {
        supported.first { $0.hasPrefix(identifier) } ?? identifier
    }
}

// Empty stand-ins for Hex's Metal recording scope and live preview: never shown.

enum DotScopePhase: Equatable, Sendable { case hidden, idle, starting, recording, processing, failed }

enum DotScopeLook: Equatable { case ios, strip }

struct DotScopePose: Equatable, Sendable {
    var opacity: Float = 0
    var live: Float = 0
    var cool: Float = 0
    var grid: Float = 0
    var glow: Float = 0
}

struct DotScopeTuning: Equatable, Sendable {
    var height: Float = 0
    var transition: Float = 0

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
    var look: DotScopeLook = .ios
    var hostFades = false
    let debugPose = DotScopePose()

    init(tuning: DotScopeTuning, maximumDrawableCount: Int) {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func tearDown() {}
}

@MainActor
final class LiveDictationPreviewHost {
    var palette = FullKeyboardPalette(isDark: false)
    func attach(to keyboard: FullKeyboardView) {}
    func sync() {}
    func layout() {}
}

nonisolated struct KeyboardParakeetPlan: Sendable {
    var awaitsV2Download: Bool { false }
    static func current() -> KeyboardParakeetPlan { KeyboardParakeetPlan() }
}

nonisolated struct KeyboardParakeetNotice: Sendable {
    static let opensHex = BridgeURL.app
    func mayShow(now: Date = Date(), calendar: Calendar = .current) -> Bool { false }
    func recordShown(now: Date = Date(), calendar: Calendar = .current) {}
    func recordOpened() {}
    func recordDismissed() {}
}

/// Maps Hex's custom vocabulary list to VoiceiQ's Dictionary in the App Group so
/// dictionary terms are never autocorrected away and holding a strip suggestion
/// adds the word to VoiceiQ's Dictionary.
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
