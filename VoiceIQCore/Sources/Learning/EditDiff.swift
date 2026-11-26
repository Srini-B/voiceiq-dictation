import Foundation

public struct LearnedCorrection: Equatable, Sendable {
    public let original: String
    public let replacement: String
    /// Which words of the original text `original` spans, by index, so two
    /// edits of the same word at different places stay apart.
    public let words: Range<Int>

    public init(original: String, replacement: String, words: Range<Int>) {
        self.original = original
        self.replacement = replacement
        self.words = words
    }
}

public enum LearningStep: Equatable, Sendable {
    /// A new word or phrase.
    case learn(LearnedCorrection)
    /// The words earlier edits taught from the transcript wording in
    /// `replacing` become this correction's replacement.
    case revise(replacing: [String], with: LearnedCorrection)
    /// The user put the original words back: what this taught goes.
    case forget(LearnedCorrection)
}

public enum EditDiff {
    public struct Match: Equatable, Sendable {
        public let window: String
        public let range: Range<String.Index>

        public static func == (lhs: Match, rhs: Match) -> Bool {
            lhs.window == rhs.window
        }
    }

    private struct Word {
        let text: String
        let key: String
        let range: Range<String.Index>
    }

    private struct Candidate {
        let match: Match
        let start: Int
        let end: Int
        let edits: Int
    }

    /// Locates several inserted passages together so repeated wording is assigned
    /// in insertion order instead of every passage claiming the best exact match.
    public static func locateWindows(insertions: [String], in current: String) -> [Match?] {
        let fieldWords = words(in: current)
        guard !fieldWords.isEmpty else { return Array(repeating: nil, count: insertions.count) }
        let lists = insertions.map { candidates(for: $0, in: current, fieldWords: fieldWords) }
        var memo: [State: Result] = [:]

        func solve(_ index: Int, _ minimumStart: Int) -> Result {
            guard index < lists.count else { return Result(score: 0, choices: []) }
            let state = State(index: index, minimumStart: minimumStart)
            if let cached = memo[state] { return cached }
            var best = solve(index + 1, minimumStart).prepending(nil, score: -100)
            for candidate in lists[index] where candidate.start >= minimumStart {
                let quality = 1_000 - candidate.edits * 100 - abs(candidate.end - candidate.start)
                let result = solve(index + 1, candidate.end).prepending(candidate.match, score: quality)
                if result.score > best.score { best = result }
            }
            memo[state] = best
            return best
        }

        return solve(0, 0).choices
    }

    public static func corrections(original: String, replacement: String) -> [LearnedCorrection] {
        let before = words(in: original)
        let after = words(in: replacement)
        guard !before.isEmpty, !after.isEmpty else { return [] }
        let matches = lcsPairs(before.map(\.text), after.map(\.text), caseSensitive: true)
        var output: [LearnedCorrection] = []
        var previousBefore = -1
        var previousAfter = -1

        for pair in matches + [(before.count, after.count)] {
            let removed = before[(previousBefore + 1)..<pair.0]
            let added = after[(previousAfter + 1)..<pair.1]
            if (1...3).contains(removed.count), (1...3).contains(added.count) {
                let originalText = clean(removed.map(\.text).joined(separator: " "))
                let replacementText = clean(added.map(\.text).joined(separator: " "))
                if valid(originalText), valid(replacementText), originalText != replacementText,
                   isPlausibleFix(originalText, replacementText) {
                    output.append(LearnedCorrection(
                        original: originalText,
                        replacement: replacementText,
                        words: (previousBefore + 1)..<pair.0
                    ))
                }
            }
            previousBefore = pair.0
            previousAfter = pair.1
        }
        return output
    }

    /// What learning should do with `corrections`, the edits a dictation now
    /// carries against its original text, given `earlier`, the edits it carried
    /// at the previous harvest. Edits seen before are skipped. An edit over the
    /// same words as earlier ones, because the user changed that word again or
    /// edited the word next to it, revises what those taught, so "Wispr" then
    /// "Flow" typed a few seconds apart ends as the one phrase "Wispr Flow".
    /// An earlier edit the user undid is forgotten.
    public static func steps(for corrections: [LearnedCorrection], after earlier: [LearnedCorrection]) -> [LearningStep] {
        let changed: [LearningStep] = corrections.compactMap { correction in
            guard !earlier.contains(correction) else { return nil }
            let overlapped = earlier.filter { $0.words.overlaps(correction.words) }
            guard !overlapped.isEmpty else { return .learn(correction) }
            return .revise(replacing: overlapped.map(\.original), with: correction)
        }
        let undone = earlier.filter { edit in !corrections.contains { $0.words.overlaps(edit.words) } }
        return changed + undone.map { .forget($0) }
    }

    /// Whether `replacement` could be the same words respelled rather than
    /// different wording, by letters alone. The iPhone keyboard's dictation
    /// learning uses the same bound.
    private static func isPlausibleFix(_ original: String, _ replacement: String) -> Bool {
        let a = Array(original.lowercased().filter { $0.isLetter || $0.isNumber })
        let b = Array(replacement.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !a.isEmpty, !b.isEmpty else { return false }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count] <= max(2, max(a.count, b.count) / 2)
    }

