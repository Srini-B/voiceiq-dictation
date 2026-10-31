import UIKit
import VoiceIQBridge

/// What an undo step groups: a word typed, a run of deletes, or one action.
enum EditKind { case typing, deleting, other }

/// An edit to the text before the cursor: delete `remove` characters,
/// then type `append`. Built from the exact text each keyboard edit removed
/// and typed, because iOS shows only part of a long field.
struct TextEdit: Equatable {
    var remove = 0
    var append = ""

    /// Adds an edit made after this one.
    mutating func add(removing count: Int, typing text: String) {
        if count <= append.count {
            append = String(append.dropLast(count)) + text
        } else {
            remove += count - append.count
            append = text
        }
    }

    /// Adds the reverse of an edit, that removed `deleted` and typed
    /// `inserted`, made after the edits this one reverses.
    mutating func addReverse(deleted: String, inserted: String) {
        if deleted.count <= remove {
            remove += inserted.count - deleted.count
        } else {
            append = String(deleted.dropLast(remove)) + append
            remove = inserted.count
        }
    }
}

/// One step of the edit panel: how to undo it and how to redo it.
struct UndoStep: Equatable {
    var undo = TextEdit()
    var redo = TextEdit()
}

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
        deleteRestore = nil
        apply(restore)
        deleteSlide = (proxy.documentContextBeforeInput ?? "", 0)
    }

    /// Removes `steps` words or characters from where the slide began,
    /// putting back what a slide back to the right no longer covers.
    func deleteSlid(steps: Int) {
        guard let slide = deleteSlide else { return }
        let characters = Array(slide.source)
        let target = preferences.deleteSlide == .characters ? min(steps, characters.count) : Self.length(ofLast: steps, wordsIn: characters)
        if target > slide.removed {
            deleteBack(target - slide.removed)
        } else if target < slide.removed {
            typeText(String(characters[(characters.count - slide.removed)..<(characters.count - target)]))
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
        deleteBack()
        finishEdit()
    }

    func paste() {
        guard canUsePasteboard, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        checkpoint(.other)
        if pendingSpace { typeText(" ") }
        pendingSpace = false
        slid = nil
        typeText(text)
        finishEdit()
    }

    // MARK: - Undo

    /// Starts a new undo step for each word typed, each run of deletes and
    /// each other action.
    func checkpoint(_ kind: EditKind) {
        guard let proxy else { return }
        editGeneration &+= 1
        if kind != .deleting { deleteRestore = nil }
        let before = proxy.documentContextBeforeInput ?? ""
        let wordStart = before.isEmpty || before.last!.isWhitespace
        if undoStack.isEmpty || kind == .other || kind != lastEdit || (kind == .typing && wordStart) {
            if undoStack.last != UndoStep() { undoStack.append(UndoStep()) }
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack = []
        }
        lastEdit = kind
    }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        redoStack.append(step)
        replay(step.undo)
    }

    func redo() {
        guard let step = redoStack.popLast() else { return }
        undoStack.append(step)
        replay(step.redo)
    }

    private func replay(_ edit: TextEdit) {
        guard let proxy else { return }
        for _ in 0..<edit.remove { proxy.deleteBackward() }
        if !edit.append.isEmpty { proxy.insertText(edit.append) }
        deleteRestore = nil
        editGeneration &+= 1
        slid = nil
        pendingSpace = false
        corrected = nil
        lastEdit = nil
        finishEdit()
    }

    func apply(_ edit: TextEdit) {
        deleteBack(edit.remove)
        if !edit.append.isEmpty { typeText(edit.append) }
    }

    /// Types `text` over the selection, if any, and records the edit.
    func typeText(_ text: String) {
        guard let proxy else { return }
        record(deleted: proxy.selectedText ?? "", inserted: text)
        proxy.insertText(text)
    }

    /// Presses Delete `count` times and records what that removes: the
    /// selection first, if any, then the text before it.
    func deleteBack(_ count: Int = 1) {
        guard let proxy, count > 0 else { return }
        let selected = proxy.selectedText ?? ""
        let before = proxy.documentContextBeforeInput ?? ""
        record(deleted: String(before.suffix(selected.isEmpty ? count : count - 1)) + selected, inserted: "")
        for _ in 0..<count { proxy.deleteBackward() }
    }

    private func record(deleted: String, inserted: String) {
        if !undoStack.isEmpty {
            undoStack[undoStack.count - 1].undo.addReverse(deleted: deleted, inserted: inserted)
            undoStack[undoStack.count - 1].redo.add(removing: deleted.count, typing: inserted)
        }
        deleteRestore?.addReverse(deleted: deleted, inserted: inserted)
    }
}
