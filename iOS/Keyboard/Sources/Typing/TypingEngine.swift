import CoreGraphics
import Foundation

/// Where each letter sits on screen, for corrections and slide to type.
struct KeyGeometry: Equatable, Sendable {
    var centers: [Character: CGPoint]
    /// The width of one letter key, the unit every distance is measured in.
    var keyWidth: CGFloat
    var keyHeight: CGFloat

    func distance(_ a: Character, _ b: Character) -> CGFloat? {
        guard let p = centers[a], let q = centers[b] else { return nil }
        return hypot((p.x - q.x) / keyWidth, (p.y - q.y) / keyHeight)
    }
}

/// One entry in the suggestion bar.
struct Suggestion: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The letters as typed, shown in quotes; picking it keeps and learns them.
        case typed
        /// Applied on the next space or punctuation unless the user picks otherwise.
        case autocorrection
        case word
        /// A Text Replacement from iOS Settings.
        case replacement
        /// An emoji for the word typed ("pizza" → 🍕); it takes the word's place.
        case emoji
    }
    var text: String
    var kind: Kind
}

/// What FUTO's context model expects after some words, computed once per
/// context off the main thread (`SwipeRecognizer.nextWords`).
struct NextWordScores: Sendable {
    /// The words before the word at the cursor (`TypingEngine.contextWords`).
    var context: [String]
    /// Every word the model knows, spelled as it spells them ("the", "I",
    /// "don't"), with a logit: higher is likelier, and the difference of two
    /// is the log of their odds.
    var scores: [String: Double]
    /// The likeliest words, best first.
    var top: [String]

    /// - Parameter words: the model's words, best first, one per logit.
    init(context: [String], words: [String], logits: [Float]) {
        self.context = context
        scores = Dictionary(zip(words, logits.map(Double.init)), uniquingKeysWith: max)
        top = Array(words.prefix(30))
    }
}

/// Words that are not in the shipped list but are the user's: the VoiceiQ
/// Dictionary, contact names, and words learned from typing.
struct UserWords: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var display: String
        var count: Int
    }
    /// Keyed by `TypingEngine.key(of:)`.
    var learned: [String: Entry] = [:]
    var dictionary: [String: String] = [:]
    var contacts: [String: String] = [:]
    /// Words typed after a word: its key, then each next word's key.
    /// `sentenceStart` stands for the start of a sentence.
    var pairs: [String: [String: Entry]] = [:]

    /// A word typed this many times without correction is a word, and a
    /// word typed this many times after another is predicted after it.
    static let knownAfter = 2
    /// A learned word goes to the Dictionary once typed this many times, so a
    /// typo kept once or twice does not become a cleanup hint on the Mac.
    static let syncedAfter = 3
    static let sentenceStart = "."

    /// The words usually typed after `previous`, most used first.
    func followers(of previous: String) -> [Entry] {
        (pairs[previous] ?? [:]).values.filter { $0.count >= Self.knownAfter }.sorted { $0.count > $1.count }
    }

    func display(key: String) -> String? {
        if let word = dictionary[key] ?? contacts[key] { return word }
        if let entry = learned[key], entry.count >= Self.knownAfter { return entry.display }
        return nil
    }

    /// Typed words count as a little rarer than a mid-list word, more with use.
    func logProbability(key: String) -> Double? {
        if dictionary[key] != nil || contacts[key] != nil { return -11 }
        guard let entry = learned[key], entry.count >= Self.knownAfter else { return nil }
        return -13 + log(Double(entry.count))
    }

    func keys(prefix: String) -> [String] {
        (Array(dictionary.keys) + Array(contacts.keys) + learned.keys.filter { learned[$0]!.count >= Self.knownAfter })
            .filter { $0.hasPrefix(prefix) }
    }
}

/// Predictions, completions and corrections for English typing.
///
/// Scores are natural-log probabilities: the word's chance in this context
/// (the pair with the previous word when the list has it, otherwise its
/// overall frequency with a backoff penalty) plus the cost of the edits that
/// turn it into what was typed. Adjacent-key slips cost less than distant ones.
struct TypingEngine: Sendable {
    let lexicon: Lexicon
    var geometry: KeyGeometry
    var user = UserWords()
    /// Text Replacements: lowercase shortcut to its phrase.
    var replacements: [String: String] = [:]

    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
    private static let backoff = log(0.05)
    /// The typed word, when it is a word, is preferred by this much.
    private static let keepBonus = log(4.0)
    /// A correction must reach this score to be applied without asking.
    private static let autocorrectFloor = -24.0

