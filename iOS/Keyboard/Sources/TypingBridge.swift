import SwiftUI
import UIKit
import VoiceIQBridge

/// Owns Hex's `FullKeyboardView` and connects it to VoiceiQ's `EditController`,
/// `KeyboardModel`, and `UIInputViewController`.
@MainActor
final class TypingBridge: ObservableObject {
    @Published var compact = false
    /// Hex's suggestion row in the keyboard, between the keys' outer edges (VoiceiQ's
    /// buttons sit at its ends), and whether the emoji panel is up.
    @Published private(set) var stripRow: CGRect = .zero
    @Published private(set) var emojiOpen = false
    /// Paste last sits beside cursor control, except while a suggestion too long for its
    /// slot shows: then the row keeps one button at its left end (Paste last moves to the
    /// cursor page), so the words get the room.
    @Published private(set) var pasteInRow = true

    /// Every button in the row (cursor control, Paste last, Dictate, recording's Cancel and
    /// Done) is this wide, as tall as Hex's suggestion capsule.
    static let buttonWidth: CGFloat = 44
    static let buttonGap: CGFloat = 6

    /// Room at the suggestion row's ends; `KeyboardView` lays its buttons out in exactly this room.
    var leadingEnd: CGFloat { Self.leadingEnd(pasteInRow: pasteInRow) }
    static let trailingEnd: CGFloat = buttonWidth + buttonGap

    static func leadingEnd(pasteInRow: Bool) -> CGFloat {
        (pasteInRow ? 2 * buttonWidth + buttonGap : buttonWidth) + buttonGap
    }

    weak var controller: UIInputViewController?
    weak var editor: EditController?
    var onPreferredHeightChange: (() -> Void)?

    let dictation = KeyboardViewModel()
    let learning = DictationLearning()
    private(set) var keyboard: FullKeyboardView?
    /// VoiceiQ shows its own content in the suggestion row; Hex shows its strip again after
    /// the emoji panel or a selection, so this is applied again each time the strip refreshes.
    private var suggestionsHidden = false
    private var lexiconEntries: [(userInput: String, documentText: String)] = []
    /// The words Hex's strip shows now, and where Paste last is headed (applied on the next
    /// run-loop turn, see `fitEnds`).
    private var stripWords: [String] = []
    private var pasteTarget = true

