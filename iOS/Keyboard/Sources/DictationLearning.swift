import Foundation
import VoiceIQBridge

/// Learns from the fixes you make to dictated text, as Hex's keyboard does:
/// Hex's `DictationEditTracker` follows each dictation typed into the field
/// and reports what became of it. A word you fixed in a dictation you kept
/// ("Sharon" to "Saran") goes to the app as an auto-learned Dictionary word
/// heard as the dictated wording (`DictionaryAddition.learnedFrom`), and the
/// app keeps it by the Mac's rules (`DictionaryStore.learn`). A dictation
/// rewritten, deleted, undone or dictated again teaches nothing.
///
/// Always on, also with Learn how I type off: what it learns is removable in
/// the Dictionary's Auto-learned section. Never in a secure field or one
/// Hex's journal skips (`TypingBridge.learnsFromDictation`).
@MainActor
final class DictationLearning {
    typealias Context = DictationEditTracker.Context

    private let tracker: DictationEditTracker
    /// The field's text as last seen with text in it, to read back how a fixed word is
    /// spelled there (`spelling`). A send that empties the field leaves it as it was.
    private var fieldText = ""

    /// `learn`: a fixed word and the dictated wording it replaced.
    init(
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        learn: @escaping (_ term: String, _ heard: String) -> Void = { term, heard in
            SharedStore.shared.requestDictionaryAddition(term, learnedFrom: heard)
            KeyboardLog.note("dictation fix queued for the Dictionary")
        }
    ) {
        tracker = DictationEditTracker(now: now)
        tracker.onResult = { [unowned self] result in
            for fix in Self.fixes(in: result, field: fieldText) { learn(fix.meant, fix.heard) }
        }
    }

    /// A dictation went in at the cursor; `before` is the field as it was.
    /// Not `learns`: the dictation before it is settled and this one is not followed.
    func inserted(_ text: String, before: Context, after: Context, learns: Bool) {
        guard learns else { return finish(before) }
        note(before)
        tracker.willInsert(heard: nil, inserted: text, context: before)
        note(after)
        tracker.observe(after, fromKeys: true)
    }

    /// The field changed, by this keyboard's keys (`fromKeys`) or by the app.
    func observe(_ context: Context, fromKeys: Bool) {
        guard tracker.isTracking else { return }
        note(context)
        tracker.tick { context }
        tracker.observe(context, fromKeys: fromKeys)
    }

    func undone() {
        tracker.didUndo()
    }

    /// The keyboard is going or the text was sent: what the dictation became is final.
    /// Nil when the field can no longer be read.
    func finish(_ context: Context?) {
        guard tracker.isTracking else { return }
        if let context { note(context) }
        tracker.finish(context)
    }

    private func note(_ context: Context) {
        let text = (context.before ?? "") + (context.after ?? "")
        if !text.isEmpty { fieldText = text }
    }

    /// The words you replaced in a dictation you kept, with what you replaced
    /// them by. Hex's classifier has already left out rewrites (more than half
    /// changed), changes too long to be one fix (over three words a side) and
    /// replacements that don't read as a respelling of what was dictated.
    nonisolated static func fixes(in result: DictationEditResult, field: String) -> [(heard: String, meant: String)] {
        guard result.outcome == .edited else { return [] }
        return result.pairs.filter { $0.kind == .substituted }.map { ($0.heard, spelling(of: $0, in: field)) }
    }

    /// The fix as spelled in the field. Hex lowers a capital that only starts a sentence
    /// ("Saran went home" teaches "saran"), but a name keeps it: when the field has the
    /// fixed words with that capital, between the dictated words around them, the capital
    /// stays. A lowercase word the user left at the start stays lowercase.
    nonisolated static func spelling(of pair: DictationEditPair, in field: String) -> String {
        let meant = pair.meant
        guard let first = meant.first, first.isLowercase else { return meant }
        let capitalized = first.uppercased() + meant.dropFirst()
        let words = DictationText.words(in: field).map(\.text)
        let count = DictationText.words(in: meant).count
        guard count > 0, words.count >= count else { return meant }
        for start in 0...(words.count - count) where words[start..<(start + count)].joined(separator: " ") == capitalized {
            let end = start + count
            let beforeMatches = pair.before.map { start > 0 && DictationText.key(words[start - 1]) == DictationText.key($0) } ?? true
            let afterMatches = pair.after.map { end < words.count && DictationText.key(words[end]) == DictationText.key($0) } ?? true
            if beforeMatches && afterMatches { return capitalized }
        }
        return meant
    }
}