    static func key(of word: String) -> String {
        word.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
    }

    // MARK: - Context

    struct Context: Equatable {
        /// The letters before the cursor that belong to the word being typed.
        var partial: String
        /// The word before it, when it is in the same sentence.
        var previous: String?
        /// The cursor is where a sentence starts.
        var sentenceStart: Bool
    }

    static func context(before text: String) -> Context {
        let wordCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "'’"))
        var partial = ""
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            guard text[previous].unicodeScalars.allSatisfy(wordCharacters.contains) else { break }
            index = previous
        }
        partial = String(text[index...])
        let head = text[..<index]
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        let sentenceStart = trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("!")
            || trimmed.hasSuffix("?") || head.hasSuffix("\n")
        var previous: String?
        if !sentenceStart, head.last == " " {
            let words = trimmed.split(whereSeparator: { !$0.unicodeScalars.allSatisfy(wordCharacters.contains) })
            if let last = words.last, trimmed.hasSuffix(last) { previous = String(last) }
        }
        return Context(partial: partial, previous: previous, sentenceStart: sentenceStart)
    }

    // MARK: - Suggestions

    struct Result: Equatable {
        /// Up to three, best first.
        var suggestions: [Suggestion]
        var autocorrection: Suggestion? { suggestions.first { $0.kind == .autocorrection || $0.kind == .replacement } }
    }

    /// - Parameter autocorrect: whether a correction may be marked for
    ///   applying on space. Suggestions show either way.
    /// - Parameter spellGuesses: the system spell checker's guesses, for
    ///   mistakes two edits away.
    /// - Parameter nextWords: the context model's scores for the words before
    ///   this one. They rank predictions and completions mid-sentence; at a
    ///   sentence start, and for corrections, the word list alone decides.
    func suggest(_ context: Context, autocorrect: Bool, nextWords: NextWordScores? = nil,
                 spellGuesses: (String) -> [String] = { _ in [] }) -> Result {
        let partial = context.partial
        let previousID = context.previous.flatMap(bestID(for:))
        // With no sentence-start token the model guesses poorly there: 3%
        // of first words in its top three against the starters' 17%.
        let model = context.sentenceStart ? nil : nextWords
        guard !partial.isEmpty else {
            let words = predictions(after: context.previous, sentenceStart: context.sentenceStart, model: model)
            return Result(suggestions: words.map { Suggestion(text: $0, kind: .word) })
        }
        let typedKey = Self.key(of: partial)
        if let phrase = replacements[partial.lowercased()] {
            var list = [Suggestion(text: partial, kind: .typed), Suggestion(text: phrase, kind: .replacement)]
            if let word = rank(partial, typedKey: typedKey, previousID: previousID, previousKey: nil, spellGuesses: spellGuesses).first,
               word.text.lowercased() != partial.lowercased() {
                list.append(Suggestion(text: word.text, kind: .word))
            }
            return Result(suggestions: list)
        }
        let previousKey = context.sentenceStart ? UserWords.sentenceStart : context.previous.map(Self.key(of:))
        let ranked = rank(partial, typedKey: typedKey, previousID: previousID, previousKey: previousKey, spellGuesses: spellGuesses)
        // A typed word is only changed to its own casing or contraction
        // ("monday", "cant"); an unknown one to the best different spelling.
        // A longer word is a completion the user has not chosen.
        let correction = isKnown(partial, key: typedKey)
            ? ranked.first { $0.overridesTypedWord }
            : ranked.first { $0.isCorrection && $0.score > Self.autocorrectFloor }
        // With the model, its completions go first; the correction stays the list's.
        let words = (model.map { completions(of: partial, typedKey: typedKey, previousID: previousID, previousKey: previousKey, model: $0) } ?? [])
            + ranked.map(\.text)
        if let correction {
            let rest = words.first { $0 != correction.text && $0.lowercased() != partial.lowercased() }
            return Result(suggestions: [Suggestion(text: partial, kind: .typed),
                                        Suggestion(text: correction.text, kind: autocorrect ? .autocorrection : .word)]
                + (rest.map { [Suggestion(text: $0, kind: .word)] } ?? []))
        }
        var out = Self.distinct(words).prefix(3).map { Suggestion(text: $0, kind: .word) }
        if !isKnown(partial, key: typedKey) {
            out = [Suggestion(text: partial, kind: .typed)] + out.filter { $0.text != partial }.prefix(2)
        }
        return Result(suggestions: out.isEmpty ? [Suggestion(text: partial, kind: .typed)] : out)
    }

    /// Whether the letters are a word as typed, ignoring case.
    func isKnown(_ word: String, key: String? = nil) -> Bool {
        let key = key ?? Self.key(of: word)
        if user.display(key: key) != nil { return true }
        return lexicon.words(key: key).contains { lexicon.display($0).lowercased() == word.lowercased().replacingOccurrences(of: "’", with: "'") }
    }

    private struct Candidate {
        var text: String
        var score: Double
        /// Spelled differently from what was typed, not just longer.
        var isCorrection: Bool
        /// Wins over a typed word: "cant" to "can't", "i" to "I", "monday" to "Monday".
        var overridesTypedWord: Bool
    }

    private func rank(_ partial: String, typedKey: String, previousID: Lexicon.WordID?, previousKey: String?,
                      spellGuesses: (String) -> [String]) -> [Candidate] {
        var best: [String: Candidate] = [:]
        func offer(_ display: String, score: Double, correction: Bool, overrides: Bool = false) {
            let cased = Self.matchCase(of: partial, to: display)
            let id = cased.lowercased()
            if let existing = best[id], existing.score >= score { return }
            best[id] = Candidate(text: cased, score: score, isCorrection: correction, overridesTypedWord: overrides)
        }
        let contextScore = contextModel(previousID)

        // The word as typed, and a different casing or apostrophe of it.
        for id in lexicon.words(key: typedKey) where !lexicon.flags(id).contains(.noSuggest) || isKnown(partial, key: typedKey) {
            let display = lexicon.display(id)
            let sameSpelling = display.lowercased() == partial.lowercased()
            let preferred = lexicon.flags(id).contains(.preferred) && !partial.contains("'")
            let recased = display != display.lowercased() && partial == partial.lowercased()
            offer(display, score: contextScore(id) + (sameSpelling ? Self.keepBonus : 0),
                  correction: !sameSpelling || recased, overrides: preferred || (sameSpelling && recased))
        }
        if let display = user.display(key: typedKey), let lp = user.logProbability(key: typedKey) {
            offer(display, score: lp + Self.backoff + Self.keepBonus, correction: display != partial,
                  overrides: display.lowercased() == partial.lowercased() && display != partial)
        }

        // Completions: longer words that start with what was typed.
        var completions: [(Lexicon.WordID, Double)] = []
        for id in lexicon.range(prefix: typedKey) where lexicon.key(id).count > typedKey.count {
            if lexicon.flags(id).contains(.noSuggest) { continue }
            completions.append((id, contextScore(id)))
        }
        completions.sort { $0.1 > $1.1 }
        // Each letter still to type makes a completion a little less likely.
        for (id, score) in completions.prefix(6) {
            offer(lexicon.display(id), score: score - 0.4 * Double(lexicon.key(id).count - typedKey.count), correction: false)
        }
        for key in user.keys(prefix: typedKey) where key.count > typedKey.count {
            if let display = user.display(key: key), let lp = user.logProbability(key: key) {
                offer(display, score: lp + Self.backoff, correction: false)
            }
        }
        // A word the user usually types after the previous one beats the list.
        for entry in previousKey.map(user.followers(of:)) ?? [] {
            let key = Self.key(of: entry.display)
            guard key.count > typedKey.count, key.hasPrefix(typedKey) else { continue }
            offer(entry.display, score: log(Double(entry.count)) - 0.4 * Double(key.count - typedKey.count), correction: false)
        }

        // Corrections one edit away, weighted by how close the keys are.
        if typedKey.count >= 2 {
            for (key, cost) in edits(of: typedKey) {
                for id in lexicon.words(key: key) where !lexicon.flags(id).contains(.noSuggest) {
                    offer(lexicon.display(id), score: contextScore(id) + cost, correction: true)
                }
                if let display = user.display(key: key), let lp = user.logProbability(key: key) {
                    offer(display, score: lp + Self.backoff + cost, correction: true)
                }
            }
            for guess in spellGuesses(partial).prefix(4) {
                let key = Self.key(of: guess)
                guard key != typedKey, let id = lexicon.words(key: key).first(where: { !lexicon.flags($0).contains(.noSuggest) }) else { continue }
                offer(lexicon.display(id), score: contextScore(id) - 7, correction: true)
            }
        }
        return best.values.sorted { $0.score > $1.score }
    }

    /// Longer words that start with the typed letters, blended with the
    /// context model; the words the user usually types next come first.
    private func completions(of partial: String, typedKey: String, previousID: Lexicon.WordID?,
                             previousKey: String?, model: NextWordScores) -> [String] {
        let contextScore = contextModel(previousID)
        let usual = (previousKey.map(user.followers(of:)) ?? []).map(\.display).filter {
            let key = Self.key(of: $0)
            return key.count > typedKey.count && key.hasPrefix(typedKey)
        }
        // The 200 most frequent hold the word being typed 89% of the time
        // after one letter and 98% after two (DailyDialog).
        var frequent: [(id: Lexicon.WordID, logProbability: Double)] = []
        for id in lexicon.range(prefix: typedKey)
        where lexicon.key(id).count > typedKey.count && !lexicon.flags(id).contains(.noSuggest) {
            frequent.append((id, lexicon.logProbability(id)))
        }
        frequent.sort { $0.logProbability > $1.logProbability }
        var candidates = frequent.prefix(200).map { id, _ in
            (lexicon.display(id), contextScore(id) - 0.4 * Double(lexicon.key(id).count - typedKey.count))
        }
        for key in user.keys(prefix: typedKey) where key.count > typedKey.count {
            if let display = user.display(key: key), let lp = user.logProbability(key: key) {
                candidates.append((display, lp + Self.backoff))
            }
        }
        return Self.distinct(usual + Self.blend(candidates, model)).map { Self.matchCase(of: partial, to: $0) }
    }

    /// Best first by the context model's logit plus a quarter of the list's
    /// score, both natural logs. The quarter was best on the DailyDialog and
    /// BBC News dev sets; the model alone was close. A word the model does
    /// not know gets the lowest logit of the others.
    private static func blend(_ candidates: [(word: String, list: Double)], _ model: NextWordScores) -> [String] {
        let logits = candidates.map { model.scores[$0.word] }
        let floor = logits.compactMap { $0 }.min() ?? 0
        return zip(candidates, logits).map { ($0.word, ($1 ?? floor) + 0.25 * $0.list) }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func distinct(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Every string one edit from `word`, with the log cost of the slip.
    func edits(of word: String) -> [(String, Double)] {
        let letters = Array(word)
        var out: [(String, Double)] = []
        for i in letters.indices {
            // An extra letter typed: cheaper when it doubles its neighbour.
            var deleted = letters; deleted.remove(at: i)
            let doubled = (i > 0 && letters[i - 1] == letters[i]) || (i + 1 < letters.count && letters[i + 1] == letters[i])
            out.append((String(deleted), doubled ? -3.5 : -5.5))
            // A wrong key: cheap for a neighbour, costly far away.
            for c in Self.alphabet where c != letters[i] {
                guard let distance = geometry.distance(letters[i], c), distance < 2.2 else { continue }
                var swapped = letters; swapped[i] = c
                out.append((String(swapped), -2.5 - 2.6 * Double(distance * distance)))
            }
            if i + 1 < letters.count, letters[i] != letters[i + 1] {
                var transposed = letters; transposed.swapAt(i, i + 1)
                out.append((String(transposed), -4.5))
            }
        }
        // A letter left out.
        for i in 0...letters.count {
            for c in Self.alphabet {
                var inserted = letters; inserted.insert(c, at: i)
                let doubles = (i > 0 && letters[i - 1] == c) || (i < letters.count && letters[i] == c)
                out.append((String(inserted), doubles ? -2.8 : -6))
            }
        }
        return out
    }

    /// ln P(word | previous word): the pair when the list has it, otherwise
    /// the word's own frequency with a backoff penalty.
    private func contextModel(_ previousID: Lexicon.WordID?) -> (Lexicon.WordID) -> Double {
        let lexicon = lexicon
        let pairs = previousID.map { Dictionary(lexicon.followers(of: $0, limit: .max), uniquingKeysWith: max) } ?? [:]
        return { id in pairs[id] ?? (lexicon.logProbability(id) + Self.backoff) }
    }

    // MARK: - Next word

    private func bestID(for word: String) -> Lexicon.WordID? {
        let ids = lexicon.words(key: Self.key(of: word))
        return ids.first { lexicon.display($0).lowercased() == word.lowercased() } ?? ids.first
    }

    private static let sentenceStarters = ["I", "The", "I'm"]

    /// The words the user usually types next come first, then the list's,
    /// or with `model` the list's and the model's likeliest, blended.
    func predictions(after previous: String?, sentenceStart: Bool, model: NextWordScores? = nil) -> [String] {
        let previousKey = sentenceStart ? UserWords.sentenceStart : previous.map(Self.key(of:))
        let usual = previousKey.map { user.followers(of: $0).map(\.display) } ?? []
        let previousID = sentenceStart ? nil : previous.flatMap(bestID(for:))
        var words: [String]
        if let previousID {
            words = lexicon.followers(of: previousID, limit: 12)
                .filter { !lexicon.flags($0.0).contains(.noSuggest) }
                .map { lexicon.display($0.0) }
        } else {
            words = Self.sentenceStarters
        }
        if let model {
            let contextScore = contextModel(previousID)
            let candidates = Self.distinct(model.top + words).compactMap { word -> (String, Double)? in
                guard let id = listID(word), !lexicon.flags(id).contains(.noSuggest),
                      word.first?.isLetter == true, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
                return (word, contextScore(id))
            }
            words = Self.blend(candidates, model)
        }
        return Array(Self.distinct(usual + words).prefix(3))
    }

    /// The list's entry for a word, with its exact spelling if it has one:
    /// "may" and not "May".
    private func listID(_ word: String) -> Lexicon.WordID? {
        let ids = lexicon.words(key: Self.key(of: word))
        return ids.first { lexicon.display($0) == word } ?? ids.first { lexicon.display($0).lowercased() == word.lowercased() }
    }

    // MARK: - Context model

    /// The last ten words before the cursor on its line, as FUTO's context
    /// model takes them: split at anything but letters, digits, "_" and
    /// apostrophes, as FUTO Keyboard does, with ’ as '. The model knows a
    /// word as written mid-sentence ("the", "I", "London"), so a word that
    /// starts a sentence, or that the list lacks as typed, is lowercased
    /// when the list has it lowercase: "The" and "THANKS" give "the" and "thanks".
    func contextWords(before text: String) -> [String] {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        var words: [(word: String, startsSentence: Bool)] = []
        var word = "", startsSentence = true
        for character in line.replacingOccurrences(of: "’", with: "'") + " " {
            if character.isLetter || character.isNumber || character == "_" || character == "'" {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                words.append((word, startsSentence))
                word = ""
                startsSentence = false
            }
            if ".!?".contains(character) { startsSentence = true }
        }
        return words.suffix(10).map { word, startsSentence in
            let lower = word.lowercased()
            return lower != word && (startsSentence || !hasSpelling(word)) && hasSpelling(lower) ? lower : word
        }
    }

    private func hasSpelling(_ word: String) -> Bool {
        lexicon.words(key: Self.key(of: word)).contains { lexicon.display($0) == word }
    }

    /// The word as the user or the list spells it: "so" for a capitalized
    /// "So", "I" for "i", a name as saved.
    func spelling(of word: String) -> String {
        if let display = user.display(key: Self.key(of: word)) { return display }
        return bestID(for: word).map(lexicon.display) ?? word
    }

    // MARK: - Casing

    /// "Hel" makes "Hello", "HEL" makes "HELLO", and "iphone" keeps "iPhone".
    static func matchCase(of typed: String, to word: String) -> String {
        let letters = typed.filter(\.isLetter)
        if letters.count > 1, letters == letters.uppercased() { return word.uppercased() }
        if let first = letters.first, first.isUppercase, let head = word.first {
            return head.uppercased() + word.dropFirst()
        }
        return word
    }
}
