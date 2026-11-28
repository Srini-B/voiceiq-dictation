import UIKit

/// A dictation's transcript in the field as marked text while the writing
/// model rewrites it (`SessionSnapshot.draft`), then replaced by the written
/// text. Hosts draw marked text underlined, which is the draft's underline.
///
/// A keyboard cannot see the field. What `documentContextBeforeInput` returns
/// is a copy this process keeps and edits call by call, while the host gets
/// one turn's calls as one batch and applies its insertions and deletions
/// before `unmarkText` and before new marked text, whatever order they were
/// called in; there, Delete on marked text removes all of it. After
/// `unmarkText` and Delete in one turn the copy had lost one character and
/// the field the whole draft, and they never agreed again (iOS 27 Simulator,
/// Messages; `activities/2026-11-28-iphone-draft-swap-by-insert.md`). So no
/// write is checked by reading the field, and Delete is never pressed on a
/// draft.
///
/// The draft stays marked from `type` until one last write:
/// - `replace` inserts the written text, which takes the place of the marked
///   text and of nothing else.
/// - `keep(_:.beforeEdit)` inserts the draft's own text the same way, when
///   the keyboard's own edit follows in the same turn: after `unmarkText`
///   that edit would reach the host first and replace or delete the draft.
/// - `keep(_:.alone)` calls `unmarkText`, when the keyboard writes nothing
///   else in that turn.
///
/// A dictation stopped while an earlier one's draft is still marked adds its
/// transcript to the same marked text (`add`): new marked text replaces the
/// old, so a second, separate draft would take the first one's place. Each
/// part's written text takes its place in the marked text as it comes, and
/// the whole goes in with one insert once every part has its written text.
///
/// Where a host made the draft plain text without telling the keyboard, an
/// insert lands beside it: its text is there twice, and no text is lost.
@MainActor
final class KeyboardDraft {
    /// Fits a text to the text before and after the cursor
    /// (`SurroundingText.fitted`), the same for the draft and the written text.
    typealias Fit = (_ text: String, _ before: String, _ after: String) -> String

    enum Swap: Equatable {
        /// One insert of the written text went in over the marked draft.
        case replaced(String)
        /// The written text took its part's place in the marked draft, which
        /// waits for the written text of a part before it.
        case waiting
        /// The field is no longer as the draft left it. It stays as heard.
        case kept
    }

    /// How a draft that stays as heard becomes plain text.
    enum Commit {
        /// The keyboard writes nothing else to the field in this turn.
        case alone
        /// The keyboard's own edit follows in this turn.
        case beforeEdit
    }

    /// One dictation's transcript in the draft, and its written text once
    /// it came.
    struct Part {
        let id: UUID
        let heard: String
        var written: String?
    }

    /// The dictations in the draft, in the order they were spoken.
    private(set) var parts: [Part]
    /// The input session it was typed in.
    let documentID: UUID
    /// The marked text in the field: each part, heard or written, fitted to
    /// the text before it.
    private(set) var text: String
    /// The text before and after the cursor when the first part went in.
    let before: String
    let after: String
    /// When the last part went in.
    private(set) var typedAt: Date
    /// Marked text this keyboard has not yet replaced or made plain.
    private(set) var isMarked = true

    private init(part: Part, documentID: UUID, text: String, before: String, after: String, typedAt: Date) {
        parts = [part]
        self.documentID = documentID
        self.text = text
        self.before = before
        self.after = after
        self.typedAt = typedAt
    }

    /// Whether the dictation `id` has a part in this draft.
    func holds(_ id: UUID?) -> Bool {
        parts.contains { $0.id == id }
    }

    /// Types `transcript` at the cursor as marked text. Nil over a selection,
    /// in a field that has text but shows none around the cursor (an edit
    /// there could not be noticed), and for a transcript with a line break:
    /// the written text then goes in alone.
    static func type(_ transcript: String, id: UUID, documentID: UUID, into proxy: UITextDocumentProxy,
                     fit: Fit, now: Date = Date()) -> KeyboardDraft? {
        guard (proxy.selectedText ?? "").isEmpty else { return nil }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        guard !(before.isEmpty && after.isEmpty && proxy.hasText) else { return nil }
        let fitted = fit(transcript, before, after)
        guard canType(fitted) else { return nil }
        proxy.setMarkedText(fitted, selectedRange: NSRange(location: fitted.utf16.count, length: 0))
        return KeyboardDraft(part: Part(id: id, heard: transcript), documentID: documentID, text: fitted,
                             before: before, after: after, typedAt: now)
    }

