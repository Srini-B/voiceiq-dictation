import AudioToolbox
import UIKit
import VoiceIQBridge

/// Typing: turns key presses, swipes and suggestion taps into edits of the
/// host field, and keeps the suggestion bar and shift key in step with the
/// text before the cursor. The text itself is the state: every decision
/// rereads `documentContextBeforeInput`, so moving the cursor or editing
/// with another keyboard never leaves this out of date.
@MainActor
final class TypingController: ObservableObject, KeyboardKeysDelegate {
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var page: KeyPage = .letters
    @Published private(set) var shift: ShiftState = .off
    @Published private(set) var field = FieldTraits()
    @Published private(set) var returnEnabled = true
    @Published private(set) var preferences = KeyboardPreferences() {
        didSet { if preferences.theme != oldValue.theme || preferences.keyTone != oldValue.keyTone { theme = KeyTheme.make(preferences) } }
    }
    @Published private(set) var theme = KeyTheme.standard
    @Published var showsEmoji = false
    /// Landscape on iPhone: shorter rows and bar.
    @Published var compact = false
    /// Nothing typed since the keyboard appeared, so the bar may show the
    /// Dictionary offer instead of predictions.
    @Published private(set) var typedSinceAppear = false

    weak var controller: UIInputViewController?
    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    private static let lexicon = Bundle.main.url(forResource: "lexicon", withExtension: "bin").flatMap(Lexicon.init(url:))
    private var engine: TypingEngine?
    private var classifier: SwipeClassifier?
    private let checker = UITextChecker()

    /// Shift follows the text (sentence starts) until the user presses it.
    private var shiftIsAuto = true
    private var shiftHeld = false
    private var typedWhileShiftHeld = false
    private var lastShiftTap: Date?
    private var lastSpaceAt: Date?
    /// The last slid word, its alternatives, and whether a space went in before it.
    private var slid: (word: String, alternates: [String], leadingSpace: Bool)?
    /// A slid word gets its space when the next word starts, so punctuation can attach.
    private var pendingSpace = false
    /// The last autocorrection, so the bar can offer the typed letters back.
    private var corrected: (original: String, replacement: String)?

    // MARK: - Lifecycle

    func appeared() {
        preferences = SharedStore.shared.keyboardPreferences
        loadUserWords()
        page = .letters
        showsEmoji = false
        typedSinceAppear = false
        slid = nil
        pendingSpace = false
        corrected = nil
        readField()
        refresh()
    }

    func readField() {
        guard let proxy else { return }
        field = FieldTraits(keyboardType: proxy.keyboardType ?? .default,
                            returnKeyType: proxy.returnKeyType ?? .default,
                            showsGlobe: controller?.needsInputModeSwitchKey ?? true)
        if field.isDigitPad { page = .digits }
    }

    func geometryChanged(_ geometry: KeyGeometry) {
        guard let lexicon = Self.lexicon, engine?.geometry != geometry else { return }
        if engine == nil {
            engine = TypingEngine(lexicon: lexicon, geometry: geometry)
            loadUserWords()
        }
        engine?.geometry = geometry
        classifier = SwipeClassifier(lexicon: lexicon, geometry: geometry)
        refresh()
    }

    /// Text Replacements and contact names from iOS.
    func setSupplementaryLexicon(_ entries: [UILexiconEntry]) {
        var replacements: [String: String] = [:], contacts: [String: String] = [:]
        for entry in entries {
            if entry.userInput == entry.documentText {
                for name in entry.documentText.split(separator: " ") where name.count > 1 {
                    contacts[TypingEngine.key(of: String(name))] = String(name)
                }
            } else {
                replacements[entry.userInput.lowercased()] = entry.documentText
            }
        }
        pendingLexicon = (replacements, contacts)
        engine?.replacements = replacements
        engine?.user.contacts = contacts
    }

    private var pendingLexicon: (replacements: [String: String], contacts: [String: String])?

    // MARK: - Field rules

    private var assistanceAllowed: Bool {
        guard !field.isDigitPad else { return false }
        let blocked: [UITextContentType] = [.oneTimeCode, .password, .newPassword, .creditCardNumber,
                                             .telephoneNumber, .postalCode]
        if let type = proxy?.textContentType ?? nil, blocked.contains(type) { return false }
        return true
    }

