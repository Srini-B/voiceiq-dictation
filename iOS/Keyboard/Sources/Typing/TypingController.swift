import UIKit
import VoiceIQBridge

/// Typing: Hex's keyboard (`FullKeyboardView`, iOS/Keyboard/Hex) types, suggests,
/// autocorrects and reads slides; this owns it and the VoiceiQ panels around it
/// (emoji, edit, mini keys). It is also the keys' text target, so every edit the
/// keys make reaches the field through here: the edit panel can undo it, and while
/// emoji search is open the letters go into the search instead.
@MainActor
final class TypingController: ObservableObject {
    @Published var showsEmoji = false
    /// Typed letters go here instead of the field while searching emoji.
    @Published var emojiQuery: String?
    @Published var showsEdit = false
    /// Landscape on iPhone: a shorter bar.
    @Published var compact = false
    /// The mini keyboard: the mic bar over two rows of keys. The user's last
    /// choice, kept by the keyboard itself so it needs no Full Access.
    @Published private(set) var mini = UserDefaults.standard.bool(forKey: "typing.mini")
    /// The mini keys show digits instead of punctuation.
    @Published var miniDigits = false
    /// The mini keys are on screen: set by `KeyboardView`, which knows when a
    /// panel or the voice screen takes their place at full height.
    var showsMini = false { didSet { if showsMini != oldValue { onHeightChange?() } } }
    var onHeightChange: (() -> Void)?
    /// Nothing typed since the keyboard appeared, so the bar may show the
    /// Dictionary offer.
    @Published private(set) var typedSinceAppear = false
    /// A hold on the strip's mic started a dictation the app has not picked up
    /// yet. The keys stay on screen meanwhile: swapping them for the voice panel
    /// would end the mic's touch, and lifting the hold could never stop it.
    @Published var dictationKeyStarting = false
    /// The voice panel is open, from the strip's or a panel's waveform button.
    @Published var voiceOpen = false
    /// Hex's strip in the keys view: the whole bar, the part between VoiceiQ's
    /// buttons where the suggestions are, and the height down to the keys.
    @Published private(set) var stripBar = CGRect.zero
    @Published private(set) var stripSlots = CGRect.zero
    @Published private(set) var stripArea: CGFloat = KeyboardMetrics.portrait.stripArea
    /// What covers the strip: the Dictionary offer the suggestions, a recording
    /// or the emoji search all of it, VoiceiQ's buttons too.
    var stripCover = StripCover.none { didSet { applyStripCover() } }
    enum StripCover: Equatable { case none, suggestions, all }
    /// The strip mic's tap; its hold goes through `dictation` as the Hex key's did.
    var onMicTap: (() -> Void)?
    private var stripButtons: [StripButton: UIControl] = [:]
    /// The buttons beside the space bar rather than in the strip.
    private var bottomRowButtons: Set<StripButton> = []

    init() {
        HexStripHeight.install()
        KeyboardLayout.spaceSideRoom = StripButton.spaceSideRoom
    }
    /// The text selected in the field, so the bar's Dictionary offer ends with
    /// the selection.
    @Published private(set) var selection = ""
    @Published private(set) var isDigitPad = false
    @Published var undoStack: [UndoStep] = []
    @Published var redoStack: [UndoStep] = []
    var lastEdit: EditKind?
    /// The keys deleted in this run-loop turn (`insertText`).
    var deletedThisTurn = false
    /// The undo steps before this turn's first delete, and what the turn
    /// deleted, so a replacement typed in the same turn is its own undo step.
    var undoBeforeTurn: [UndoStep]?
    var turnDeletes: [String] = []
    /// Counts delete turns, so an older turn's queued end never ends a newer one.
    var deleteTurn = 0

    weak var controller: UIInputViewController?
    var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    /// What Hex's dictation side reads, and the callbacks the strip's mic calls
    /// as Hex's key did.
    let dictation = KeyboardViewModel()
    private(set) var keyboard: FullKeyboardView?
    /// Text Replacements and contacts from iOS, kept to merge with the Dictionary.
    private var lexicon: [(userInput: String, documentText: String)] = []
    /// The text around the cursor after the last edit seen.
    private var lastBefore: String?
    private var lastAfter: String?

