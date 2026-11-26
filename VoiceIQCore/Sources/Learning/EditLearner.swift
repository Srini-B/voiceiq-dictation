#if os(macOS)
import Foundation

/// Learns dictionary corrections from the user's edits to earlier insertions.
///
/// The accessibility read and the diff run off the main actor: a long
/// document with several tracked insertions took whole seconds of CPU, and
/// doing that on the main thread every poll froze the hotkey, the pill and
/// the tray menu. Only bookkeeping and dictionary writes touch the main actor.
@MainActor
public final class EditLearner {
    private struct Insertion {
        let id: UUID
        /// The text as inserted. Each harvest diffs the field against this, so
        /// words edited a few seconds apart still read as one phrase.
        let original: String
        /// Where the insertion was last found, to find it again.
        var text: String
        let insertedAt: Date
        /// The edits it carried at the last harvest.
        var edits: [LearnedCorrection] = []
    }

    private struct TrackedField {
        let snapshot: FieldSnapshot
        var insertions: [Insertion]
        var lastInsertionAt: Date
        /// Hash of the field value the last diff ran against.
        var lastValueHash: Int?
        /// A value seen since then that has not yet held still long enough
        /// to be diffed, and when it was first seen.
        var pendingHash: Int?
        var pendingSince: Date?
        var pollTask: Task<Void, Never>?
        var harvesting = false
    }

    /// One matched insertion after a harvest: its text now reads `window`.
    private struct Located: Sendable {
        let id: UUID
        let window: String
        let corrections: [LearnedCorrection]
    }

    private enum Harvest: Sendable {
        case fieldGone
        case unchanged
        /// The field changed but is still being edited: `valueHash` is the
        /// value seen now, to be diffed once it has held still.
        case editing(valueHash: Int)
        case located([Located], valueHash: Int)
    }

    /// Fields above this size are not diffed; the harvest would cost more than
    /// the corrections are worth and the user is unlikely to be dictating there.
    nonisolated static let maximumFieldLength = 200_000

    /// A changed field is diffed only after its value has stayed the same for
    /// this long. Diffing mid-edit learned half-typed words ("Pastack" while
    /// the user was on the way from "Paystack" to "pstack").
    nonisolated static let settleSeconds: TimeInterval = 4

    /// An auto-learned word edited again, or extended by editing the word next
    /// to it, within this long of being learned (or last revised) is revised
    /// in place rather than joined by a new entry.
    nonisolated static let reEditSeconds: TimeInterval = 120

    private let dictionary: DictionaryStore
    private var fields: [FieldKey: TrackedField] = [:]
    /// The fields still being polled, for `captureBeforeReturn` on the tap thread.
    private nonisolated let watched = WatchedFields()
    public var onLearned: (([DictionaryEntry]) -> Void)?

    public init(dictionary: DictionaryStore = DictionaryStore()) {
        self.dictionary = dictionary
    }

    private static let pruneFlag = "didPruneOrdinaryAutoLearned"

