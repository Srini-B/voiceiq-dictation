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

    /// A fixed word as handed to the app.
    struct Fix: Equatable {
        /// The dictated wording it replaced.
        var heard: String
        /// The fixed word, spelled as in the field.
        var term: String
        /// It begins a sentence, so its capital may not mark a name.
        var startsSentence: Bool
    }

    private let tracker: DictationEditTracker
    /// The input session (`UITextDocumentProxy.documentIdentifier`) the followed
    /// dictation went into; nil when UIKit didn't name it.
    private var document: UUID?
    /// The field's text as last seen with text in it, to read back how a fixed word is
    /// spelled there (`fix(for:in:)`). A send that empties the field leaves it as it was.
    private var fieldText = ""

    init(
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        learn: @escaping (Fix) -> Void = { fix in
            SharedStore.shared.requestDictionaryAddition(fix.term, learnedFrom: fix.heard,
                                                         startsSentence: fix.startsSentence)
            KeyboardLog.note("dictation fix queued for the Dictionary")
        }
    ) {
        tracker = DictationEditTracker(now: now)
        tracker.onResult = { [unowned self] result in
            for fix in Self.fixes(in: result, field: fieldText) { learn(fix) }
        }
    }

    /// A dictation went in at the cursor in input session `document`; `before` is the
    /// field as it was. Not `learns`: the dictation before it is settled and this one is
    /// not followed.
    func inserted(_ text: String, before: Context, after: Context, in document: UUID?, learns: Bool) {
        if !isSameDocument(document) { tracker.finish(nil) }
        guard learns else { return finish(before, in: document) }
        self.document = document
        note(before)
        tracker.willInsert(heard: nil, inserted: text, context: before)
        note(after)
        tracker.observe(after, fromKeys: true)
    }

    /// The field changed, by this keyboard's keys (`fromKeys`) or by the app. In another
    /// input session the dictation settles where it was last seen in its own, before the
    /// other field's text can read as an edit of it; while UIKit names no session (focus
    /// moving) nothing is read.
    func observe(_ context: Context, in document: UUID?, fromKeys: Bool) {
        guard tracker.isTracking else { return }
        guard isSameDocument(document) else {
            if document != nil { tracker.finish(nil) }
            return
        }
        note(context)
        tracker.tick { context }
        tracker.observe(context, fromKeys: fromKeys)
    }

    func undone() {
        tracker.didUndo()
    }

    /// The keyboard is going or the text was sent: what the dictation became is final.
    /// Nil when the field can no longer be read.
    func finish(_ context: Context?, in document: UUID? = nil) {
        guard tracker.isTracking else { return }
        guard let context, isSameDocument(document) else { return tracker.finish(nil) }
        note(context)
        tracker.finish(context)
    }

    /// Whether `document` is the session the dictation went into. A dictation whose
    /// session UIKit didn't name matches any.
    private func isSameDocument(_ document: UUID?) -> Bool {
        self.document == nil || document == self.document
    }

    private func note(_ context: Context) {
        let text = (context.before ?? "") + (context.after ?? "")
        if !text.isEmpty { fieldText = text }
    }

    /// The words you replaced in a dictation you kept, with what you replaced
    /// them by. Hex's classifier has already left out rewrites (more than half
    /// changed), changes too long to be one fix (over three words a side) and
    /// replacements that don't read as a respelling of what was dictated.
    nonisolated static func fixes(in result: DictationEditResult, field: String) -> [Fix] {
        guard result.outcome == .edited else { return [] }
        return result.pairs.filter { $0.kind == .substituted }.map { fix(for: $0, in: field) }
    }

    /// The fix as it reads in the field, found between the dictated words around it.
    /// Hex lowers a capital that only starts a sentence ("Saran went home" teaches
    /// "saran"); the capital the user left comes back, and the fix starts a sentence.
    /// A lowercase word the user left at the start stays lowercase. Otherwise the fix
    /// starts a sentence when the field has `.`, `!`, `?`, `…`, `:` or a line break
    /// before it, or nothing.
    nonisolated static func fix(for pair: DictationEditPair, in field: String) -> Fix {
        let meant = pair.meant
        var fix = Fix(heard: pair.heard, term: meant, startsSentence: false)
        let words = DictationText.words(in: field)
        let key = DictationText.phraseKey(meant)
        let count = DictationText.words(in: meant).count
        guard count > 0, words.count >= count else { return fix }
        for start in 0...(words.count - count) {
            let end = start + count
            let window = words[start..<end].map(\.text)
            guard window.map(DictationText.key).joined(separator: " ") == key,
                  pair.before.map({ start > 0 && DictationText.key(words[start - 1].text) == DictationText.key($0) }) ?? true,
                  pair.after.map({ end < words.count && DictationText.key(words[end].text) == DictationText.key($0) }) ?? true
            else { continue }
            if let first = meant.first, first.isLowercase,
               window.joined(separator: " ") == first.uppercased() + meant.dropFirst() {
                fix.term = first.uppercased() + meant.dropFirst()
                fix.startsSentence = true
            } else {
                fix.startsSentence = startsSentence(at: words[start].range.lowerBound, in: field)
            }
            return fix
        }
        return fix
    }

    private nonisolated static func startsSentence(at index: String.Index, in text: String) -> Bool {
        var index = index
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if character.isNewline { return true }
            if character.isWhitespace || "\"“”'‘’([".contains(character) { continue }
            return ".!?…:".contains(character)
        }
        return true
    }
}
