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

    /// Apps whose text fields were seen to take a draft and its swap as
    /// described above. In any other app the written text goes in alone, as
    /// before drafts: one that makes marked text plain on its own (a field
    /// that rewrites its text on every change) would show every dictation
    /// twice.
    static let verifiedHosts: Set<String> = ["com.apple.MobileSMS", "io.blue.voiceiq.ios"]

    let id: UUID
    /// The input session it was typed in.
    let documentID: UUID
    /// The transcript as it went in, fitted to the text around it.
    let text: String
    /// The text before and after the cursor when it went in.
    let before: String
    let after: String
    let typedAt: Date
    /// Marked text this keyboard has not yet replaced or made plain.
    private(set) var isMarked = true

    private init(id: UUID, documentID: UUID, text: String, before: String, after: String, typedAt: Date) {
        self.id = id
        self.documentID = documentID
        self.text = text
        self.before = before
        self.after = after
        self.typedAt = typedAt
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
        return KeyboardDraft(id: id, documentID: documentID, text: fitted, before: before, after: after, typedAt: now)
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
        if current == before { return true }
        // A host reports as much text before the cursor as it likes, so with
        // the draft in it the start of the earlier text may be cut off.
        return current.hasSuffix(text) && before.hasSuffix(String(current.dropLast(text.count)))
    }

    /// Replaces the draft with `written`, fitted to the text that was around
    /// the draft: one insert, the only write of this turn. A field that has
    /// changed keeps the draft as heard.
    func replace(with written: String, in proxy: UITextDocumentProxy, fit: Fit) -> Swap {
        guard isMarked else { return .kept }
        let fitted = fit(written, before, after)
        guard !fitted.isEmpty, isInPlace(proxy) else {
            keep(proxy, .alone)
            return .kept
        }
        isMarked = false
        proxy.insertText(fitted)
        return .replaced(fitted)
    }

    /// Makes the draft plain text, as heard. Before the keyboard's own edit
    /// that is an insert of its own text; in a field that has changed it is
    /// `unmarkText` even then, since a second copy of the draft could land
    /// anywhere.
    func keep(_ proxy: UITextDocumentProxy, _ commit: Commit) {
        guard isMarked else { return }
        isMarked = false
        if commit == .beforeEdit, isInPlace(proxy) {
            proxy.insertText(text)
        } else {
            proxy.unmarkText()
        }
    }
}
