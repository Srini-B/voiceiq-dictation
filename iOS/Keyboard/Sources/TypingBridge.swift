import SwiftUI
import UIKit
import VoiceIQBridge

/// Owns Hex's `FullKeyboardView` and connects it to VoiceiQ's `EditController`,
/// `KeyboardModel`, and `UIInputViewController`.
@MainActor
final class TypingBridge: ObservableObject {
    @Published var compact = false
    /// Hex's suggestion row in the keyboard (VoiceiQ's buttons sit at its ends), the
    /// landscape safe-area inset Hex keeps on both sides, and whether the emoji panel is up.
    @Published private(set) var stripRow: CGRect = .zero
    @Published private(set) var sideInset: CGFloat = 0
    @Published private(set) var emojiOpen = false

    /// Room at the suggestion row's ends for cursor control and Paste last (leading) and
    /// Dictate (trailing); `KeyboardView` lays its buttons out in exactly this room.
    static let leadingEnd: CGFloat = 86
    static let trailingEnd: CGFloat = 56

    weak var controller: UIInputViewController?
    weak var editor: EditController?
    var onPreferredHeightChange: (() -> Void)?

    let dictation = KeyboardViewModel()
    private(set) var keyboard: FullKeyboardView?
    /// VoiceiQ shows its own content in the suggestion row; Hex shows its strip again after
    /// the emoji panel or a selection, so this is applied again each time the strip refreshes.
    private var suggestionsHidden = false
    private var lexiconEntries: [(userInput: String, documentText: String)] = []

    var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    /// The whole keyboard's height: Hex's suggestion row and keys (and the emoji search lift).
    var keysHeight: CGFloat {
        keyboard?.preferredHeight ?? KeyboardLayout.height(
            for: compact ? .landscape : .portrait,
            numberRow: FullKeyboardSettings().numberRow
        )
    }

    func makeKeyboard() -> FullKeyboardView {
        if let keyboard { return keyboard }
        KeyboardLayout.reservedStripEnds = (Self.leadingEnd, Self.trailingEnd)
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
        view.onStripSuggestions = { [weak self] _ in self?.applySuggestionsHidden() }
        view.onStripRowLayout = { [weak self, weak view] row, emojiOpen in
            guard let self else { return }
            let inset = view?.engine.horizontalInset ?? 0
            if self.stripRow != row { self.stripRow = row }
            if self.sideInset != inset { self.sideInset = inset }
            if self.emojiOpen != emojiOpen { self.emojiOpen = emojiOpen }
        }
        self.keyboard = view
        applySuggestionsHidden()
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
        dictation.hasFullAccess = controller?.hasFullAccess ?? false
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

    /// Hides Hex's suggestions while VoiceiQ shows something else in their row: the
    /// recording strip, a notice, the Dictionary offer or the edit panel.
    func setSuggestionsHidden(_ hidden: Bool) {
        suggestionsHidden = hidden
        applySuggestionsHidden()
    }

    private func applySuggestionsHidden() {
        guard let keyboard else { return }
        // The emoji panel and a two-thumb selection keep the strip hidden themselves while up.
        let hidden = suggestionsHidden || keyboard.emojiPanel != nil || keyboard.engine.selectionPresentation != nil
        if keyboard.stripView.isHidden != hidden { keyboard.stripView.isHidden = hidden }
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