    /// Hex's keys, made on first use with this controller as their text target.
    func makeKeyboard() -> FullKeyboardView {
        if let keyboard { return keyboard }
        let keyboard = FullKeyboardView(model: dictation, target: WeakTextTarget(self))
        keyboard.hostController = controller
        keyboard.allowsHaptics = { [weak self] in self?.controller?.hasFullAccess == true }
        keyboard.languageOverride = .english
        keyboard.letterLayoutOverride = .qwerty
        keyboard.onPreferredHeightChange = { [weak self] in self?.onHeightChange?() }
        // The emoji key opens VoiceiQ's emoji panel.
        keyboard.engine.onEmojiKey = { [weak self] in
            guard let self else { return }
            if self.emojiQuery != nil { self.closeEmojiSearch() } else { self.showsEmoji = true }
        }
        // One row: VoiceiQ's buttons take the strip's ends and the space bar's
        // sides, and the Hex key goes; the strip's mic does what it did.
        keyboard.hexKey.removeFromSuperview()
        for button in StripButton.allCases {
            let control = makeStripButton(button)
            stripButtons[button] = control
            keyboard.addSubview(control)
        }
        keyboard.stripLayout = { [weak self] layout, lift in
            // Hex's strip keeps its frame, with the words on `stripTextCenter`; VoiceiQ's
            // buttons and the overlays in its place get a band as tall, centred on that line.
            let hexBar = layout.stripBarFrame.offsetBy(dx: 0, dy: lift)
            let bar = hexBar.offsetBy(dx: 0, dy: layout.metrics.stripTextCenter - hexBar.height / 2)
            let beside = StripButton.besideSpace(in: layout).map {
                (mini: $0.mini.offsetBy(dx: 0, dy: lift), edit: $0.edit.offsetBy(dx: 0, dy: lift))
            }
            let placed = StripButton.layout(bar: bar, side: layout.metrics.side, besideSpace: beside)
            self?.placeStrip(buttons: placed.buttons, besideSpace: beside != nil, radius: layout.metrics.cornerRadius,
                             bar: bar, slots: placed.strip, area: layout.metrics.stripArea + lift)
            func onHexBar(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX, y: hexBar.minY - lift, width: rect.width, height: hexBar.height)
            }
            return (onHexBar(placed.strip), placed.slots.map(onHexBar))
        }
        self.keyboard = keyboard
        keyboard.prepareForField()
        loadWords()
        return keyboard
    }

    /// The keys' height at the current orientation, strip included.
    var keysHeight: CGFloat {
        keyboard?.preferredHeight ?? KeyboardLayout.height(for: compact ? .landscape : .portrait)
    }

    // MARK: - Lifecycle

    func appeared() {
        HexKeyboardSettings.apply(SharedStore.shared.keyboardPreferences)
        showsEmoji = false
        emojiQuery = nil
        showsEdit = false
        miniDigits = false
        typedSinceAppear = false
        dictationKeyStarting = false
        undoStack = []
        redoStack = []
        lastEdit = nil
        readField()
        keyboard?.prepareForField()
        loadWords()
        refresh()
    }

    func readField() {
        dictation.needsGlobeKey = controller?.needsInputModeSwitchKey ?? true
        let type = proxy?.keyboardType ?? .default
        isDigitPad = KeyboardFieldRouting.route(for: type) == .handOff
    }

    /// iOS ends a keyboard over its memory limit and shows its own.
    func releaseMemory() {
        keyboard?.handleMemoryWarning()
    }

    /// Text Replacements and contact names from iOS.
    func setSupplementaryLexicon(_ entries: [(String, String)]) {
        lexicon = entries.map { (userInput: $0.0, documentText: $0.1) }
        loadWords()
    }

    /// iOS's lexicon and VoiceiQ's Dictionary are words the keys know, suggest and slide to.
    private func loadWords() {
        guard let keyboard else { return }
        let dictionary = SharedStore.shared.dictionaryWords.filter { !$0.contains(" ") }.map { ($0, $0) }
        keyboard.engine.autocorrect.loadLexiconEntries(lexicon + dictionary)
        keyboard.syncSettings()
        keyboard.engine.refreshSuggestions()
    }

    /// Hands the words Hex learned (each kept twice from the strip or by undoing
    /// its correction) to the app, which adds them to the Dictionary as
    /// Auto-learned. The App Group needs Full Access.
    func publishLearnedWords() {
        guard controller?.hasFullAccess == true, let keyboard else { return }
        let words = Array(keyboard.engine.autocorrect.learnedWords.words.suffix(200).reversed())
        guard words != SharedStore.shared.keyboardLearnedWords else { return }
        SharedStore.shared.setKeyboardLearnedWords(words)
    }

    /// The field changed outside the keys: another keyboard, the app, the
    /// user moving the cursor.
    func textChanged() {
        readField()
        if proxy?.documentContextBeforeInput != lastBefore || proxy?.documentContextAfterInput != lastAfter {
            forgetUndo()
        }
        keyboard?.textDidChange()
        refresh()
    }

    /// Rereads the selection and the text around the cursor after an edit.
    func refresh() {
        let selected = proxy?.selectedText ?? ""
        if selection != selected { selection = selected }
        lastBefore = proxy?.documentContextBeforeInput
        lastAfter = proxy?.documentContextAfterInput
    }

    /// An edit VoiceiQ made itself (a dictation, the edit panel, an emoji):
    /// the keys' strip and shift follow it.
    func editedOutsideKeys() {
        keyboard?.textDidChange()
        refresh()
    }

    /// The dictation side wrote straight to the field (a dictation, an
    /// answer, the voice panel's keys): the recorded undo steps no longer
    /// match the text, so Undo would delete the wrong characters.
    func modelWroteToField() {
        forgetUndo()
        editedOutsideKeys()
    }

    // MARK: - Strip

    private func makeStripButton(_ button: StripButton) -> UIControl {
        if button == .mic {
            let mic = DictationKeyControl()
            mic.onPress = { [weak self] at in self?.dictation.onHexKeyPress?(at) }
            mic.onTap = { [weak self] in self?.onMicTap?() }
            mic.onHold = { [weak self] in self?.dictation.onDictateTap?() }
            mic.onHoldRelease = { [weak self] in self?.dictation.onStopTap?() }
            mic.onAbandon = { [weak self] in self?.dictation.onHexKeyAbandon?() }
            return mic
        }
        let control = StripKeyButton(button)
        control.addAction(UIAction { [weak self] _ in self?.stripButtonTapped(button) }, for: .touchUpInside)
        return control
    }

    private func stripButtonTapped(_ button: StripButton) {
        switch button {
        case .voice:
            voiceOpen = true
            showsEmoji = false
            showsEdit = false
        case .mini: toggleMini()
        case .edit:
            showsEmoji = false
            showsEdit = true
        case .mic: break
        }
    }

    private func placeStrip(
        buttons frames: [StripButton: CGRect], besideSpace: Bool, radius: CGFloat, bar: CGRect, slots: CGRect, area: CGFloat
    ) {
        bottomRowButtons = besideSpace ? [.mini, .edit] : []
        for (button, control) in stripButtons {
            control.frame = frames[button] ?? .zero
            if let key = control as? StripKeyButton {
                key.isKey = bottomRowButtons.contains(button)
                key.cornerRadius = radius
            }
        }
        applyStripCover()
        guard (bar, slots, area) != (stripBar, stripSlots, stripArea) else { return }
        // Layout runs inside SwiftUI's update; publish after it.
        DispatchQueue.main.async { [weak self] in
            self?.stripBar = bar
            self?.stripSlots = slots
            self?.stripArea = area
        }
    }

    private func applyStripCover() {
        keyboard?.stripView.isHidden = stripCover != .none
        for (button, control) in stripButtons {
            control.isHidden = control.frame.isEmpty
            // Faded, not hidden: a hold on the mic that starts the recording
            // strip keeps its touch, so lifting it still stops the dictation.
            // The keys beside the space bar stay, as the other keys do.
            control.alpha = stripCover == .all && !bottomRowButtons.contains(button) ? 0 : 1
        }
    }

    // MARK: - Panels and mini keys

    func toggleMini() {
        mini.toggle()
        UserDefaults.standard.set(mini, forKey: "typing.mini")
        miniDigits = false
    }

    func insert(_ text: String) {
        checkpoint(text.first?.isLetter == true || text.first?.isNumber == true ? .typing : .other)
        typeText(text)
        typedSinceAppear = true
        editedOutsideKeys()
    }

    func insertEmoji(_ emoji: String) {
        EmojiData.noteUsed(emoji)
        if emojiQuery != nil {
            emojiQuery = nil
            showsEmoji = true
        }
        insert(emoji)
    }

    /// Delete from a panel or the mini keys: the search while searching emoji.
    func deleteFromPanel() {
        deleteBackward()
        if emojiQuery == nil { editedOutsideKeys() }
    }
}

