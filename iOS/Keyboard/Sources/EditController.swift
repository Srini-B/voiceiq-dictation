import UIKit

enum CursorMove { case left, right, wordLeft, wordRight, lineStart, lineEnd }

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

/// One undo step: how to undo it and how to redo it.
struct UndoStep: Equatable {
    var undo = TextEdit()
    var redo = TextEdit()
}

/// Every edit the keyboard makes to the field: the bottom row's keys, the
/// edit panel's cursor moves and pasteboard, a dictation typed in, and undo
/// of all of these. Keyboards cannot select text or reach the app's own undo.
@MainActor
final class EditController: ObservableObject {
    /// What an undo step groups: a run of spaces and returns, a run of
    /// deletes, or one other action (a paste, a cut, a dictation).
    enum Kind { case typing, deleting, other }

    /// The text selected in the field, reread after every edit, so the
    /// Dictionary offer ends with the selection.
    @Published private(set) var selection = ""
    @Published private(set) var undoStack: [UndoStep] = []
    @Published private(set) var redoStack: [UndoStep] = []

    weak var controller: UIInputViewController?
    /// Notifies Hex's keyboard when EditPanel or KeyboardModel edits the field directly.
    var onExternalEdit: (() -> Void)?
    /// Called before every edit, so a dictation's draft marked in the field
    /// (`KeyboardDraft`) becomes plain text first and the edit cannot
    /// replace it.
    var willEdit: (() -> Void)?
    /// Whether this run loop turn has a marked-text call in it
    /// (`KeyboardModel.markedTextThisTurn`).
    var markedTextThisTurn: (() -> Bool)?
    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }
    private var lastKind: Kind?
    /// The text around the cursor after the keyboard's last edit, to tell
    /// the app's own changes apart from the keyboard's.
    private var lastBefore: String?
    private var lastAfter: String?
    /// Groups same-turn deletes followed by a replacement insert (autocorrect)
    /// into one undo step without breaking ordinary Backspace runs.
    private var deletedThisTurn = false
    private var undoBeforeTurn: [UndoStep]?
    private var turnDeletes: [String] = []
    private var deleteTurn = 0

    /// The pasteboard needs Full Access.
    var canUsePasteboard: Bool { controller?.hasFullAccess == true }

    func appeared() {
        resetUndo()
        refresh()
    }

    func resetUndo() {
        undoStack = []
        redoStack = []
        lastKind = nil
        deletedThisTurn = false
        undoBeforeTurn = nil
        turnDeletes = []
    }

    func syncSelection() {
        refresh()
    }

    func cursorMovedExternally() {
        resetUndo()
        refresh()
    }

    /// A dictation that reached the field another way than `type`: a draft
    /// swapped for its written text (`KeyboardDraft`). It becomes one undo
    /// step, like a dictation typed in, which takes `inserted` back out
    /// from before the cursor.
    func recordDictation(inserted: String) {
        guard !inserted.isEmpty else { return }
        checkpoint(.other)
        record(deleted: "", inserted: inserted)
        refresh()
    }

    /// The user moved the cursor or the app changed the text: undo replays
    /// text before the cursor, which is no longer this text.
    func textChanged() {
        if proxy?.documentContextBeforeInput != lastBefore || proxy?.documentContextAfterInput != lastAfter {
            resetUndo()
        }
        refresh()
    }

    // MARK: - Keys

    /// Every edit starts here. The host applies a turn's inserts, Deletes
    /// and cursor moves before its marked-text calls, so an edit in the turn
    /// a draft was marked would land before the draft, and one in the turn a
    /// draft was made plain with `unmarkText` would replace it. In such a
    /// turn `edit` runs again on the next one and this returns false;
    /// otherwise a held draft is made plain first (`willEdit`), which may
    /// itself be such a call. `change` is what `edit` does to the text
    /// before the cursor, which `projected` counts until it runs.
    func runsNow(changing change: TextEdit? = nil, _ edit: @escaping @MainActor @Sendable () -> Void) -> Bool {
        if markedTextThisTurn?() != true { willEdit?() }
        guard markedTextThisTurn?() == true else { return true }
        if let change { waiting.append(change) }
        DispatchQueue.main.async { [weak self] in
            if change != nil { self?.waiting.removeFirst() }
            edit()
        }
        return false
    }

    /// Edits `runsNow` moved to the next turn, in order.
    private var waiting: [TextEdit] = []

    /// The text before the cursor as it will be once the edits waiting for
    /// the next turn are made. The keys read this between their own edits:
    /// a word-wise Delete reads the word to take after each word it took.
    /// It counts inserts and Deletes before the cursor only: a waiting cursor
    /// move, or a Delete over a selection, is not in it, and the selection
    /// and the text after the cursor are read as they are. Such an edit needs
    /// a key in the one turn of a marked-text call.
    func projected(_ before: String) -> String {
        waiting.reduce(before) { String($0.dropLast($1.remove)) + $1.append }
    }

    /// Types `text` over the selection, if any, as one undo step of `kind`.
    func type(_ text: String, as kind: Kind = .other) {
        guard !text.isEmpty, runsNow(changing: TextEdit(append: text), { [weak self] in self?.type(text, as: kind) }) else { return }
        checkpoint(kind)
        insert(text)
        refresh()
        onExternalEdit?()
    }

    func deleteBackward() {
        guard runsNow(changing: TextEdit(remove: 1), { [weak self] in self?.deleteBackward() }) else { return }
        checkpoint(.deleting)
        deleteBack()
        refresh()
        onExternalEdit?()
    }

    /// Insert driven by Hex's `FullKeyboardEngine` (already owns keyboard state).
    func typeFromKeyboard(_ text: String) {
        guard !text.isEmpty, runsNow(changing: TextEdit(append: text), { [weak self] in self?.typeFromKeyboard(text) }) else { return }
        let wordCharacter = text.count == 1 && (text.first?.isLetter == true || text.first?.isNumber == true)
        if deletedThisTurn {
            groupTurnDeletes()
            lastKind = .other
        } else {
            checkpoint(wordCharacter ? .typing : .other)
        }
        insert(text)
        refresh()
    }

    /// Delete driven by Hex's `FullKeyboardEngine`.
    func deleteFromKeyboard() {
        guard runsNow(changing: TextEdit(remove: 1), { [weak self] in self?.deleteFromKeyboard() }) else { return }
        if !deletedThisTurn {
            deletedThisTurn = true
            undoBeforeTurn = undoStack
            turnDeletes = []
            deleteTurn += 1
            let turn = deleteTurn
            DispatchQueue.main.async { [weak self] in
                guard let self, self.deleteTurn == turn else { return }
                self.deletedThisTurn = false
                self.undoBeforeTurn = nil
                self.turnDeletes = []
            }
        }
        checkpoint(.deleting)
        turnDeletes.append(deleteBackReturningDeleted())
        refresh()
    }

    private func groupTurnDeletes() {
        deletedThisTurn = false
        guard let prior = undoBeforeTurn else { return }
        undoBeforeTurn = nil
        let removed = turnDeletes
        turnDeletes = []
        undoStack = prior
        undoStack.append(UndoStep())
        if undoStack.count > 50 { undoStack.removeFirst() }
        for text in removed {
            record(deleted: text, inserted: "")
        }
    }

    func moveCursor(_ move: CursorMove) {
        // First: the offsets below count a draft's text once it is plain.
        guard let proxy, runsNow({ [weak self] in self?.moveCursor(move) }) else { return }
        let before = Array(proxy.documentContextBeforeInput ?? "")
        let after = Array(proxy.documentContextAfterInput ?? "")
        let offset: Int
        switch move {
        case .left: offset = before.isEmpty ? 0 : -1
        case .right: offset = after.isEmpty ? 0 : 1
        case .wordLeft: offset = -Self.length(ofLastWordIn: before)
        case .wordRight: offset = Self.length(ofLastWordIn: after.reversed())
        case .lineStart: offset = -(before.lastIndex(of: "\n").map { before.count - $0 - 1 } ?? before.count)
        case .lineEnd: offset = after.firstIndex(of: "\n") ?? after.count
        }
        guard offset != 0 else { return }
        proxy.adjustTextPosition(byCharacterOffset: offset)
        // Undo replays at the cursor, so a moved cursor drops it.
        resetUndo()
        refresh()
        onExternalEdit?()
    }

    func copySelection(cut: Bool) {
        guard canUsePasteboard, let text = proxy?.selectedText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        guard cut, runsNow({ [weak self] in self?.copySelection(cut: true) }) else { return }
        checkpoint(.other)
        deleteBack()
        refresh()
        onExternalEdit?()
    }

    func paste() {
        guard canUsePasteboard, let text = UIPasteboard.general.string else { return }
        type(text)
    }

    // MARK: - Undo

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
        guard let proxy, runsNow(changing: edit, { [weak self] in self?.replay(edit) }) else { return }
        for _ in 0..<edit.remove { proxy.deleteBackward() }
        if !edit.append.isEmpty { proxy.insertText(edit.append) }
        lastKind = nil
        refresh()
        onExternalEdit?()
    }

    /// Starts a new undo step unless this edit continues the last one.
    private func checkpoint(_ kind: Kind) {
        if undoStack.isEmpty || kind == .other || kind != lastKind {
            if undoStack.last != UndoStep() { undoStack.append(UndoStep()) }
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
        redoStack = []
        lastKind = kind
    }

    private func insert(_ text: String) {
        guard let proxy else { return }
        record(deleted: proxy.selectedText ?? "", inserted: text)
        proxy.insertText(text)
    }

    /// Presses Delete once and records what that removes: the selection, if
    /// any, or the character before the cursor.
    private func deleteBack() {
        _ = deleteBackReturningDeleted()
    }

    private func deleteBackReturningDeleted() -> String {
        guard let proxy else { return "" }
        let selected = proxy.selectedText ?? ""
        let deleted = selected.isEmpty ? String((proxy.documentContextBeforeInput ?? "").suffix(1)) : selected
        record(deleted: deleted, inserted: "")
        proxy.deleteBackward()
        return deleted
    }

    private func record(deleted: String, inserted: String) {
        guard !undoStack.isEmpty else { return }
        undoStack[undoStack.count - 1].undo.addReverse(deleted: deleted, inserted: inserted)
        undoStack[undoStack.count - 1].redo.add(removing: deleted.count, typing: inserted)
    }

    private func refresh() {
        guard let proxy else { return }
        let selected = proxy.selectedText ?? ""
        if selection != selected { selection = selected }
        lastBefore = proxy.documentContextBeforeInput
        lastAfter = proxy.documentContextAfterInput
    }

    /// The last word and the spaces after it.
    private static func length(ofLastWordIn characters: [Character]) -> Int {
        var index = characters.count
        while index > 0, characters[index - 1].isWhitespace { index -= 1 }
        while index > 0, !characters[index - 1].isWhitespace { index -= 1 }
        return characters.count - index
    }
}
