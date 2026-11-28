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
        /// The marked draft became the written text in place.
        case replacedMarked(String)
        /// The draft was plain text right before the cursor: it was deleted
        /// and the written text typed.
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
    /// Something changed the field after the draft went in. The host may
    /// have committed the marked text meanwhile, so it is no longer replaced
    /// as marked text.
    private(set) var touched = false

    /// The host reports the keyboard's own change within this.
    static let landingGrace: TimeInterval = 0.5

    private init(id: UUID, documentID: UUID, text: String, before: String, after: String, typedAt: Date) {
        self.id = id
        self.documentID = documentID
        self.text = text
        self.before = before
        self.after = after
        self.typedAt = typedAt
    }

    /// Types `transcript` at the cursor as marked text. Nil over a selection,
    /// which the written text replaces alone, and when nothing is left to type.
    static func type(_ transcript: String, id: UUID, documentID: UUID, into proxy: UITextDocumentProxy,
                     fit: Fit, now: Date = Date()) -> KeyboardDraft? {
        guard (proxy.selectedText ?? "").isEmpty else { return nil }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        let fitted = fit(transcript, before, after)
        guard !fitted.isEmpty else { return nil }
        proxy.setMarkedText(fitted, selectedRange: NSRange(location: fitted.utf16.count, length: 0))
        return KeyboardDraft(id: id, documentID: documentID, text: fitted, before: before, after: after, typedAt: now)
    }

    /// The controller saw the text or the selection change. Past the grace
    /// for the draft's own landing, any change counts as the user's.
    func fieldChanged(_ proxy: UITextDocumentProxy, now: Date = Date()) {
        guard !touched else { return }
        let landing = now.timeIntervalSince(typedAt) < Self.landingGrace
        if !landing || !(readsAsTyped(proxy) || readsAsBefore(proxy)) { touched = true }
    }

    /// Makes the marked draft plain text, as heard: the keyboard is going,
    /// or the user edits with it.
    func commit(_ proxy: UITextDocumentProxy) {
        touched = true
        guard isMarked else { return }
        isMarked = false
        proxy.unmarkText()
    }

    /// Swaps the draft for `written`: in place while it is still the marked
    /// text the keyboard left; otherwise only while it is plain text right
    /// before the cursor with nothing selected. Anything else keeps it.
    func replace(with written: String, in proxy: UITextDocumentProxy, fit: Fit) -> Swap {
        if isMarked, !touched, readsAsTyped(proxy, allowingCutWindow: true) {
            let fitted = fit(written, before, after)
            guard !fitted.isEmpty else {
                commit(proxy)
                return .kept
            }
            isMarked = false
            proxy.setMarkedText(fitted, selectedRange: NSRange(location: fitted.utf16.count, length: 0))
            proxy.unmarkText()
            return .replacedMarked(fitted)
        }
        commit(proxy)
        let current = proxy.documentContextBeforeInput ?? ""
        guard (proxy.selectedText ?? "").isEmpty, current.hasSuffix(text), isStillAround(proxy, before: current)
        else { return .kept }
        let fitted = fit(written, String(current.dropLast(text.count)), proxy.documentContextAfterInput ?? "")
        guard !fitted.isEmpty else { return .kept }
        for _ in 0..<text.count { proxy.deleteBackward() }
        proxy.insertText(fitted)
        return .retyped(fitted)
    }

    /// The field reads as the draft left it: the draft right before the
    /// cursor, nothing selected, the same text after. A host that shows only
    /// part of the field may show only the draft's end
    /// (`allowingCutWindow`), never an empty window.
    private func readsAsTyped(_ proxy: UITextDocumentProxy, allowingCutWindow: Bool = false) -> Bool {
        guard (proxy.selectedText ?? "").isEmpty, (proxy.documentContextAfterInput ?? "") == after else { return false }
        let current = proxy.documentContextBeforeInput ?? ""
        return current.hasSuffix(text) || (allowingCutWindow && !current.isEmpty && text.hasSuffix(current))
    }

    /// The text around the cursor is still the text around the draft: the
    /// same text after it, and the text before the draft ending as it did.
    /// An earlier copy of the same words, with the cursor moved to it, has
    /// other text around it and is never taken for the draft.
    private func isStillAround(_ proxy: UITextDocumentProxy, before current: String) -> Bool {
        guard (proxy.documentContextAfterInput ?? "") == after else { return false }
        let rest = current.dropLast(text.count)
        // A host may show only part of the text before the cursor.
        let shared = min(rest.count, before.count, 40)
        if shared == 0 { return rest.isEmpty == before.isEmpty || rest.isEmpty }
        return rest.suffix(shared) == before.suffix(shared)
    }

    /// The field reads as it did before the draft went in: the host has not
    /// shown it yet.
    private func readsAsBefore(_ proxy: UITextDocumentProxy) -> Bool {
        (proxy.selectedText ?? "").isEmpty && (proxy.documentContextBeforeInput ?? "") == before
            && (proxy.documentContextAfterInput ?? "") == after
    }
}
