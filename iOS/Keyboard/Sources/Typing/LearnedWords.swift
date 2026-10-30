import Foundation
import VoiceIQBridge

/// What the keyboard learns from typing. Words and word pairs live in the
/// keyboard's own defaults, so learning works without Full Access. With Full
/// Access the most-used words also go to the App Group, where the app adds
/// them to the Dictionary and iCloud takes them to the Mac.
enum LearnedWords {
    private static let wordsKey = "typing.learnedWords"
    private static let pairsKey = "typing.learnedPairs"
    private static let clearedKey = "typing.learningClearedAt"
    private static let maxWords = 3000
    /// Next words kept per word, and words that keep any.
    private static let maxFollowers = 12
    private static let maxPrevious = 2000
    /// About 50 KB of Dictionary entries; iCloud stops syncing the whole
    /// Dictionary past 900 KB (`DictionarySync.maxBytes`).
    private static let maxSynced = 200

    /// Reads both lists. A reset from the app newer than the last one
    /// clears them first, in memory too: the extension process outlives one
    /// appearance, so the engine still holds what it loaded before.
    static func load(into user: inout UserWords, resetAt: Date?) {
        let defaults = UserDefaults.standard
        if let resetAt, resetAt.timeIntervalSince1970 > defaults.double(forKey: clearedKey) {
            defaults.removeObject(forKey: wordsKey)
            defaults.removeObject(forKey: pairsKey)
            defaults.set(resetAt.timeIntervalSince1970, forKey: clearedKey)
            user.learned = [:]
            user.pairs = [:]
        }
        if let learned = read([String: UserWords.Entry].self, wordsKey) { user.learned = learned }
        if let pairs = read([String: [String: UserWords.Entry]].self, pairsKey) { user.pairs = pairs }
    }

    /// Counts one more use of a word the list does not have. Returns whether
    /// this use made it one to add to the Dictionary.
    @discardableResult
    static func learn(_ word: String, strongly: Bool, in user: inout UserWords) -> Bool {
        let key = TypingEngine.key(of: word)
        var entry = user.learned[key] ?? UserWords.Entry(display: word, count: 0)
        let before = entry.count
        entry.count = strongly ? max(entry.count + 1, UserWords.knownAfter) : entry.count + 1
        entry.display = word
        user.learned[key] = entry
        if user.learned.count > maxWords, let rarest = user.learned.min(by: { $0.value.count < $1.value.count })?.key {
            user.learned[rarest] = nil
        }
        write(user.learned, wordsKey)
        return before < UserWords.syncedAfter && entry.count >= UserWords.syncedAfter
    }

    /// Counts `word` once more after `previous`, a word's key or
    /// `UserWords.sentenceStart`.
    static func learnPair(_ word: String, after previous: String, in user: inout UserWords) {
        let key = TypingEngine.key(of: word)
        var followers = user.pairs[previous] ?? [:]
        var entry = followers[key] ?? UserWords.Entry(display: word, count: 0)
        entry.count += 1
        entry.display = word
        followers[key] = entry
        if followers.count > maxFollowers,
           let rarest = followers.filter({ $0.key != key }).min(by: { $0.value.count < $1.value.count })?.key {
            followers[rarest] = nil
        }
        user.pairs[previous] = followers
        if user.pairs.count > maxPrevious,
           let rarest = user.pairs.filter({ $0.key != previous }).min(by: { uses($0.value) < uses($1.value) })?.key {
            user.pairs[rarest] = nil
        }
        write(user.pairs, pairsKey)
    }

    /// Hands the most-used learned words to the app. Needs Full Access.
    static func publish(_ user: UserWords) {
        let words = user.learned.values.filter { $0.count >= UserWords.syncedAfter }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.display < $1.display }
            .prefix(maxSynced).map(\.display)
        guard words != SharedStore.shared.keyboardLearnedWords else { return }
        SharedStore.shared.setKeyboardLearnedWords(words)
    }

    private static func uses(_ followers: [String: UserWords.Entry]) -> Int {
        followers.values.reduce(0) { $0 + $1.count }
    }

    private static func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func write<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