    /// One-time: removes auto-learned entries that are ordinary words, learned
    /// before the rule above existed. Entries the user added are untouched.
    /// The removal syncs to the iPhone like any other deletion.
    public static func pruneOrdinaryAutoLearnedOnce(dictionary: DictionaryStore = DictionaryStore()) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: pruneFlag) else { return }
        defaults.set(true, forKey: pruneFlag)
        let entries = dictionary.entries()
        let kept = entries.filter { $0.source != .auto || !CommonWords.isOrdinary($0.term) }
        guard kept.count != entries.count else { return }
        dictionary.save(kept)
        Log.learning.info("Removed \(entries.count - kept.count) auto-learned ordinary word(s)")
    }

    deinit {
        for field in fields.values { field.pollTask?.cancel() }
    }

    /// Harvests edits made to earlier insertions in `field`, returning once
    /// they are applied. Callers about to insert new text await this so the
    /// diff sees the field before the new text lands.
    public func harvest(before field: FieldSnapshot) async {
        await harvest(key: FieldKey(field))
    }

    public func track(inserted text: String, in field: FieldSnapshot) {
        let key = FieldKey(field)
        let now = Date()
        var tracked = fields[key] ?? TrackedField(
            snapshot: field,
            insertions: [],
            lastInsertionAt: now
        )
        tracked.insertions.removeAll { now.timeIntervalSince($0.insertedAt) > 7_200 }
        tracked.insertions.append(Insertion(id: UUID(), original: text, text: text, insertedAt: now))
        if tracked.insertions.count > 20 {
            tracked.insertions.removeFirst(tracked.insertions.count - 20)
        }
        tracked.lastInsertionAt = now
        tracked.lastValueHash = nil
        tracked.pendingHash = nil
        tracked.pendingSince = nil
        tracked.pollTask?.cancel()
        tracked.pollTask = pollingTask(for: key)
        fields[key] = tracked
        watched.set(key, field)
        Log.learning.debug("Tracking edit candidates for pid \(field.pid)")
    }

    public func undo(_ entries: [DictionaryEntry]) {
        for entry in entries { dictionary.remove(id: entry.id) }
    }

    private func pollingTask(for key: FieldKey) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let field = self.fields[key] else { return }
                let elapsed = Date().timeIntervalSince(field.lastInsertionAt)
                guard elapsed < 600 else {
                    self.watched.set(key, nil)
                    return
                }
                let interval: TimeInterval = elapsed < 20 ? 1 : 5
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.harvest(key: key)
                guard self.fields[key] != nil else { return }
            }
        }
    }

    /// Called on the event-tap thread while a Return key-down is held back from
    /// the frontmost app, so the field is read before a chat app sends and
    /// clears it. Return means the user is done editing, so the value is
    /// diffed at once instead of after `settleSeconds`.
    public nonisolated func captureBeforeReturn(frontmostPID: pid_t) {
        let captured = watched.fields(pid: frontmostPID).compactMap { key, snapshot in
            snapshot.quickValue().map { (key, $0) }
        }
        guard !captured.isEmpty else { return }
        Task { @MainActor [weak self] in
            for (key, value) in captured {
                await self?.harvest(key: key, captured: value)
            }
        }
    }

    /// With `captured`, diffs that value as settled. A capture runs even while
    /// a poll is in flight: that poll may be reading the field after the app
    /// has already sent and cleared it.
    private func harvest(key: FieldKey, captured: String? = nil) async {
        guard var tracked = fields[key], captured != nil || !tracked.harvesting else { return }
        let now = Date()
        tracked.insertions.removeAll { now.timeIntervalSince($0.insertedAt) > 7_200 }
        guard !tracked.insertions.isEmpty else {
            forget(key)
            return
        }
        if captured == nil { tracked.harvesting = true }
        fields[key] = tracked

        let snapshot = tracked.snapshot
        let insertions = tracked.insertions.map { ($0.id, $0.text, $0.original) }
        let previousHash = tracked.lastValueHash
        let settled = tracked.pendingSince.map { now.timeIntervalSince($0) >= Self.settleSeconds } == true
        let settledHash = captured?.hashValue ?? (settled ? tracked.pendingHash : nil)
        let result = await Task.detached(priority: .utility) {
            Self.compute(
                value: captured ?? snapshot.currentValue(),
                insertions: insertions,
                previousHash: previousHash,
                settledHash: settledHash
            )
        }.value

        guard var current = fields[key] else { return }
        if captured == nil { current.harvesting = false }
        switch result {
        case .fieldGone:
            forget(key)
        case .unchanged:
            fields[key] = current
        case let .editing(valueHash):
            if valueHash != current.pendingHash {
                current.pendingHash = valueHash
                current.pendingSince = now
            }
            fields[key] = current
        case let .located(located, valueHash):
            current.lastValueHash = valueHash
            current.pendingHash = nil
            current.pendingSince = nil
            let harvested = Set(insertions.map(\.0))
            let byID = Dictionary(uniqueKeysWithValues: located.map { ($0.id, $0) })
            var steps: [LearningStep] = []
            current.insertions = current.insertions.compactMap { insertion in
                guard harvested.contains(insertion.id) else { return insertion }
                guard let match = byID[insertion.id] else { return nil }
                steps += EditDiff.steps(for: match.corrections, after: insertion.edits)
                var updated = insertion
                updated.text = match.window
                updated.edits = match.corrections
                return updated
            }
            if current.insertions.isEmpty {
                forget(key)
            } else {
                fields[key] = current
            }
            learn(steps)
        }
    }

    private func forget(_ key: FieldKey) {
        fields[key]?.pollTask?.cancel()
        fields.removeValue(forKey: key)
        watched.set(key, nil)
    }

    private nonisolated static func compute(
        value: String?,
        insertions: [(UUID, String, String)],
        previousHash: Int?,
        settledHash: Int?
    ) -> Harvest {
        guard let current = value, current.count <= maximumFieldLength else { return .fieldGone }
        let valueHash = current.hashValue
        if valueHash == previousHash { return .unchanged }
        guard valueHash == settledHash else { return .editing(valueHash: valueHash) }
        let matches = EditDiff.locateWindows(insertions: insertions.map(\.1), in: current)
        let located = zip(insertions, matches).compactMap { insertion, match -> Located? in
            guard let match else { return nil }
            return Located(
                id: insertion.0,
                window: match.window,
                corrections: EditDiff.corrections(original: insertion.2, replacement: match.window)
            )
        }
        return .located(located, valueHash: valueHash)
    }

    private nonisolated static func isFresh(_ entry: DictionaryEntry) -> Bool {
        entry.source == .auto && Date().timeIntervalSince(entry.updatedAt) <= reEditSeconds
    }

    private func learn(_ steps: [LearningStep]) {
        var learned: [DictionaryEntry] = []
        var known = dictionary.entries()
        for step in steps {
            let correction: LearnedCorrection
            let stale: [DictionaryEntry]
            // The transcript wording a revised entry now records; nil keeps it.
            var heardAs: String?
            switch step {
            case let .forget(edit):
                let gone = known.filter {
                    Self.isFresh($0)
                        && $0.term.lowercased() == edit.replacement.lowercased()
                        && $0.learnedFrom?.lowercased() == edit.original.lowercased()
                }
                guard !gone.isEmpty else { continue }
                let goneIDs = Set(gone.map(\.id))
                for entry in gone { dictionary.remove(id: entry.id) }
                known.removeAll { goneIDs.contains($0.id) }
                learned.removeAll { goneIDs.contains($0.id) }
                Log.learning.info("Dropped a just-learned word the user put back")
                continue
            case let .learn(edit):
                // The user changed a word learned moments ago, here or in
                // another dictation.
                correction = edit
                stale = known.filter { Self.isFresh($0) && $0.term.lowercased() == edit.original.lowercased() }
            case let .revise(replacing, edit):
                // The user went back to words learned moments ago from this
                // dictation, or edited the word beside one.
                correction = edit
                heardAs = edit.original
                let wordings = Set(replacing.map { $0.lowercased() })
                stale = known.filter { Self.isFresh($0) && wordings.contains($0.learnedFrom?.lowercased() ?? "") }
            }
            if let kept = stale.first {
                // The entry follows the edit, and entries for the parts of a
                // phrase fold into the phrase.
                let staleIDs = Set(stale.map(\.id))
                for entry in stale.dropFirst() { dictionary.remove(id: entry.id) }
                known.removeAll { staleIDs.contains($0.id) }
                learned.removeAll { staleIDs.contains($0.id) }
                let replacement = correction.replacement.lowercased()
                if known.contains(where: { $0.term.lowercased() == replacement })
                    || CommonWords.isOrdinary(correction.replacement) {
                    dictionary.remove(id: kept.id)
                    Log.learning.info("Dropped a just-learned word the user edited again")
                } else {
                    dictionary.update(id: kept.id, term: correction.replacement, learnedFrom: heardAs)
                    if let entry = dictionary.entries().first(where: { $0.id == kept.id }) {
                        learned.append(entry)
                        known.append(entry)
                    }
                }
                continue
            }
            let original = correction.original.lowercased()
            let replacement = correction.replacement.lowercased()
            guard !known.contains(where: {
                let term = $0.term.lowercased()
                let misspelling = $0.misspelling?.lowercased()
                let learnedFrom = $0.learnedFrom?.lowercased()
                return term == original || term == replacement
                    || misspelling == original || misspelling == replacement
                    || learnedFrom == original
            }) else { continue }
            // Only words the language does not already have: a name, a
            // product term, jargon. Changing "They" to "we" or fixing the
            // case of "There's" is an edit, not a new word.
            guard !CommonWords.isOrdinary(correction.replacement) else {
                Log.learning.info("Skipped an edit to ordinary words")
                continue
            }
            // Learned as a word only, never as a wrong→right rule: a rule
            // built from one edit ("stack" → "pstack") would rewrite every
            // later "stack". The word rides in the vocabulary; `learnedFrom`
            // records the transcript wording it replaced.
            guard dictionary.add(
                term: correction.replacement,
                learnedFrom: correction.original,
                source: .auto
            ) else { continue }
            if let entry = dictionary.entries().last(where: {
                $0.source == .auto && $0.term.caseInsensitiveCompare(correction.replacement) == .orderedSame
            }) {
                learned.append(entry)
                known.append(entry)
            }
        }
        if !learned.isEmpty {
            Log.learning.info("Learned \(learned.count) dictionary correction(s)")
            onLearned?(learned)
        }
    }
}
#endif
