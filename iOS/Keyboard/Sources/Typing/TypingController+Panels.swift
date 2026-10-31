import UIKit
import VoiceIQBridge

/// What an undo step groups: a word typed, a run of deletes, or one action.
enum EditKind { case typing, deleting, other }

enum CursorMove { case left, right, wordLeft, wordRight, lineStart, lineEnd }

/// Emoji search, blocked words, delete slides and the edit panel.
extension TypingController {
    // MARK: - Emoji search

    func startEmojiSearch() {
        showsEmoji = false
        page = .letters
        emojiQuery = ""
    }

    func closeEmojiSearch() {
        emojiQuery = nil
        showsEmoji = true
    }

    /// While searching, the keys type into the query.
    func searchKeyTapped(_ key: KeySpec, text: String?) {
        guard var query = emojiQuery else { return }
        switch key.action {
        case .insert(let character): query += (text ?? character).lowercased()
        case .space: query += " "
        case .delete: if !query.isEmpty { query.removeLast() }
        case .returnKey, .emoji: return closeEmojiSearch()
        case .page(let target): page = target
        case .shift, .globe: break
        }
        emojiQuery = query
    }

    // MARK: - Blocked words

    private static let localBlockedKey = "typing.blockedWords"

    /// Blocked in the app, and here without Full Access, where the app's
    /// list cannot be written.
    var blockedWords: Set<String> {
        Set(preferences.blockedWords).union(UserDefaults.standard.stringArray(forKey: Self.localBlockedKey) ?? [])
    }

    /// Words blocked before Full Access move to the app's list, where
    /// Settings can unblock them.
    func adoptLocalBlocks() {
        guard controller?.hasFullAccess == true,
              let local = UserDefaults.standard.stringArray(forKey: Self.localBlockedKey), !local.isEmpty else { return }
        var shared = SharedStore.shared.keyboardPreferences
        shared.blockedWords += local.filter { !shared.blockedWords.contains($0) }
        SharedStore.shared.keyboardPreferences = shared
        preferences.blockedWords = shared.blockedWords
        UserDefaults.standard.removeObject(forKey: Self.localBlockedKey)
    }

    /// Holding a suggested word offers to block it; typed letters and
    /// Text Replacements are the user's own.
    func offerBlock(_ suggestion: Suggestion) {
        guard suggestion.kind == .word || suggestion.kind == .autocorrection else { return }
        blockOffer = suggestion.text
    }

    /// The word is never suggested, corrected to or slid to again, and is
    /// forgotten if it was learned.
    func block(_ word: String) {
        let key = TypingEngine.key(of: word)
        if controller?.hasFullAccess == true {
            var shared = SharedStore.shared.keyboardPreferences
            if !shared.blockedWords.contains(key) { shared.blockedWords.append(key) }
            SharedStore.shared.keyboardPreferences = shared
            preferences.blockedWords = shared.blockedWords
        } else {
            let local = UserDefaults.standard.stringArray(forKey: Self.localBlockedKey) ?? []
            UserDefaults.standard.set(local + [key], forKey: Self.localBlockedKey)
        }
        if var engine {
            LearnedWords.forget(key, in: &engine.user)
            if controller?.hasFullAccess == true { LearnedWords.publish(engine.user) }
            self.engine = engine
        }
        blockOffer = nil
        syncSwipeWords()
        refresh()
    }

    // MARK: - Delete slide

    /// The press already deleted a character, a word or a held run; the
    /// slide starts by putting that back, so sliding back to the key undoes
    /// everything.
    func deleteSlideBegan() {
        guard emojiQuery == nil, let proxy, let restore = deleteRestore else { return }
        for _ in 0..<restore.remove { proxy.deleteBackward() }
        if !restore.append.isEmpty { proxy.insertText(restore.append) }
        deleteRestore = nil
        deleteSlide = (proxy.documentContextBeforeInput ?? "", 0)
    }

    /// Removes `steps` words or characters from where the slide began,
    /// putting back what a slide back to the right no longer covers.
    func deleteSlid(steps: Int) {
        guard let proxy, let slide = deleteSlide else { return }
        let characters = Array(slide.source)
        let target = preferences.deleteSlide == .characters ? min(steps, characters.count) : Self.length(ofLast: steps, wordsIn: characters)
        if target > slide.removed {
            for _ in slide.removed..<target { proxy.deleteBackward() }
        } else if target < slide.removed {
            proxy.insertText(String(characters[(characters.count - slide.removed)..<(characters.count - target)]))
        }
        deleteSlide?.removed = target
    }

