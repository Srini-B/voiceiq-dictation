import UIKit

/// A dictation's transcript in the field as marked text while the writing
/// model rewrites it (`SessionSnapshot.draft`), then swapped for the
/// written text. Hosts draw marked text underlined, which is the draft's
/// underline. Only the draft's own text is ever replaced: once the field
/// changed around it, or it is no longer right before the cursor, it stays
/// as heard.
@MainActor
final class KeyboardDraft {
    /// Fits a text to the text before and after the cursor
    /// (`SurroundingText.fitted`), the same for the draft and the written text.
    typealias Fit = (_ text: String, _ before: String, _ after: String) -> String

    enum Swap: Equatable {
        /// The draft, right before the cursor, was deleted and the written
        /// text typed.
        case retyped(String)
        /// The draft can't be found for certain. It stays as it is.
        case kept
    }

    let id: UUID
    /// The input session it was typed in.
    let documentID: UUID
    /// The transcript as it went in, fitted to the text around it.
    let text: String
    /// The text before and after the cursor when it went in.
    let before: String
    let after: String
    let typedAt: Date
    /// Still marked text, as far as this keyboard knows.
    private(set) var isMarked = true
    /// The text before the cursor once the draft was first seen there
    /// (`follow`). Any change after that is someone's edit.
    private var landedBefore: String?
    private init(id: UUID, documentID: UUID, text: String, before: String, after: String, typedAt: Date) {
        self.id = id
        self.documentID = documentID
        self.text = text
        self.before = before
        self.after = after
        self.typedAt = typedAt
    }

    /// Types `transcript` at the cursor as marked text. Nil over a selection,
    /// and for a draft that could not be swapped (`canSwap`): the written
    /// text then goes in alone.
    static func type(_ transcript: String, id: UUID, documentID: UUID, into proxy: UITextDocumentProxy,
                     fit: Fit, now: Date = Date()) -> KeyboardDraft? {
        guard (proxy.selectedText ?? "").isEmpty else { return nil }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        // A field with text it doesn't show can't be checked at the swap.
        guard !(before.isEmpty && after.isEmpty && proxy.hasText) else { return nil }
        let fitted = fit(transcript, before, after)
        guard canSwap(fitted) else { return nil }
        proxy.setMarkedText(fitted, selectedRange: NSRange(location: fitted.utf16.count, length: 0))
        let draft = KeyboardDraft(id: id, documentID: documentID, text: fitted, before: before, after: after,
                                  typedAt: now)
        // Read right after this keyboard's own write, so nothing else can
        // have changed the field: a host that shows the draft at once, also
        // with less of the text before it, has it recorded here.
        let current = proxy.documentContextBeforeInput ?? ""
        if current.hasSuffix(fitted), (proxy.documentContextAfterInput ?? "") == after,
           before.hasSuffix(current.dropLast(fitted.count)) {
            draft.landedBefore = current
        }
        return draft
    }

    /// Whether a draft of `text` could be swapped later. The swap deletes
    /// it one key at a time and must see all of it before the cursor, so a
    /// draft is typed only when its characters are single code points (a
    /// host may delete a Tamil or Devanagari vowel sign, or part of an
    /// emoji, on its own), it has no line break and it is short enough for
    /// hosts that show only the last sentence or so before the cursor.
    /// Otherwise the written text goes in once, as before drafts.
    static func canSwap(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxLength && text.unicodeScalars.count == text.count
            && !text.contains(where: \.isNewline)
    }

    static let maxLength = 200

    /// Makes the marked draft plain text, as heard: the keyboard is going,
    /// or the user edits with it.
    func commit(_ proxy: UITextDocumentProxy) {
        guard isMarked else { return }
        isMarked = false
        proxy.unmarkText()
    }

    /// Watches the field while the writer runs. False once the field changed
    /// after the draft was seen in it: the host or the user edited it
    /// without this keyboard (a menu's Cut, the host's own undo), and the
    /// text around the cursor could match an earlier copy of its words.
    func follow(_ proxy: UITextDocumentProxy) -> Bool {
        let current = proxy.documentContextBeforeInput ?? ""
        if let landedBefore {
            return current == landedBefore && (proxy.documentContextAfterInput ?? "") == after
                && (proxy.selectedText ?? "").isEmpty
        }
        if current.hasSuffix(text), isStillAround(proxy, before: current) { landedBefore = current }
        return true
    }

    /// Swaps the draft for `written`, only while it is right before the
    /// cursor with nothing selected and the same text around it. A host can
    /// commit marked text without saying so, and marked text set over it
    /// would then go in beside it, so the draft is always committed first and
    /// swapped as plain text. Anything else keeps it.
    func replace(with written: String, in proxy: UITextDocumentProxy, fit: Fit) -> Swap {
        commit(proxy)
        let current = proxy.documentContextBeforeInput ?? ""
        guard (proxy.selectedText ?? "").isEmpty, current.hasSuffix(text), isStillAround(proxy, before: current),
              Self.canSwap(text)
        else { return .kept }
        let fitted = fit(written, String(current.dropLast(text.count)), proxy.documentContextAfterInput ?? "")
        guard !fitted.isEmpty else { return .kept }
        for _ in 0..<text.count { proxy.deleteBackward() }
        proxy.insertText(fitted)
        return .retyped(fitted)
    }

    /// The text around the cursor is still the text around the draft: the
    /// same text after it, and the text before the draft ending as it did.
    /// An earlier copy of the same words, with the cursor moved to it, has
    /// other text around it and is never taken for the draft.
    private func isStillAround(_ proxy: UITextDocumentProxy, before current: String) -> Bool {
        guard (proxy.documentContextAfterInput ?? "") == after else { return false }
        // Exactly the text that was before it: a host that shows less of it
        // now could be showing an earlier copy of the draft's words left by
        // an edit nobody saw. Such hosts swap only a draft seen as it was
        // typed (`landedBefore`).
        if let landedBefore { return current == landedBefore }
        return String(current.dropLast(text.count)) == before
    }
}