    private struct State: Hashable {
        let index: Int
        let minimumStart: Int
    }

    private struct Result {
        let score: Int
        let choices: [Match?]

        func prepending(_ match: Match?, score addition: Int) -> Result {
            Result(score: score + addition, choices: [match] + choices)
        }
    }

    /// Windows of the field within `allowedEdits` word edits of the insertion.
    ///
    /// Words are interned to integers and one Levenshtein table per start
    /// position yields the distance to every window length at once, so the
    /// cost is O(field × insertion²) instead of the O(field × insertion³) of
    /// scoring each window separately. Starts whose window cannot contain
    /// enough of the insertion's words are skipped before any table is built,
    /// which is most of a long document.
    private static func candidates(for insertion: String, in current: String, fieldWords: [Word]) -> [Candidate] {
        let source = words(in: insertion)
        guard !source.isEmpty else { return [] }
        let allowedEdits = max(1, Int(ceil(Double(source.count) * 0.3)))
        let minimumCount = max(1, source.count - allowedEdits)
        let maximumCount = source.count + allowedEdits
        let requiredHits = source.count - allowedEdits

        var ids: [String: Int] = [:]
        func intern(_ key: String) -> Int {
            if let id = ids[key] { return id }
            ids[key] = ids.count
            return ids.count - 1
        }
        let sourceIDs = source.map { intern($0.key) }
        let sourceSet = Set(sourceIDs)
        let fieldIDs = fieldWords.map { ids[$0.key] ?? -1 }
        let isHit = fieldIDs.map { sourceSet.contains($0) }

        var hits = isHit.prefix(maximumCount).reduce(0) { $0 + ($1 ? 1 : 0) }
        var previous = [Int](repeating: 0, count: maximumCount + 1)
        var row = [Int](repeating: 0, count: maximumCount + 1)
        var found: [Candidate] = []
        found.reserveCapacity(candidateLimit + 1)
        func ranksBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.edits != rhs.edits { return lhs.edits < rhs.edits }
            return lhs.start < rhs.start
        }
        func keep(start: Int, end: Int, edits: Int) {
            if found.count == candidateLimit, let last = found.last, !(edits < last.edits || (edits == last.edits && start < last.start)) { return }
            let range = fieldWords[start].range.lowerBound..<fieldWords[end - 1].range.upperBound
            let candidate = Candidate(match: Match(window: String(current[range]), range: range), start: start, end: end, edits: edits)
            let position = found.firstIndex { ranksBefore(candidate, $0) } ?? found.count
            found.insert(candidate, at: position)
            if found.count > candidateLimit { found.removeLast() }
        }

        for start in fieldWords.indices {
            defer {
                if start + maximumCount < fieldIDs.count, isHit[start + maximumCount] { hits += 1 }
                if isHit[start] { hits -= 1 }
            }
            guard hits >= requiredHits, start + minimumCount <= fieldWords.count else { continue }
            let width = min(maximumCount, fieldWords.count - start)
            for j in 0...width { previous[j] = j }
            var aborted = false
            for (i, sourceID) in sourceIDs.enumerated() {
                row[0] = i + 1
                var rowMinimum = row[0]
                for j in 1...width {
                    let cost = fieldIDs[start + j - 1] == sourceID ? previous[j - 1] : min(previous[j - 1], previous[j], row[j - 1]) + 1
                    row[j] = cost
                    if cost < rowMinimum { rowMinimum = cost }
                }
                if rowMinimum > allowedEdits { aborted = true; break }
                swap(&previous, &row)
            }
            guard !aborted else { continue }
            for count in minimumCount...width {
                let edits = previous[count]
                guard edits <= allowedEdits else { continue }
                keep(start: start, end: start + count, edits: edits)
            }
        }
        return found
    }

    private static let candidateLimit = 24

    private static func words(in text: String) -> [Word] {
        var result: [Word] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) {
            _, range, _, _ in
            let value = String(text[range])
            result.append(Word(text: value, key: clean(value).lowercased(), range: range))
        }
        return result
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'-")))
    }

    private static func valid(_ text: String) -> Bool {
        guard (1...60).contains(text.count), text.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return !text.allSatisfy { $0.isNumber || $0.isWhitespace }
    }

    private static func lcsPairs(_ lhs: [String], _ rhs: [String], caseSensitive: Bool) -> [(Int, Int)] {
        let left = caseSensitive ? lhs : lhs.map { $0.lowercased() }
        let right = caseSensitive ? rhs : rhs.map { $0.lowercased() }
        var table = [[Int]](repeating: [Int](repeating: 0, count: right.count + 1), count: left.count + 1)
        if !left.isEmpty, !right.isEmpty {
            for i in stride(from: left.count - 1, through: 0, by: -1) {
                for j in stride(from: right.count - 1, through: 0, by: -1) {
                    table[i][j] = left[i] == right[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < left.count, j < right.count {
            if left[i] == right[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