// MARK: - The keys' text target

extension TypingController: @MainActor KeyboardTextTarget {
    /// While searching emoji the keys see the search, so autocorrect and
    /// suggestions work on it and never on the field.
    var documentContextBeforeInput: String? { emojiQuery ?? proxy?.documentContextBeforeInput }
    var hasText: Bool { emojiQuery.map { !$0.isEmpty } ?? proxy?.hasText ?? false }
    var autocapitalizationType: UITextAutocapitalizationType? { emojiQuery != nil ? UITextAutocapitalizationType.none : proxy?.autocapitalizationType }
    /// Off in the search and in fields where a correction or a text
    /// replacement would corrupt what is typed: Hex checks only this and the
    /// field kind before replacing a word.
    var autocorrectionType: UITextAutocorrectionType? {
        if emojiQuery != nil { return .no }
        if let type = proxy?.textContentType ?? nil, Self.noAssistance.contains(type) { return .no }
        return proxy?.autocorrectionType
    }
    private static let noAssistance: [UITextContentType] = [.oneTimeCode, .password, .newPassword, .creditCardNumber,
                                                            .telephoneNumber, .postalCode]
    var keyboardType: UIKeyboardType? { emojiQuery != nil ? .default : proxy?.keyboardType }
    var returnKeyType: UIReturnKeyType? { emojiQuery != nil ? .search : proxy?.returnKeyType }
    var enablesReturnKeyAutomatically: Bool? { emojiQuery != nil ? false : proxy?.enablesReturnKeyAutomatically }
    var keyboardAppearance: UIKeyboardAppearance? { proxy?.keyboardAppearance }
    var textContentType: UITextContentType? { emojiQuery != nil ? nil : proxy?.textContentType ?? nil }
    var isSecureTextEntry: Bool? { proxy?.isSecureTextEntry }

