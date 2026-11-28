import Foundation

public extension Notification.Name {
    /// A draft stayed in the field as heard; the object is the pill's note.
    static let voiceIQDraftKept = Notification.Name("io.blue.voiceiq.draft-kept")
}

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
    private var withdrawn = false

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
            guard self?.ended == false, self?.withdrawn == false else { return .notInserted }
            let shown = await draft.show(text)
            // A draft that never went in leaves the place to the written
            // text, which takes the whole turn.
            if shown != .notInserted { turn?.markPlaced() }
            // The job may have ended while the draft went in: its cleanup has
            // run, so nothing would take the writing animation down again.
            if shown == .shown, self?.ended == false { onShown() }
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

    /// The job ends without written text (Esc, no speech, a failure): a
    /// draft that went in is taken back out through the same verified swap,
    /// so the field is left as it was. One the user edited stays. Run in its
    /// own task, so the job's cancellation doesn't cut its waits short.
    /// A draft that stays is announced (`voiceIQDraftKept`).
    func withdraw() async {
        withdrawn = true
        guard let showing else { return }
        let draft = draft
        await Task { @MainActor in
            let shown = await showing.value
            guard shown != .notInserted else { return }
            // A lost draft may be in the field and can't be found to take out.
            if shown == .lost || (await draft.replace(with: "")) != true {
                NotificationCenter.default.post(name: .voiceIQDraftKept, object: DictationCoordinator.withdrawKeptNotice)
            }
        }.value
    }

    func end() {
        ended = true
        draft.end()
    }
}
