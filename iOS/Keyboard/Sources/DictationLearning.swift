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
    /// dictation went into. A dictation whose session UIKit didn't name is not followed.
    private var document: UUID?
    /// The followed dictation and the text around it when it went in, as Hex's tracker
    /// remembers it, to find it again in the field (`DictationSpanLocator`).
    private var insertion: DictationInsertion?
    /// The text now in the dictation's place, as last found in the field with words in it
    /// (as Hex's tracker keeps it), to read back how a fixed word is spelled there
    /// (`fix(for:in:from:dictated:)`). A send that empties the field leaves it as it was.
    private var spanText = ""
    /// The last observation of the followed dictation's field, and when: the edit window
    /// ends on it.
    private var lastSeen: Context?
    private var lastSeenAt: TimeInterval = 0
    /// When the followed dictation went in.
    private var insertedAt: TimeInterval = 0
    private let now: () -> TimeInterval

    /// The edit window waits this long after the last edit, so a word being retyped as it
    /// ends settles once typing pauses, not half done.
    static let typingPause: TimeInterval = 3
    /// But not past this long after the window, so steady typing can't keep it open.
    static let longestWait: TimeInterval = 10

    init(
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        learn: @escaping (Fix) -> Void = { fix in
            SharedStore.shared.requestDictionaryAddition(fix.term, learnedFrom: fix.heard,
                                                         startsSentence: fix.startsSentence)
            KeyboardLog.note("dictation fix queued for the Dictionary")
        }
    ) {
        self.now = now
        tracker = DictationEditTracker(now: now)
        tracker.onResult = { [unowned self] result in
            let found = fixes(in: result)
            // The dictation's text is held only while it is followed.
            insertion = nil
            spanText = ""
            lastSeen = nil
            for fix in found { learn(fix) }
        }
    }

    /// A dictation went in at the cursor in input session `document`; `before` is the
    /// field as it was. Not `learns`: the dictation before it is settled and this one is
    /// not followed.
    func inserted(_ text: String, before: Context, after: Context, in document: UUID?, learns: Bool) {
        if !isSameDocument(document) { tracker.finish(nil) }
        // Without a named session, text from the next field could read as an edit of it.
        guard learns, document != nil else { return finish(before, in: document) }
        self.document = document
        note(before)
        tracker.willInsert(heard: nil, inserted: text, context: before)
        // After `willInsert`, which settles the dictation before with its own text.
        insertion = DictationInsertion(inserted: text, before: before.before, after: before.after)
        spanText = text
        insertedAt = now()
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
        // A window that ended since the last poll ends on what was seen before this edit,
        // which then belongs to no dictation.
        tick()
        note(context)
        tracker.observe(context, fromKeys: fromKeys)
    }

    /// Called on the keyboard's poll: a dictation whose edit window ended settles on its
    /// last observation, so a later keystroke is not an edit of it. Not while the user is
    /// still typing (`typingPause`), up to `longestWait` past the window.
    func tick() {
        guard tracker.isTracking, let lastSeen else { return }
        let time = now()
        if time - lastSeenAt < Self.typingPause,
           time - insertedAt < DictationEditTracker.editWindow + Self.longestWait { return }
        tracker.tick { lastSeen }
    }

    /// A dictation is about to go in through the keyboard's own edits: the one before it
    /// settles on the field as it is now (`context`, nil when it may not be read), so the
    /// new text never reaches it as an edit. Hex pairs a dictation deleted and dictated
    /// again; nothing is learned from those either way.
    func willInsert(_ context: Context?, in document: UUID?) {
        finish(context, in: document)
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

    /// The field as the tracker reads it. The proxy's text before and after the cursor
    /// both leave out a selection, so the selected text goes back after the text before
    /// it; without it, selecting the "n" of "Sharon" read as fixing it to "Sharo". Hex's
    /// keyboard joins only the two.
    nonisolated static func context(before: String?, selected: String?, after: String?,
                                    hasText: Bool) -> Context {
        guard let selected, !selected.isEmpty else { return Context(before: before, after: after, hasText: hasText) }
        return Context(before: (before ?? "") + selected, after: after, hasText: hasText)
    }

    /// Whether `document` is the session the dictation went into.
    private func isSameDocument(_ document: UUID?) -> Bool {
        document != nil && document == self.document
    }

    private func note(_ context: Context) {
        lastSeen = context
        lastSeenAt = now()
        if let insertion, let span = DictationSpanLocator.locate(insertion, before: context.before, after: context.after),
           span.hasWords {
            spanText = span.text
        }
    }

    /// The fixes in `result`, read back from the followed dictation's place in the field
    /// (after the text Hex anchored it by), never from other text.
    private func fixes(in result: DictationEditResult) -> [Fix] {
        guard let insertion else { return [] }
        let text = insertion.anchorBefore + spanText
        let start = text.index(text.startIndex, offsetBy: insertion.anchorBefore.count)
        return Self.fixes(in: result, field: text, from: start, dictated: insertion.inserted)
    }

    /// The words you replaced in a dictation you kept, with what you replaced
    /// them by. Hex's classifier has already left out rewrites (more than half
    /// changed), changes too long to be one fix (over three words a side) and
    /// replacements that don't read as a respelling of what was dictated.
    nonisolated static func fixes(in result: DictationEditResult, field: String, from start: String.Index,
                                  dictated: String) -> [Fix] {
        guard result.outcome == .edited else { return [] }
        return result.pairs.filter { $0.kind == .substituted }.compactMap {
            fix(for: $0, in: field, from: start, dictated: dictated)
        }
    }

    /// The fix as it reads in the dictation's place in the field (`field` from `start`;
    /// the text before is for the sentence start) and the words it replaced as they read
    /// in the dictation, each found between the dictated words around it. Hex's pairs are
    /// word tokens joined by spaces, so the text is taken from the first word's start to
    /// the last word's end, keeping what joins them ("GPT-4", not "GPT 4"). Nil when the
    /// fix isn't in the dictation's place, is there more than once with the same words
    /// around it (on either side), or either side runs across a clause or
    /// sentence break, which the Mac splits into separate edits (`EditDiff.pieces`).
    ///
    /// Hex lowers a capital that only starts a sentence ("Saran went home" teaches
    /// "saran"); the field's text keeps the capital the user left, and the fix starts a
    /// sentence. A lowercase word the user left at the start stays lowercase. Hex takes
    /// any capitalized first word of a dictation for a sentence start, so a fixed first
    /// word that continues a sentence is marked as one too: the app then never takes its
    /// capital for a name, which can only skip a word, never learn an ordinary one.
    nonisolated static func fix(for pair: DictationEditPair, in field: String, from start: String.Index,
                                dictated: String) -> Fix? {
        let fixed = spans(of: pair.meant, before: pair.before, after: pair.after, in: field, from: start)
        let dictatedSpans = spans(of: pair.heard, before: pair.before, after: pair.after, in: dictated,
                                  from: dictated.startIndex)
        // Twice, with the same words around it: which one was fixed can't be told.
        guard fixed.count == 1, let range = fixed.first, dictatedSpans.count <= 1 else { return nil }
        let term = String(field[range])
        let heard = dictatedSpans.first.map { String(dictated[$0]) } ?? pair.heard
        // "Notepad++", "C#", "@Saran": symbols next to the words fall outside them, so
        // the term would be learned without them.
        guard isBounded(range, in: field), dictatedSpans.first.map({ isBounded($0, in: dictated) }) ?? true,
              !crossesBreak(term), !crossesBreak(heard) else { return nil }
        let capitalRestored = pair.meant.first?.isLowercase == true && term.first?.isUppercase == true
        return Fix(heard: heard, term: term,
                   startsSentence: capitalRestored || startsSentence(at: range.lowerBound, in: field))
    }

    /// Everywhere the words of `phrase` are in `text`, ignoring case, with the word
    /// `before` right before them and `after` right after (when given): from the first
    /// word's start to the last word's end. Only words from `from` on.
    private nonisolated static func spans(of phrase: String, before: String?, after: String?,
                                          in text: String, from: String.Index) -> [Range<String.Index>] {
        let words = DictationText.words(in: text).filter { $0.range.lowerBound >= from }
        let key = DictationText.phraseKey(phrase)
        let count = DictationText.words(in: phrase).count
        guard count > 0, words.count >= count else { return [] }
        var found: [Range<String.Index>] = []
        for start in 0...(words.count - count) {
            let end = start + count
            guard words[start..<end].map({ DictationText.key($0.text) }).joined(separator: " ") == key,
                  before.map({ start > 0 && DictationText.key(words[start - 1].text) == DictationText.key($0) }) ?? true,
                  after.map({ end < words.count && DictationText.key(words[end].text) == DictationText.key($0) }) ?? true
            else { continue }
            found.append(words[start].range.lowerBound..<words[end - 1].range.upperBound)
        }
        return found
    }

    /// Whether `range` stands alone in `text`: at its start or end, or next to whitespace or
    /// ordinary sentence and clause punctuation, quotes and brackets, not another symbol.
    nonisolated static func isBounded(_ range: Range<String.Index>, in text: String) -> Bool {
        let ordinary: (Character) -> Bool = { $0.isWhitespace || ".,;:!?…—–\"“”'‘’()[]{}".contains($0) }
        if range.lowerBound > text.startIndex, !ordinary(text[text.index(before: range.lowerBound)]) { return false }
        if range.upperBound < text.endIndex, !ordinary(text[range.upperBound]) { return false }
        return true
    }

    /// Whether a comma, a sentence or clause mark or a line break sits between two of the
    /// words of `text` (the Mac's `EditDiff` breaks). A dot or comma joining two letters or
    /// digits without spaces is part of a word ("3.5", "1,000", "voiceiq.com"), as the
    /// Mac's word splitting reads it.
    nonisolated static func crossesBreak(_ text: String) -> Bool {
        let words = DictationText.words(in: text)
        for (previous, next) in zip(words, words.dropFirst()) {
            let gap = text[previous.range.upperBound..<next.range.lowerBound]
            guard gap.contains(where: { ".!?;:,…".contains($0) || $0.isNewline }) else { continue }
            let joined = gap.count == 1 && (gap == "." || (gap == "," && previous.text.last?.isNumber == true
                && next.text.first?.isNumber == true))
            if !joined { return true }
        }
        return false
    }

    /// As the Mac judges it (`EditDiff.startsSentence`): after `.`, `!`, `?`, `…`, `:` or a
    /// line break, after a list marker (`-`, `*`, `•`) that starts a line, in a quotation
    /// opened after a comma (`He said, "Green…`), or at the start of the text.
    private nonisolated static func startsSentence(at index: String.Index, in text: String) -> Bool {
        var index = index
        var quoted = false
        var marker = false
        var spaced = false
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if character.isNewline { return true }
            if character.isWhitespace { spaced = true; continue }
            // A quote opens the word's sentence only when it touches the word.
            if "\"“”'‘’([".contains(character) { quoted = quoted || (!spaced && "\"“'‘".contains(character)); continue }
            if !marker, "-*•".contains(character) { marker = true; continue }
            if marker { return false }
            return ".!?…:".contains(character) || (quoted && character == ",")
        }
        return true
    }
}
