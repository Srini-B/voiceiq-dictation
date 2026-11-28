import Foundation

/// One dictation's draft: the transcript goes in once, the moment it is
/// heard and after the text of every dictation spoken before it, and the job
/// then swaps it for the written text, whatever the earlier ones' writers
/// are still doing.
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
            await turn?.waitForPreviousPlaced()
            // Cancelled (Esc) or finished while it waited its turn.
            guard self?.ended == false else { return .notInserted }
            let shown = await draft.show(text)
            // A draft that never went in leaves the place to the written
            // text, which takes the whole turn.
            if shown != .notInserted { turn?.markPlaced() }
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
