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
        /// A field forgotten and tracked again is a new one: results of
        /// harvests that started on the old one are dropped.
        let id = UUID()
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
        /// Return captures still diffing: the field is not dropped under one.
        var capturesInFlight = 0
        /// Harvests are numbered when they read the field; a result older
        /// than the last one applied (a slow poll behind a Return capture)
        /// is dropped.
        var nextTicket = 0
        var appliedTicket = -1
    }

    /// One matched insertion after a harvest: its text now reads `window`.
    private struct Located: Sendable {
        let id: UUID
        let window: String
        let edits: DictationEdits
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
        let kept = entries.filter { entry in
            entry.source != .auto || !teachesNothing(LearnedCorrection(
                original: entry.learnedFrom ?? "",
                replacement: entry.term,
                words: 0..<0
            ))
        }
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
        // A poll that read the field before this insertion is no longer the
        // newest, so it cannot drop the field or move its pending value.
        tracked.nextTicket += 1
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
            if tracked.capturesInFlight == 0 { forget(key) }
            return
        }
        if captured == nil { tracked.harvesting = true } else { tracked.capturesInFlight += 1 }
        let ticket = tracked.nextTicket
        let fieldID = tracked.id
        tracked.nextTicket += 1
        fields[key] = tracked

        let snapshot = tracked.snapshot
        let insertions = tracked.insertions.map { ($0.id, $0.text, $0.original, $0.edits) }
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

        guard var current = fields[key], current.id == fieldID else { return }
        if captured == nil { current.harvesting = false } else { current.capturesInFlight -= 1 }
        // Only the newest harvest may drop the field or move its pending
        // value: an older one read the field before a newer one did.
        let newest = ticket == current.nextTicket - 1
        switch result {
        case .fieldGone:
            if newest, current.capturesInFlight == 0 { forget(key) } else { fields[key] = current }
        case .unchanged:
            fields[key] = current
        case let .editing(valueHash):
            if newest, valueHash != current.pendingHash {
                current.pendingHash = valueHash
                current.pendingSince = now
            }
            fields[key] = current
        case let .located(located, valueHash):
            guard ticket > current.appliedTicket else {
                fields[key] = current
                return
            }
            current.appliedTicket = ticket
            current.lastValueHash = valueHash
            current.pendingHash = nil
            current.pendingSince = nil
            let harvested = Set(insertions.map(\.0))
            let byID = Dictionary(uniqueKeysWithValues: located.map { ($0.id, $0) })
            var steps: [LearningStep] = []
            current.insertions = current.insertions.compactMap { insertion in
                guard harvested.contains(insertion.id) else { return insertion }
                guard let match = byID[insertion.id] else { return nil }
                steps += EditDiff.steps(for: match.edits, after: insertion.edits)
                var updated = insertion
                updated.text = match.window
                updated.edits = EditDiff.history(after: match.edits, earlier: insertion.edits)
                return updated
            }
            if current.insertions.isEmpty, newest, current.capturesInFlight == 0 {
                forget(key)
            } else {
                fields[key] = current
            }
            let taught = current.insertions.flatMap(\.edits)
                .reduce(into: [String: Int]()) { $0[$1.replacement.lowercased(), default: 0] += 1 }
            learn(steps, stillTaught: taught)
        }
    }

    private func forget(_ key: FieldKey) {
        fields[key]?.pollTask?.cancel()
        fields.removeValue(forKey: key)
        watched.set(key, nil)
    }

    private nonisolated static func compute(
        value: String?,
        insertions: [(UUID, String, String, [LearnedCorrection])],
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
                edits: EditDiff.edits(
                    original: insertion.2, replacement: match.window, earlier: insertion.3,
                    context: String(current[..<match.range.lowerBound].suffix(200))
                )
            )
        }
        return .located(located, valueHash: valueHash)
    }

    private nonisolated static func isFresh(_ entry: DictionaryEntry) -> Bool {
        entry.source == .auto && !entry.starred && Date().timeIntervalSince(entry.updatedAt) <= reEditSeconds
    }

    /// `stillTaught`: how many corrections in this field still teach each
    /// spelling, so undoing or revising one copy of a fix does not drop a word
    /// another copy keeps.
    /// Only words the language does not already have: a name, a product term,
    /// jargon. Many Indian names are English words in lowercase ("Saran",
    /// "Ram", "Raja"), so a capitalized replacement for heard wording that was
    /// not ordinary either ("Sharon" → "Saran") is still a name, unless the
    /// capital only starts a sentence ("Sara, I'm late" → "Sorry, I'm late").
    /// Changing "They" to "We" or "Then" to "Than" teaches nothing.
    private static func teachesNothing(_ correction: LearnedCorrection) -> Bool {
        guard CommonWords.isOrdinary(correction.replacement) else { return false }
        return !(correction.nameLike && !CommonWords.isOrdinary(correction.original))
    }

    func learn(_ steps: [LearningStep], stillTaught: [String: Int]) {
        var learned: [DictionaryEntry] = []
        var known = dictionary.entries()
        for step in steps {
            let correction: LearnedCorrection
            let candidates: [DictionaryEntry]
            // The transcript wording a revised entry now records; nil keeps it.
            var heardAs: String?
            switch step {
            case let .forget(edit):
                guard stillTaught[edit.replacement.lowercased(), default: 0] == 0 else { continue }
                // By spelling alone: a rename from another dictation keeps
                // the older wording.
                let gone = known.filter { Self.isFresh($0) && $0.term.lowercased() == edit.replacement.lowercased() }
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
                candidates = known.filter { Self.isFresh($0) && $0.term.lowercased() == edit.original.lowercased() }
            case let .revise(replacing, edit):
                // The user went back to words learned moments ago from this
                // dictation, or edited the word beside one.
                correction = edit
                heardAs = edit.original
                // Matched by the spelling the earlier fix taught, not by its
                // transcript wording, which other fixes of that word share.
                let terms = Set(replacing.map { $0.replacement.lowercased() })
                candidates = known.filter { Self.isFresh($0) && terms.contains($0.term.lowercased()) }
            }
            // A spelling another fix in the field still teaches is not
            // renamed or dropped; this correction's own spelling counts once.
            // The correction is then learned as its own word.
            let stale = candidates.filter {
                let term = $0.term.lowercased()
                let own = term == correction.replacement.lowercased() ? 1 : 0
                return stillTaught[term, default: 0] - own == 0
            }
            let protected = Set(candidates.map(\.id)).subtracting(stale.map(\.id))
            if let kept = stale.first {
                // The entry follows the edit, and entries for the parts of a
                // phrase fold into the phrase.
                let staleIDs = Set(stale.map(\.id))
                for entry in stale.dropFirst() { dictionary.remove(id: entry.id) }
                known.removeAll { staleIDs.contains($0.id) }
                learned.removeAll { staleIDs.contains($0.id) }
                let replacement = correction.replacement.lowercased()
                if known.contains(where: { $0.term.lowercased() == replacement })
                    || Self.teachesNothing(correction) {
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
            // A revision too late to rename its entry is a new spelling of the
            // same transcript wording, so that wording does not block it.
            let isRevision = heardAs != nil
            guard !known.contains(where: {
                let term = $0.term.lowercased()
                let misspelling = $0.misspelling?.lowercased()
                let learnedFrom = $0.learnedFrom?.lowercased()
                // A protected entry spelled as the original does not block
                // learning the new spelling beside it.
                return (term == original && !protected.contains($0.id)) || term == replacement
                    || misspelling == original || misspelling == replacement
                    || (!isRevision && learnedFrom == original && !protected.contains($0.id))
            }) else { continue }
            guard !Self.teachesNothing(correction) else {
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