    func insertText(_ text: String) {
        if let query = emojiQuery {
            // Return closes the search, as the keys' search key.
            if text == "\n" { emojiQuery = nil; showsEmoji = true } else { emojiQuery = query + text.lowercased() }
            return
        }
        let wordCharacter = text.count == 1 && (text.first?.isLetter == true || text.first?.isNumber == true)
        if deletedThisTurn {
            // A text replacement or a correction: the keys deleted what was
            // typed and type its replacement in one go, one undo step, apart
            // from a Backspace run before it.
            groupTurnDeletes()
            lastEdit = .other
        } else {
            checkpoint(wordCharacter ? .typing : .other)
        }
        typeText(text)
        typedSinceAppear = true
        refresh()
    }

    func deleteBackward() {
        if var query = emojiQuery {
            if !query.isEmpty { query.removeLast() }
            emojiQuery = query
            return
        }
        if !deletedThisTurn {
            deletedThisTurn = true
            undoBeforeTurn = undoStack
            turnDeletes = []
            deleteTurn += 1
            let turn = deleteTurn
            DispatchQueue.main.async { [weak self] in
                guard let self, self.deleteTurn == turn else { return }
                self.endDeleteTurn()
            }
        }
        checkpoint(.deleting)
        turnDeletes.append(deleteBack())
        refresh()
    }

    /// The space-bar trackpad.
    func adjustTextPosition(byCharacterOffset offset: Int) {
        guard emojiQuery == nil else { return }
        proxy?.adjustTextPosition(byCharacterOffset: offset)
        forgetUndo()
        refresh()
    }
}
