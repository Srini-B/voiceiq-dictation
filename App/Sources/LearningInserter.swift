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
        let enabled = SettingsStore().autoLearnEnabled
        let field = enabled
            ? AXInserter.focusedField(targetPID: context.targetPID, bundleID: context.targetAppBundleID)
            : nil
        if let field { await learner.harvest(before: field) }
        let text = InsertionCoordinator.fitted(text, context: context)
        let outcome = await inner.insert(text, context: context)
        if outcome == .inserted, let field { learner.track(inserted: text, in: field) }
        return outcome
    }
}