    /// Adds the next dictation's transcript to the end of the marked draft.
    /// False, and nothing typed, where `type` would type nothing, and in a
    /// field that is no longer as the draft left it.
    func add(_ transcript: String, id: UUID, to proxy: UITextDocumentProxy, fit: Fit, now: Date = Date()) -> Bool {
        guard isMarked, !holds(id), isInPlace(proxy) else { return false }
        let added = parts + [Part(id: id, heard: transcript)]
        let marked = Self.fitted(added, before: before, after: after, fit: fit)
        guard Self.canType(marked) else { return false }
        parts = added
        mark(marked, in: proxy)
        typedAt = now
        return true
    }

    /// A line break in marked text is the one shape not tried in any host (a
    /// one-line field may take it for Return). Any script and length is fine:
    /// the swap is one insert, not a Delete per character.
    static func canType(_ text: String) -> Bool {
        !text.isEmpty && !text.contains(where: \.isNewline)
    }

    /// Whether the field still looks as the draft left it: text in it,
    /// nothing selected, the same text after the cursor, and before it the
    /// text that was there, with or without the draft (the keyboard's copy
    /// leaves marked text out; a host's own report may have it in). Anything
    /// else is an edit made without this keyboard (a menu's Cut, Send, which
    /// empties the field), and an insert would land somewhere else.
    func isInPlace(_ proxy: UITextDocumentProxy) -> Bool {
        guard proxy.hasText, (proxy.selectedText ?? "").isEmpty,
              (proxy.documentContextAfterInput ?? "") == after else { return false }
        let current = proxy.documentContextBeforeInput ?? ""
        return current == before || reportsDraft(current)
    }

    /// Whether `current`, the proxy's text before the cursor, has the draft
    /// in it. A host reports as much text before the cursor as it likes, so
    /// the start of the earlier text may be cut off.
    private func reportsDraft(_ current: String) -> Bool {
        current.hasSuffix(text) && before.hasSuffix(String(current.dropLast(text.count)))
    }

    /// The text before the cursor as the field has it: the proxy's, with the
    /// marked draft it leaves out. The keys plan an edit from this text
    /// before they make it (autocorrect counts its Deletes, a word-wise move
    /// its offset), and set Shift from it; planned from the proxy's text
    /// alone, they would count from the word before the draft and, once the
    /// draft is plain, delete into it and into that word.
    func textBefore(_ proxy: UITextDocumentProxy) -> String {
        let current = proxy.documentContextBeforeInput ?? ""
        return isMarked && current == before ? current + text : current
    }

    /// Puts the written text of dictation `id` in its part's place. Once
    /// every part has its written text, the whole is one insert, the only
    /// write of this turn; until then the marked text shows the written
    /// parts in place of their transcripts. A field that has changed keeps
    /// the draft as heard.
    func replace(_ id: UUID, with written: String, in proxy: UITextDocumentProxy, fit: Fit) -> Swap {
        guard isMarked, let index = parts.firstIndex(where: { $0.id == id }) else { return .kept }
        var updated = parts
        updated[index].written = written
        let fitted = Self.fitted(updated, before: before, after: after, fit: fit)
        guard !written.isEmpty, !fitted.isEmpty, isInPlace(proxy) else {
            keep(proxy, .alone)
            return .kept
        }
        parts = updated
        guard parts.allSatisfy({ $0.written != nil }) else {
            mark(fitted, in: proxy)
            return .waiting
        }
        isMarked = false
        proxy.insertText(fitted)
        return .replaced(fitted)
    }

    /// Makes the draft plain text, as it is in the field. Before the
    /// keyboard's own edit that is an insert of its own text; in a field that
    /// has changed it is `unmarkText` even then, since a second copy of the
    /// draft could land anywhere. True when it called `unmarkText`.
    @discardableResult
    func keep(_ proxy: UITextDocumentProxy, _ commit: Commit) -> Bool {
        guard isMarked else { return false }
        isMarked = false
        if commit == .beforeEdit, isInPlace(proxy) {
            proxy.insertText(text)
            return false
        }
        proxy.unmarkText()
        return true
    }

    /// New marked text in place of the old (a host replaces marked text with
    /// marked text), the cursor at its end.
    private func mark(_ marked: String, in proxy: UITextDocumentProxy) {
        proxy.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0))
        text = marked
    }

    /// The parts, each fitted to the text before it; only the last is fitted
    /// to the text after the draft.
    private static func fitted(_ parts: [Part], before: String, after: String, fit: Fit) -> String {
        var text = ""
        for (index, part) in parts.enumerated() {
            text += fit(part.written ?? part.heard, before + text, index == parts.count - 1 ? after : "")
        }
        return text
    }
}
