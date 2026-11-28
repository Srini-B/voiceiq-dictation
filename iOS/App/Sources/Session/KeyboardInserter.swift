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

    /// A draft when the dictation goes back to a keyboard's input session.
    /// Whether a keyboard is still there to type it is the keyboard's call
    /// (`KeyboardModel.typeDraftIfNeeded`); when none does, the written text
    /// comes alone, as before.
    func draft(context: DictationContext) async -> TextDraft? {
        guard destination?()?.documentID != nil else { return nil }
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
    /// The draft a keyboard typed.
    private var typedID: UUID?
    private var ended = false

    init(inserter: KeyboardInserter) {
        self.inserter = inserter
    }

    func show(_ text: String) async -> DraftShown {
        guard !ended, offered == nil, typedID == nil, let destination = inserter.destination?() else {
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
        // A keyboard types a draft only within `Delivery.draftWindow`, well
        // inside the wait: one that did not say so by now never will.
        store.reloadFromDisk()
        guard store.typedDraftID == draft.id else {
            SessionDiagnostics.note("draft not typed by a keyboard; the written text comes alone")
            return .notInserted
        }
        typedID = draft.id
        SessionDiagnostics.note("draft typed by the keyboard")
        return .shown
    }

    func replace(with text: String) async -> Bool {
        guard let typedID else { return false }
        // The keyboard does the swap, or leaves the draft as heard.
        inserter.onDeliver?(text, typedID)
        return true
    }

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
