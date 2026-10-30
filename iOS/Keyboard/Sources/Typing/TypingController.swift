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
    private let swipe = SwipeRecognizer()
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
    /// Every suggestion for the word at the cursor, shown or not.
    private var candidates: [Suggestion] = []
    /// The text around the cursor after the keyboard's last edit. Not
    /// `documentIdentifier`: Swift declares it non-optional, iOS returns nil,
    /// and reading it crashes the keyboard (0.6.16).
    private var lastBefore: String?
    private var lastAfter: String?

    // MARK: - Lifecycle

    func appeared() {
        preferences = SharedStore.shared.keyboardPreferences
        loadUserWords()
        if preferences.slideToType, let geometry = engine?.geometry { swipe.update(geometry) }
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
        if field.isDigitPad { page = .digits } else if page == .digits { page = .letters }
    }

    func geometryChanged(_ geometry: KeyGeometry) {
        guard let lexicon = Self.lexicon, engine?.geometry != geometry else { return }
        if engine == nil {
            engine = TypingEngine(lexicon: lexicon, geometry: geometry)
            loadUserWords()
        }
        engine?.geometry = geometry
        if preferences.slideToType { swipe.update(geometry) }
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
        syncSwipeWords()
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
        updateSuggestions(before)
        lastBefore = before
        lastAfter = proxy.documentContextAfterInput
    }

    /// The user moved the cursor or the app changed the text: a slid word or
    /// correction saved for the old position no longer applies.
    func selectionChanged() {
        if proxy?.documentContextBeforeInput != lastBefore || proxy?.documentContextAfterInput != lastAfter {
            slid = nil
            pendingSpace = false
            corrected = nil
        }
        refresh()
    }

    /// Corrections come from the same list as the bar, which Predictions
    /// only hides.
    private func updateSuggestions(_ before: String) {
        candidates = currentSuggestions(before)
        suggestions = preferences.predictions ? candidates : []
    }

    private func currentSuggestions(_ before: String) -> [Suggestion] {
        guard preferences.predictions || autocorrectAllowed, let engine, assistanceAllowed else { return [] }
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

    func keyDown(_ key: KeySpec) {
        if key.action == .shift { shiftHeld = true }
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
        updateSuggestions(before)
    }

    func insert(_ character: String) {
        guard let proxy else { return }
        typedSinceAppear = true
        corrected = nil
        let first = character.first
        let startsWord = first.map { $0.isLetter || $0.isNumber || "([{\"“#@".contains($0) } ?? false
        if pendingSpace, startsWord {
            learnPair(before: proxy.documentContextBeforeInput ?? "")
            proxy.insertText(" ")
        }
        pendingSpace = false
        slid = nil
        if let first, ".,!?;:)]}\"”".contains(first) {
            applyAutocorrection()
            learnPair(before: proxy.documentContextBeforeInput ?? "")
        }
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
            learnPair(before: proxy.documentContextBeforeInput ?? "")
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
        learnPair(before: proxy.documentContextBeforeInput ?? "")
        proxy.insertText(" ")
        lastSpaceAt = now
        shiftIsAuto = true
        refresh()
    }

    /// Replaces the word before the cursor with the bar's autocorrection.
    @discardableResult
    private func applyAutocorrection() -> Bool {
        guard autocorrectAllowed, let proxy,
              let correction = candidates.first(where: { $0.kind == .autocorrection || $0.kind == .replacement }) else { return false }
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
        learnPair(before: String((proxy.documentContextBeforeInput ?? "").dropLast()))
        corrected = nil
        lastSpaceAt = nil
        shiftIsAuto = true
        if page == .numbers || page == .symbols { page = .letters }
        refresh()
    }

    // MARK: - Slide to type

    func swiped(_ points: [CGPoint], times: [TimeInterval]) {
        guard preferences.slideToType, page == .letters, let proxy else { return }
        swipe.recognize(points, times: times, context: Self.contextWords(proxy.documentContextBeforeInput ?? "")) { [weak self] words in
            self?.insertSlid(words)
        }
    }

    /// The words before the cursor on its line, as FUTO Keyboard gives them.
    private static func contextWords(_ before: String) -> [String] {
        let line = before.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        return line.split { !($0.isLetter || $0.isNumber || $0 == "_") }.suffix(10).map(String.init)
    }

    private func insertSlid(_ found: [String]) {
        guard page == .letters, let proxy, let engine else { return }
        // The user's words come back as bare letters; give them their spelling.
        var seen = Set<String>()
        let words = found.map { $0 == $0.lowercased() ? engine.user.display(key: TypingEngine.key(of: $0)) ?? $0 : $0 }
            .filter { seen.insert($0.lowercased()).inserted }
        guard !words.isEmpty else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        typedSinceAppear = true
        corrected = nil
        let capitalize = shift == .once || (shouldCapitalize(before + " ") && shift != .locked && shiftIsAuto)
        func style(_ word: String) -> String {
            shift == .locked ? word.uppercased() : (capitalize ? word.prefix(1).uppercased() + word.dropFirst() : word)
        }
        if pendingSpace { learnPair(before: before) }
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

    /// A slide types a new word, so mid-word it may start only once the
    /// letters typed so far are a word: a slip while typing stays a tap.
    var canStartSwipe: Bool {
        let partial = TypingEngine.context(before: proxy?.documentContextBeforeInput ?? "").partial
        return partial.isEmpty || pendingSpace || engine?.isKnown(partial) == true
    }

    func cursorMoved(by offset: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: offset)
        pendingSpace = false
        slid = nil
    }

    // MARK: - Learning

    /// Learned words and pairs, the Dictionary, contacts and replacements;
    /// a reset from the app arrives as a date (`LearnedWords.load`).
    private func loadUserWords() {
        guard var loaded = engine else { return }
        LearnedWords.load(into: &loaded.user, resetAt: preferences.learningResetAt)
        engine = loaded
        if controller?.hasFullAccess == true { LearnedWords.publish(loaded.user) }
        var dictionary: [String: String] = [:]
        for word in SharedStore.shared.dictionaryWords where !word.contains(" ") {
            dictionary[TypingEngine.key(of: word)] = word
        }
        engine?.user.dictionary = dictionary
        if let pendingLexicon {
            engine?.replacements = pendingLexicon.replacements
            engine?.user.contacts = pendingLexicon.contacts
        }
        syncSwipeWords()
    }

    /// The Dictionary, contacts and known learned words, for slide to type.
    private func syncSwipeWords() {
        if let engine { swipe.setUserWords(engine.user.keys(prefix: "")) }
    }

    private func learn(_ word: String, strongly: Bool) {
        // Codes, card numbers and fields that opt out of correction are not learned.
        guard assistanceAllowed, proxy?.autocorrectionType != .no,
              var engine, word.count > 1, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return }
        // A learned word stays counted after it becomes known, so typing
        // alone can take it to the uses that send it to the Dictionary.
        let key = TypingEngine.key(of: word)
        guard strongly || !engine.isKnown(word) || engine.user.learned[key] != nil else { return }
        // A capital that only starts the sentence is not the word's: keep
        // "helo" as typed mid-sentence, and a name's saved spelling.
        var word = word
        let text = proxy?.documentContextBeforeInput ?? ""
        let context = TypingEngine.context(before: text.hasSuffix(" ") ? String(text.dropLast()) : text)
        if context.sentenceStart, TypingEngine.key(of: context.partial) == key,
           word.dropFirst() == word.dropFirst().lowercased() {
            word = engine.user.learned[key]?.display ?? word.lowercased()
        }
        if LearnedWords.learn(word, strongly: strongly, in: &engine.user), controller?.hasFullAccess == true {
            LearnedWords.publish(engine.user)
        }
        self.engine = engine
        syncSwipeWords()
    }

    /// Counts the word before the cursor as typed after the word before it,
    /// or at a sentence start, once the word is finished. Both must be words.
    private func learnPair(before text: String) {
        guard preferences.predictions, assistanceAllowed, proxy?.autocorrectionType != .no, var engine else { return }
        let context = TypingEngine.context(before: text)
        let word = context.partial
        guard !word.isEmpty, engine.isKnown(word) else { return }
        let previous: String
        if context.sentenceStart {
            previous = UserWords.sentenceStart
        } else if let before = context.previous, engine.isKnown(before) {
            previous = TypingEngine.key(of: before)
        } else {
            return
        }
        LearnedWords.learnPair(engine.spelling(of: word), after: previous, in: &engine.user)
        self.engine = engine
    }
}