    private var autocorrectAllowed: Bool {
        preferences.autocorrect && assistanceAllowed && proxy?.autocorrectionType != .no
            && ![.URL, .emailAddress, .webSearch, .twitter].contains(field.keyboardType)
    }

    private func shouldCapitalize(_ before: String) -> Bool {
        guard preferences.autocapitalize else { return false }
        let atBoundary = before.isEmpty || before.last!.isWhitespace
        switch proxy?.autocapitalizationType ?? .sentences {
        case .none: return false
        case .allCharacters: return true
        case .words: return atBoundary
        default: return atBoundary && TypingEngine.context(before: before).sentenceStart
        }
    }

    // MARK: - Refresh

    func refresh() {
        guard let proxy else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        if shift != .locked, shiftIsAuto, !shiftHeld {
            let wanted: ShiftState = shouldCapitalize(before) ? .once : .off
            if shift != wanted { shift = wanted }
        }
        returnEnabled = !(proxy.enablesReturnKeyAutomatically ?? false) || proxy.hasText
        suggestions = currentSuggestions(before)
    }

    private func currentSuggestions(_ before: String) -> [Suggestion] {
        guard preferences.predictions, assistanceAllowed, let engine else { return [] }
        let context = TypingEngine.context(before: before)
        if let slid, context.partial == slid.word, pendingSpace {
            return slid.alternates.prefix(3).map { Suggestion(text: $0, kind: .word) }
        }
        if let corrected, context.partial == corrected.replacement {
            return [Suggestion(text: corrected.original, kind: .typed), Suggestion(text: corrected.replacement, kind: .word)]
        }
        var result = engine.suggest(context, autocorrect: autocorrectAllowed, spellGuesses: guesses).suggestions
        if context.partial.isEmpty {
            result = result.map { Suggestion(text: cased($0.text), kind: $0.kind) }
        }
        return result
    }

