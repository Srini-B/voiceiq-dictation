import Foundation

/// One dictation's draft: the transcript goes in once, in its turn, the
/// moment it is heard, and the job then swaps it for the written text.
@MainActor
final class DraftStage {
    let draft: TextDraft
    private let turn: InsertTurns.Ticket?
    private let onShown: () -> Void
    private var showing: Task<DraftShown, Never>?
    private var ended = false

    init(draft: TextDraft, turn: InsertTurns.Ticket?, onShown: @escaping () -> Void) {
        self.draft = draft
        self.turn = turn
        self.onShown = onShown
    }

    func show(_ text: String) {
        guard showing == nil else { return }
        showing = Task { [weak self, draft, turn, onShown] in
            await turn?.waitForPrevious()
            // Cancelled (Esc) or finished while it waited its turn.
            guard self?.ended == false else { return .notInserted }
            let shown = await draft.show(text)
            if shown == .shown { onShown() }
            return shown
        }
    }

    /// How the draft went in; `.notInserted` when the written text came
    /// first and the draft never started.
    func shown() async -> DraftShown {
        guard let showing else {
            // Too late for a draft: the written text goes in alone.
            showing = Task { .notInserted }
            return .notInserted
        }
        return await showing.value
    }

    func end() {
        ended = true
        draft.end()
    }
}
