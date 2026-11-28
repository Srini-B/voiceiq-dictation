import Foundation
import VoiceIQBridge
import VoiceIQCore

/// Where the dictation in progress came from and where its text goes.
@MainActor
final class DictationTarget {
    struct Fields: Equatable {
        /// The app Dictate was tapped in, for History and the writing model.
        var host: String?
        /// The field Dictate was tapped in.
        var origin: FieldIdentity?
        /// The field Stop was tapped in, when a keyboard stopped it.
        var stoppedIn: FieldIdentity?
        /// When the user stopped it, from a keyboard or from outside one.
        var stoppedAt: Date?
        /// The text around the cursor where the text goes, for the writing
        /// model (`DictationContext.focusedField`): read at Dictate, then
        /// at Stop when a keyboard stopped it.
        var text = FocusedFieldCapture()
    }

    var fields = Fields()

    var host: String? { fields.host }

    /// The text goes where Stop was tapped. Stopped from outside a keyboard
    /// (Dynamic Island, Action button, a call), it goes back to where it
    /// started.
    var destination: FieldIdentity? { fields.stoppedIn ?? fields.origin }
}

/// Hands results to the keyboard. The keyboard does the actual typing.
@MainActor
final class KeyboardInserter: TextInserting {
    /// Publishes the written text; the second value names the draft it
    /// replaces, when a keyboard typed one.
    var onDeliver: ((String, UUID?) -> Void)?
    /// Publishes a draft for the keyboard (`SessionSnapshot.draft`), or
    /// withdraws it with nil.
    var onDraft: ((Delivery?) -> Void)?
    /// Where the dictation in progress goes (`DictationTarget.destination`).
    var destination: (() -> FieldIdentity?)?

    func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        onDeliver?(text, nil)
        return .inserted
    }

    /// On. The swap is one insert over the marked draft (`KeyboardDraft`),
    /// tried in the iOS 27 Simulator, not yet on a device. The first swap
    /// deleted the draft key by key and, in Messages, took the earlier
    /// dictation and typed text with it (2026-11-28).
    static let offersDrafts = true

    /// A draft when the dictation goes back to a keyboard's input session in
    /// an app the swap was tried in (`Delivery.takesDrafts`). Elsewhere no
    /// draft is offered, so the written text is not held back by the wait
    /// for one, and is typed once, as before drafts. Whether a keyboard is
    /// still there to type it is the keyboard's call
    /// (`KeyboardModel.typeDraftIfNeeded`); when none does, the written text
    /// is typed as a plain result, as before.
    func draft(context: DictationContext) async -> TextDraft? {
        guard Self.offersDrafts, let destination = destination?(), destination.documentID != nil,
              let host = destination.hostBundleID,
              Delivery.takesDrafts(host, trying: SharedStore.shared.triesMoreDraftHosts) else { return nil }
        return KeyboardTextDraft(inserter: self)
    }
}

/// The app's half of a draft: it offers the transcript in the snapshot,
/// waits a moment for the keyboard to say it typed it, then withdraws it,
/// so it is never typed late. The keyboard swaps it for the written text,
/// or leaves it as heard when it can't find it for certain.
@MainActor
private final class KeyboardTextDraft: TextDraft {
    private let inserter: KeyboardInserter
    private let store = SharedStore.shared
    /// The draft in the snapshot, until it is withdrawn.
    private var offered: Delivery?
    /// The draft this dictation offered, which its written text names.
    private var draftID: UUID?
    private var ended = false

    init(inserter: KeyboardInserter) {
        self.inserter = inserter
    }

    func show(_ text: String) async -> DraftShown {
        guard !ended, offered == nil, draftID == nil, let destination = inserter.destination?() else {
            return .notInserted
        }
        let draft = Delivery(text: text, destination: destination)
        offered = draft
        inserter.onDraft?(draft)
        let deadline = draft.createdAt.addingTimeInterval(Delivery.draftWait)
        while !ended, Date() < deadline, store.typedDraftID != draft.id {
            try? await Task.sleep(for: .milliseconds(50))
            store.reloadFromDisk()
        }
        withdraw()
        guard !ended else { return .notInserted }
        // Whether or not a keyboard said it typed the draft, the written
        // text comes naming it, from this dictation alone: a keyboard holding
        // it swaps it (also one whose report came late), and any other types
        // the written text as a plain result. So it is never typed beside
        // the draft, and no other dictation's text can carry its name.
        draftID = draft.id
        store.reloadFromDisk()
        let confirmed = store.typedDraftID == draft.id
        SessionDiagnostics.note(confirmed ? "draft typed by the keyboard" : "draft not confirmed by a keyboard in time")
        // Unconfirmed, the written text takes the dictation's insert turn.
        return confirmed ? .shown : .pending
    }

    func replace(with text: String) async -> Bool {
        // The keyboard can't take a draft back out; it stays as heard.
        guard let draftID, !text.isEmpty else { return false }
        // The keyboard does the swap, leaves the draft as heard, or types
        // the text as a plain result where no draft went in.
        inserter.onDeliver?(text, draftID)
        return true
    }

    /// The keyboard types a draft on its own once offered; nothing to stop here.
    func stopShowing() {}

    func end() {
        ended = true
        withdraw()
    }

    private func withdraw() {
        guard offered != nil else { return }
        offered = nil
        inserter.onDraft?(nil)
    }
}