    var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }
    /// The text before the cursor with a held draft in it, nil without one
    /// (`KeyboardModel.textBeforeWithDraft`).
    var textBeforeWithDraft: (() -> String?)?

    /// The whole keyboard's height: Hex's suggestion row and keys (and the emoji search lift).
    var keysHeight: CGFloat {
        keyboard?.preferredHeight ?? KeyboardLayout.height(
            for: compact ? .landscape : .portrait,
            numberRow: FullKeyboardSettings().numberRow
        )
    }

    func makeKeyboard() -> FullKeyboardView {
        if let keyboard { return keyboard }
        KeyboardLayout.reservedStripEnds = (leadingEnd, Self.trailingEnd)
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
        view.onTextEdit = { [weak self] in
            self?.editor?.syncSelection()
            self?.observeDictation(fromKeys: true)
        }
        view.onUndoDictation = { [weak self] in
            self?.editor?.resetUndo()
            self?.learning.undone()
        }
        // A return key labelled Send ends the dictation's edit window: what is there is sent.
        view.onReturnKey = { [weak self] in
            guard let self, self.proxy?.returnKeyType == .send else { return }
            self.learning.finish(self.editContext)
        }
        view.onStripRowLayout = { [weak self] row, emojiOpen in
            guard let self else { return }
            let widthChanged = self.stripRow.width != row.width
            if self.stripRow != row { self.stripRow = row }
            if self.emojiOpen != emojiOpen { self.emojiOpen = emojiOpen }
            // Rotation, or the first layout: the same words may need the room now, or no longer.
            if widthChanged { self.fitEnds(to: self.stripWords) }
        }
        view.onStripSuggestions = { [weak self] words in
            self?.applySuggestionsHidden()
            self?.stripWords = words
            self?.fitEnds(to: words)
        }
        self.keyboard = view
        applySuggestionsHidden()
        view.prepareForField()
        applyLexicon()
        return view
    }

    func appeared() {
        // Shared by every keyboard instance in the process: put back this one's ends.
        KeyboardLayout.reservedStripEnds = (leadingEnd, Self.trailingEnd)
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

    /// `fromKeys`: this keyboard made the change, not the app.
    func textDidChange(fromKeys: Bool = false) {
        keyboard?.textDidChange()
        observeDictation(fromKeys: fromKeys)
    }

    func didInsertDictation(_ text: String, before: String, after: String) {
        keyboard?.didInsertDictation(text, before: before, after: after)
        learning.inserted(text, before: .init(before: before, after: after, hasText: !(before + after).isEmpty),
                          after: editContext, learns: learnsFromDictation)
    }

    /// While the text connection still reaches the field.
    func willDisappear() {
        learning.finish(editContext)
    }

    // MARK: - Learning from fixes to dictations

    /// Dictations are followed, as in Hex, only in fields its journal may learn from: text
    /// and web search fields that allow autocorrect, never a secure or credential field.
    private var learnsFromDictation: Bool {
        TypingJournal.allows(field: KeyboardFieldRouting.route(for: keyboardType).field, target: self)
    }

    private var editContext: DictationLearning.Context {
        .init(before: proxy?.documentContextBeforeInput, after: proxy?.documentContextAfterInput,
              hasText: proxy?.hasText ?? false)
    }

    private func observeDictation(fromKeys: Bool) {
        learning.observe(editContext, fromKeys: fromKeys)
    }

    func loadLexicon(_ lexicon: UILexicon) {
        lexiconEntries = lexicon.entries.map { ($0.userInput, $0.documentText) }
        applyLexicon()
    }

    /// Paste last leaves the row once a word would need type smaller than 13 pt to fit its
    /// slot beside both left buttons (a third of the room, less 3 pt a side): "Incomprehensible",
    /// not "Including". It comes back only between words (after a space, punctuation, a symbol
    /// or emoji), so the row doesn't change under the thumb at every letter.
    private func fitEnds(to words: [String]) {
        guard stripRow.width > 0 else { return }
        let slot = (stripRow.width - Self.leadingEnd(pasteInRow: true) - Self.trailingEnd) / 3 - 6
        let font = UIFont.systemFont(ofSize: 13)
        let long = words.contains { ($0 as NSString).size(withAttributes: [.font: font]).width > slot }
        var target = !long
        if target, !pasteTarget {
            let last = proxy?.documentContextBeforeInput?.last
            target = last.map { !($0.isLetter || $0.isNumber) } ?? true
        }
        guard target != pasteTarget else { return }
        pasteTarget = target
        // Hex refreshes its strip inside SwiftUI's layout pass, where a published change is
        // dropped: the latest target is applied on the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pasteInRow != self.pasteTarget else { return }
            self.pasteInRow = self.pasteTarget
            KeyboardLayout.reservedStripEnds = (self.leadingEnd, Self.trailingEnd)
            self.keyboard?.setNeedsLayout()
        }
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

    /// Off screen: the emoji panel and its library go (`handleMemoryWarning` keeps them
    /// while the panel is up), and what Learn how I type and Adaptive touch hold is
    /// written out, since iOS may end the extension before it is shown again.
    func disappeared() {
        keyboard?.closeEmojiPanel()
        keyboard?.handleMemoryWarning()
        keyboard?.engine.journal?.save()
        AdaptiveTouch.current?.save()
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
    static let noAssistance: Set<UITextContentType> = [
        .oneTimeCode, .password, .newPassword, .creditCardNumber, .telephoneNumber, .postalCode,
    ]

    /// Hex plans its edits from this, so it has a held draft in it, and the
    /// edits waiting for the next turn (`EditController.projected`).
    var documentContextBeforeInput: String? {
        (textBeforeWithDraft?() ?? proxy?.documentContextBeforeInput).map { editor?.projected($0) ?? $0 }
    }
    var hasText: Bool { proxy?.hasText ?? false }
    var autocapitalizationType: UITextAutocapitalizationType? { proxy?.autocapitalizationType }
    /// `.no` also turns off Hex's typing journal (`TypingJournal.allows`).
    var autocorrectionType: UITextAutocorrectionType? {
        if proxy?.isSecureTextEntry == true { return .no }
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
        if let editor, !editor.runsNow({ [weak self] in self?.adjustTextPosition(byCharacterOffset: offset) }) { return }
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
