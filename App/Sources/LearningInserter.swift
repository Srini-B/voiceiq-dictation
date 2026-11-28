import Foundation
import VoiceIQCore

/// `InsertionCoordinator` plus auto-learn: harvest the user's edits to earlier
/// insertions in this field before the new text lands, then track the new text.
///
/// Wrapping the inserter rather than teaching `DictationCoordinator` about
/// learning keeps the session state machine unaware of the dictionary; the only
/// thing this adds is an AX read on either side of the insert.
@MainActor
final class LearningInserter: TextInserting {
    private let inner = InsertionCoordinator()
    let learner: EditLearner

    init(learner: EditLearner) {
        self.learner = learner
    }

    func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        let field = AXInserter.focusedField(targetPID: context.targetPID, bundleID: context.targetAppBundleID)
        if let field { await learner.harvest(before: field) }
        let text = InsertionCoordinator.fitted(text, context: context)
        let outcome = await inner.insert(text, context: context)
        if outcome == .inserted, let field { learner.track(inserted: text, in: field) }
        return outcome
    }

    func draft(context: DictationContext) async -> TextDraft? {
        guard let draft = FieldDraft.begin(context: context, inserter: inner, marks: DraftOverlay()) else { return nil }
        return LearningDraft(draft: draft, learner: learner, context: context)
    }
}

/// A draft whose written text auto-learn tracks once it replaced the draft.
@MainActor
private final class LearningDraft: TextDraft {
    private let draft: FieldDraft
    private let learner: EditLearner
    private let context: DictationContext
    private var field: FieldSnapshot?

    init(draft: FieldDraft, learner: EditLearner, context: DictationContext) {
        self.draft = draft
        self.learner = learner
        self.context = context
    }

    func show(_ text: String) async -> DraftShown {
        field = AXInserter.focusedField(targetPID: context.targetPID, bundleID: context.targetAppBundleID)
        if let field { await learner.harvest(before: field) }
        return await draft.show(text)
    }

    func replace(with text: String) async -> Bool {
        let replaced = await draft.replace(with: text)
        if replaced, let field, let written = draft.text { learner.track(inserted: written, in: field) }
        return replaced
    }

    func end() { draft.end() }
}