    private func guesses(_ word: String) -> [String] {
        checker.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word, language: "en_US") ?? []
    }

    private func cased(_ word: String) -> String {
        switch shift {
        case .off: return word
        case .once: return word.prefix(1).uppercased() + word.dropFirst()
        case .locked: return word.uppercased()
        }
    }

    // MARK: - Keys

    /// Kept and prepared: a generator made for one tap often fires before
    /// the haptic engine is ready, and the tap is lost.
    private var haptic: UIImpactFeedbackGenerator?

    func keyDown(_ key: KeySpec) {
        if key.action == .shift { shiftHeld = true }
        if preferences.keySound {
            // The iOS keyboard's own click, delete and modifier sounds. They
            // follow the ring/silent switch. `playInputClick` stays silent
            // here: it works only from the keyboard's root input view.
            switch key.action {
            case .insert, .space: AudioServicesPlaySystemSound(1104)
            case .delete: AudioServicesPlaySystemSound(1155)
            default: AudioServicesPlaySystemSound(1156)
            }
        }
        // iOS allows keyboard haptics only with Full Access.
        if preferences.haptics, controller?.hasFullAccess == true {
            if haptic == nil { haptic = UIImpactFeedbackGenerator(style: .light) }
            haptic?.impactOccurred()
            haptic?.prepare()
        }
    }

    func keyTapped(_ key: KeySpec, text: String?) {
        switch key.action {
        case .insert(let character): insert(text ?? character)
        case .space: space()
        case .returnKey:
            applyAutocorrection()
            proxy?.insertText("\n")
            finishEdit()
        case .delete: delete(words: false)
        case .shift: shiftTapped()
        case .page(let target): page = target
        case .emoji: showsEmoji = true
        case .globe: break
        }
    }

    func deleteRepeated(words: Bool) { delete(words: words) }

    func shiftReleased() {
        shiftHeld = false
        if typedWhileShiftHeld, shift == .once { shift = .off; shiftIsAuto = true }
        typedWhileShiftHeld = false
    }

    private func shiftTapped() {
        let now = Date()
        if shift == .locked {
            shift = .off
        } else if let last = lastShiftTap, now.timeIntervalSince(last) < 0.35 {
            shift = .locked
        } else {
            shift = shift == .off ? .once : .off
        }
        lastShiftTap = now
        shiftIsAuto = false
        refreshSuggestionCase()
    }

    private func refreshSuggestionCase() {
        guard let before = proxy?.documentContextBeforeInput else { return }
        suggestions = currentSuggestions(before)
    }

    func insert(_ character: String) {
        guard let proxy else { return }
        typedSinceAppear = true
        corrected = nil
        let first = character.first
        let startsWord = first.map { $0.isLetter || $0.isNumber || "([{\"“#@".contains($0) } ?? false
        if pendingSpace, startsWord { proxy.insertText(" ") }
        pendingSpace = false
        slid = nil
        if let first, ".,!?;:)]}\"”".contains(first) { applyAutocorrection() }
        let isLetter = character.count == 1 && first?.isLetter == true
        proxy.insertText(isLetter && shift != .off ? character.uppercased() : character)
        if isLetter, shift == .once {
            if shiftHeld { typedWhileShiftHeld = true } else { shift = .off; shiftIsAuto = true }
        }
        if page != .letters, page != .digits, character == "'" { page = .letters }
        lastSpaceAt = nil
        refresh()
    }

    func insertEmoji(_ emoji: String) {
        guard let proxy else { return }
        typedSinceAppear = true
        if pendingSpace { proxy.insertText(" ") }
        pendingSpace = false
        slid = nil
        proxy.insertText(emoji)
        refresh()
    }

    private func space() {
        guard let proxy else { return }
        typedSinceAppear = true
        defer { if page == .numbers || page == .symbols { page = .letters } }
        if pendingSpace {
            pendingSpace = false
            slid = nil
            proxy.insertText(" ")
            finishEdit()
            return
        }
        slid = nil
        let before = proxy.documentContextBeforeInput ?? ""
        let now = Date()
        if preferences.periodShortcut, let last = lastSpaceAt, now.timeIntervalSince(last) < 0.6,
           before.hasSuffix(" "), let previous = before.dropLast().last, previous.isLetter || previous.isNumber {
            proxy.deleteBackward()
            proxy.insertText(". ")
            lastSpaceAt = nil
            finishEdit()
            return
        }
        if !applyAutocorrection() { learn(TypingEngine.context(before: before).partial, strongly: false) }
        proxy.insertText(" ")
        lastSpaceAt = now
        shiftIsAuto = true
        refresh()
    }

    /// Replaces the word before the cursor with the bar's autocorrection.
    @discardableResult
    private func applyAutocorrection() -> Bool {
        guard autocorrectAllowed, let proxy,
              let correction = suggestions.first(where: { $0.kind == .autocorrection || $0.kind == .replacement }) else { return false }
        let partial = TypingEngine.context(before: proxy.documentContextBeforeInput ?? "").partial
        guard !partial.isEmpty, correction.text != partial else { return false }
        for _ in partial { proxy.deleteBackward() }
        proxy.insertText(correction.text)
        corrected = (partial, correction.text)
        return true
    }

    private func delete(words: Bool) {
        guard let proxy else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        if let slid, pendingSpace, before.hasSuffix(slid.word) {
            for _ in 0..<(slid.word.count + (slid.leadingSpace ? 1 : 0)) { proxy.deleteBackward() }
            self.slid = nil
            pendingSpace = false
            finishEdit()
            return
        }
        // Delete right after an autocorrection puts back what was typed and
        // keeps it, as Gboard does, instead of leaving the correction.
        if !words, let corrected, before.hasSuffix(corrected.replacement + " ") {
            for _ in 0...corrected.replacement.count { proxy.deleteBackward() }
            proxy.insertText(corrected.original)
            learn(corrected.original, strongly: true)
            self.corrected = nil
            finishEdit()
            return
        }
        pendingSpace = false
        slid = nil
        if words {
            var count = 0
            var index = before.endIndex
            while index > before.startIndex, before[before.index(before: index)].isWhitespace {
                index = before.index(before: index); count += 1
            }
            while index > before.startIndex, !before[before.index(before: index)].isWhitespace {
                index = before.index(before: index); count += 1
            }
            for _ in 0..<max(count, 1) { proxy.deleteBackward() }
        } else {
            proxy.deleteBackward()
        }
        finishEdit()
    }

    private func finishEdit() {
        lastSpaceAt = nil
        shiftIsAuto = shift != .locked
        refresh()
    }

    // MARK: - Suggestions

    func pick(_ suggestion: Suggestion) {
        guard let proxy else { return }
        typedSinceAppear = true
        let before = proxy.documentContextBeforeInput ?? ""
        let partial = TypingEngine.context(before: before).partial
        if let slid, pendingSpace, before.hasSuffix(slid.word) {
            for _ in slid.word { proxy.deleteBackward() }
            proxy.insertText(suggestion.text)
            self.slid = (suggestion.text, [slid.word] + slid.alternates.filter { $0 != suggestion.text }, slid.leadingSpace)
            refresh()
            return
        }
        if partial.isEmpty {
            let needsSpace = !(before.isEmpty || before.last!.isWhitespace || "([{\"“".contains(before.last!))
            proxy.insertText((needsSpace ? " " : "") + suggestion.text + " ")
        } else {
            for _ in partial { proxy.deleteBackward() }
            proxy.insertText(suggestion.text + " ")
            if suggestion.kind == .typed { learn(suggestion.text, strongly: true) }
        }
        corrected = nil
        lastSpaceAt = nil
        shiftIsAuto = true
        if page == .numbers || page == .symbols { page = .letters }
        refresh()
    }

    // MARK: - Slide to type

    func swiped(_ points: [CGPoint]) {
        guard preferences.slideToType, page == .letters, let proxy, let engine, let classifier, let lexicon = Self.lexicon else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        let context = TypingEngine.context(before: before + " ")
        let extra = Array(engine.user.dictionary.values) + Array(engine.user.contacts.values)
            + engine.user.learned.values.filter { $0.count >= UserWords.knownAfter }.map(\.display)
        let words = classifier.classify(points, lexicon: lexicon, extra: extra,
                                        prior: engine.swipePrior(previous: context.previous))
        guard !words.isEmpty else { return }
        typedSinceAppear = true
        corrected = nil
        let capitalize = shift == .once || (shouldCapitalize(before + " ") && shift != .locked && shiftIsAuto)
        func style(_ word: String) -> String {
            shift == .locked ? word.uppercased() : (capitalize ? word.prefix(1).uppercased() + word.dropFirst() : word)
        }
        let needsSpace = pendingSpace || !(before.isEmpty || before.last!.isWhitespace || "([{\"“".contains(before.last!))
        let word = style(words[0])
        proxy.insertText((needsSpace ? " " : "") + word)
        slid = (word, words.dropFirst().map(style), needsSpace)
        pendingSpace = true
        if shift == .once { shift = .off }
        shiftIsAuto = true
        lastSpaceAt = nil
        refresh()
    }

    func cursorMoved(by offset: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: offset)
        pendingSpace = false
        slid = nil
    }

    // MARK: - Learning

    private static let learnedKey = "typing.learnedWords"
    private static let clearedKey = "typing.learningClearedAt"

    /// Learned words live in the keyboard's own defaults so typing learns
    /// without Full Access; a reset from the app arrives as a date.
    private func loadUserWords() {
        guard engine != nil else { return }
        let defaults = UserDefaults.standard
        if let reset = preferences.learningResetAt,
           reset.timeIntervalSince1970 > defaults.double(forKey: Self.clearedKey) {
            defaults.removeObject(forKey: Self.learnedKey)
            defaults.set(reset.timeIntervalSince1970, forKey: Self.clearedKey)
        }
        if let data = defaults.data(forKey: Self.learnedKey),
           let learned = try? JSONDecoder().decode([String: UserWords.Entry].self, from: data) {
            engine?.user.learned = learned
        }
        var dictionary: [String: String] = [:]
        for word in SharedStore.shared.dictionaryWords where !word.contains(" ") {
            dictionary[TypingEngine.key(of: word)] = word
        }
        engine?.user.dictionary = dictionary
        if let pendingLexicon {
            engine?.replacements = pendingLexicon.replacements
            engine?.user.contacts = pendingLexicon.contacts
        }
    }

    private func learn(_ word: String, strongly: Bool) {
        guard var engine, word.count > 1, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return }
        let key = TypingEngine.key(of: word)
        guard strongly || !engine.isKnown(word, key: key) else { return }
        var entry = engine.user.learned[key] ?? UserWords.Entry(display: word, count: 0)
        entry.count = strongly ? max(entry.count + 1, UserWords.knownAfter) : entry.count + 1
        entry.display = word
        engine.user.learned[key] = entry
        if engine.user.learned.count > 3000, let rarest = engine.user.learned.min(by: { $0.value.count < $1.value.count })?.key {
            engine.user.learned[rarest] = nil
        }
        self.engine = engine
        if let data = try? JSONEncoder().encode(engine.user.learned) {
            UserDefaults.standard.set(data, forKey: Self.learnedKey)
        }
    }
}