    func deleteSlideEnded() {
        deleteSlide = nil
        slid = nil
        pendingSpace = false
        finishEdit()
    }

    private static func length(ofLast words: Int, wordsIn characters: [Character]) -> Int {
        var index = characters.count
        for _ in 0..<words {
            while index > 0, characters[index - 1].isWhitespace { index -= 1 }
            while index > 0, !characters[index - 1].isWhitespace { index -= 1 }
        }
        return characters.count - index
    }

    // MARK: - Edit panel

    func moveCursor(_ move: CursorMove) {
        guard let proxy else { return }
        let before = Array(proxy.documentContextBeforeInput ?? "")
        let after = Array(proxy.documentContextAfterInput ?? "")
        let offset: Int
        switch move {
        case .left: offset = before.isEmpty ? 0 : -1
        case .right: offset = after.isEmpty ? 0 : 1
        case .wordLeft: offset = -Self.length(ofLast: 1, wordsIn: before)
        case .wordRight: offset = Self.length(ofLast: 1, wordsIn: after.reversed())
        case .lineStart: offset = -(before.lastIndex(of: "\n").map { before.count - $0 - 1 } ?? before.count)
        case .lineEnd: offset = after.firstIndex(of: "\n") ?? after.count
        }
        guard offset != 0 else { return }
        proxy.adjustTextPosition(byCharacterOffset: offset)
        pendingSpace = false
        slid = nil
        lastEdit = nil
        editGeneration &+= 1
    }

    var hasSelection: Bool { !(proxy?.selectedText ?? "").isEmpty }

    /// The pasteboard needs Full Access.
    var canUsePasteboard: Bool { controller?.hasFullAccess == true }

    func copySelection(cut: Bool) {
        guard canUsePasteboard, let proxy, let text = proxy.selectedText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        guard cut else { return }
        checkpoint(.other)
        proxy.deleteBackward()
        finishEdit()
    }

    func paste() {
        guard canUsePasteboard, let proxy, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        checkpoint(.other)
        if pendingSpace { proxy.insertText(" ") }
        pendingSpace = false
        slid = nil
        proxy.insertText(text)
        finishEdit()
    }

    // MARK: - Undo

    /// Saves the text before the cursor when a new step starts: each word
    /// typed, each run of deletes, each other action. A selection the edit
    /// replaces counts as before the cursor, so undo puts it back.
    func checkpoint(_ kind: EditKind) {
        guard let proxy else { return }
        editGeneration &+= 1
        let before = proxy.documentContextBeforeInput ?? ""
        let state = before + (proxy.selectedText ?? "")
        let wordStart = before.isEmpty || before.last!.isWhitespace
        if kind == .other || kind != lastEdit || (kind == .typing && wordStart) {
            if undoStack.last != state { undoStack.append(state) }
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack = []
        }
        lastEdit = kind
    }

    func undo() {
        guard let target = undoStack.popLast() else { return }
        redoStack.append(proxy?.documentContextBeforeInput ?? "")
        restoreBefore(target)
    }

    func redo() {
        guard let target = redoStack.popLast() else { return }
        undoStack.append(proxy?.documentContextBeforeInput ?? "")
        restoreBefore(target)
    }

    private func restoreBefore(_ target: String) {
        replaceBefore(with: target)
        editGeneration &+= 1
        slid = nil
        pendingSpace = false
        corrected = nil
        lastEdit = nil
        finishEdit()
    }

    /// Edits the text before the cursor into `target`. Both are the text
    /// iOS shows before the cursor, which is cut short in long fields, so
    /// they may start at different places: line them up where they agree
    /// longest, one starting at its front, and edit only what follows.
    private func replaceBefore(with target: String) {
        guard let proxy else { return }
        let current = Array(proxy.documentContextBeforeInput ?? ""), target = Array(target)
        var kept = 0, from = 0, longest = -1
        for shift in -target.count...current.count {
            let c = max(shift, 0), t = max(-shift, 0)
            var run = 0
            while c + run < current.count, t + run < target.count, current[c + run] == target[t + run] { run += 1 }
            if run > longest || (run == longest && shift == 0) { (kept, from, longest) = (c + run, t + run, run) }
        }
        for _ in kept..<current.count { proxy.deleteBackward() }
        if from < target.count { proxy.insertText(String(target[from...])) }
    }
}
