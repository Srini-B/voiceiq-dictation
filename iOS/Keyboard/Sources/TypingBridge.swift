import SwiftUI
import UIKit
import VoiceIQBridge

/// Owns Hex's `FullKeyboardView` and connects it to VoiceiQ's `EditController`,
/// `KeyboardModel`, and `UIInputViewController`.
@MainActor
final class TypingBridge: ObservableObject {
    @Published var compact = false

    weak var controller: UIInputViewController?
    weak var editor: EditController?
    var onPreferredHeightChange: (() -> Void)?

    let dictation = KeyboardViewModel()
    private(set) var keyboard: FullKeyboardView?
    private var lexiconEntries: [(userInput: String, documentText: String)] = []

    var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    /// Height of Hex's suggestion strip + keys (and emoji search lift when active).
    var keysHeight: CGFloat {
        keyboard?.preferredHeight ?? KeyboardLayout.height(
            for: compact ? .landscape : .portrait,
            numberRow: FullKeyboardSettings().numberRow
        )
    }

    func makeKeyboard() -> FullKeyboardView {
        if let keyboard { return keyboard }
        let view = FullKeyboardView(model: dictation, target: WeakTextTarget(self))
        view.hostController = controller
        view.languageOverride = .english
        view.letterLayoutOverride = .qwerty
        view.hexPlacementOverride = .hidden
        view.hexKey.removeFromSuperview()
        view.allowsHaptics = { [weak self] in
            self?.controller?.hasFullAccess == true && FullKeyboardSettings().haptics
        }
        view.onPreferredHeightChange = { [weak self] in self?.onPreferredHeightChange?() }
        view.onTextEdit = { [weak self] in self?.editor?.syncSelection() }
        view.onUndoDictation = { [weak self] in self?.editor?.resetUndo() }
        self.keyboard = view
        view.prepareForField()
        applyLexicon()
        return view
    }

    func appeared() {
        refreshHostTraits()
        keyboard?.prepareForField()
        applyLexicon()
    }

    func didAppear() {
        refreshHostTraits()
        keyboard?.keyboardDidAppear()
        keyboard?.warmUpTextCheckerAsync()
        keyboard?.textDidChange()
    }

    func refreshHostTraits() {
        dictation.needsGlobeKey = controller?.needsInputModeSwitchKey ?? true
    }

    func textDidChange() {
        keyboard?.textDidChange()
    }

    func didInsertDictation(_ text: String, before: String, after: String) {
        keyboard?.didInsertDictation(text, before: before, after: after)
    }

    func loadLexicon(_ lexicon: UILexicon) {
        lexiconEntries = lexicon.entries.map { ($0.userInput, $0.documentText) }
        applyLexicon()
    }

    func handleMemoryWarning() {
        keyboard?.handleMemoryWarning()
    }

    private func applyLexicon() {
        guard let keyboard else { return }
        let dictionary = SharedStore.shared.dictionaryWords.filter { !$0.contains(" ") }.map { ($0, $0) }
        keyboard.engine.autocorrect.loadLexiconEntries(lexiconEntries + dictionary)
        keyboard.syncSettings()
        keyboard.engine.refreshSuggestions()
    }
}

extension TypingBridge: @MainActor KeyboardTextTarget {
    private static let noAssistance: Set<UITextContentType> = [
        .oneTimeCode, .password, .newPassword, .creditCardNumber, .telephoneNumber, .postalCode,
    ]

    var documentContextBeforeInput: String? { proxy?.documentContextBeforeInput }
    var hasText: Bool { proxy?.hasText ?? false }
    var autocapitalizationType: UITextAutocapitalizationType? { proxy?.autocapitalizationType }
    var autocorrectionType: UITextAutocorrectionType? {
        if let type = proxy?.textContentType ?? nil, Self.noAssistance.contains(type) { return .no }
        return proxy?.autocorrectionType
    }
    var keyboardType: UIKeyboardType? { proxy?.keyboardType }
    var returnKeyType: UIReturnKeyType? { proxy?.returnKeyType }
    var enablesReturnKeyAutomatically: Bool? { proxy?.enablesReturnKeyAutomatically }
    var keyboardAppearance: UIKeyboardAppearance? { proxy?.keyboardAppearance }
    var textContentType: UITextContentType? { proxy?.textContentType ?? nil }
    var isSecureTextEntry: Bool? { proxy?.isSecureTextEntry }
    var documentContextAfterInput: String? { proxy?.documentContextAfterInput }
    var selectedText: String? { proxy?.selectedText }
    var smartQuotesType: UITextSmartQuotesType? { proxy?.smartQuotesType }
    var smartDashesType: UITextSmartDashesType? { proxy?.smartDashesType }
    var documentIdentifier: UUID? { proxy.flatMap { TypingLogTraits.documentIdentifier(of: $0) } }

    func insertText(_ text: String) {
        if let editor {
            editor.typeFromKeyboard(text)
        } else {
            proxy?.insertText(text)
        }
    }

    func deleteBackward() {
        if let editor {
            editor.deleteFromKeyboard()
        } else {
            proxy?.deleteBackward()
        }
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: offset)
        editor?.cursorMovedExternally()
    }
}

struct HexKeyboardRepresentable: UIViewRepresentable {
    let bridge: TypingBridge

    func makeUIView(context: Context) -> FullKeyboardView {
        bridge.makeKeyboard()
    }

    func updateUIView(_ uiView: FullKeyboardView, context: Context) {}
}
