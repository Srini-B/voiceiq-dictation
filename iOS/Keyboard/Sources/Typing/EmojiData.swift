import Foundation

/// The emoji the keyboard offers (scripts/generate-keyboard-data.py): by
/// category, by the words that find them, and with their skin tones. Recents
/// and the last skin tone live in the keyboard's own defaults.
enum EmojiData {
    static let groups: [(name: String, emoji: [String])] = lines("emoji").compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), parts[1].split(separator: " ").map(String.init))
    }

    private struct Named {
        let emoji: String
        let tones: [String]
        let words: [Substring]
    }

    private static let named: [Named] = lines("emoji-words").map { line in
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        return Named(emoji: String(parts[0]),
                     tones: parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : [],
                     words: parts.count > 2 ? parts[2].split(separator: " ") : [])
    }

    /// Each emoji that takes a skin tone, to its five toned forms.
    private static let tones: [String: [String]] = Dictionary(
        named.filter { !$0.tones.isEmpty }.map { ($0.emoji, $0.tones) }, uniquingKeysWith: { a, _ in a })

    /// The word that brings up an emoji while typing ("pizza" → 🍕).
    private static let shortcuts: [Substring: String] = Dictionary(
        lines("emoji-shortcuts").compactMap { line in
            let parts = line.split(separator: "\t")
            return parts.count == 2 ? (parts[0], String(parts[1])) : nil
        }, uniquingKeysWith: { a, _ in a })

    private static func lines(_ name: String) -> [Substring] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
    }

    // MARK: - Lookup

    /// Emoji whose words start with every word of `query`, exact matches first.
    static func search(_ query: String, limit: Int = 60) -> [String] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let first = terms.first else { return [] }
        var exact: [String] = [], prefixed: [String] = []
        for item in named where terms.allSatisfy({ term in item.words.contains { $0.hasPrefix(term) } }) {
            if item.words.contains(first) { exact.append(item.emoji) } else { prefixed.append(item.emoji) }
            if exact.count >= limit { break }
        }
        return Array((exact + prefixed).prefix(limit)).map(toned)
    }

    /// The emoji for a word just typed. Two-letter words ("it", "us") are
    /// words, not flags.
    static func shortcut(for word: String) -> String? {
        guard word.count > 2 else { return nil }
        return shortcuts[Substring(word.lowercased())].map(toned)
    }

    static func skinTones(of emoji: String) -> [String]? {
        tones[base(of: emoji)].map { [base(of: emoji)] + $0 }
    }

    // MARK: - Remembered

    private static let toneKey = "typing.emojiSkinTone"
    private static let recentsKey = "typing.recentEmoji"

    /// 0 for none, 1 to 5 for light to dark.
    static var skinTone: Int {
        get { UserDefaults.standard.integer(forKey: toneKey) }
        set { UserDefaults.standard.set(newValue, forKey: toneKey) }
    }

    /// `emoji` in the last skin tone picked, when it takes one.
    static func toned(_ emoji: String) -> String {
        let tone = skinTone
        guard tone > 0, let variants = tones[emoji] else { return emoji }
        return variants[tone - 1]
    }

    /// Picking a toned emoji makes its tone the one every emoji shows in.
    static func noteSkinTone(of emoji: String) {
        if let variants = tones[base(of: emoji)] { skinTone = (variants.firstIndex(of: emoji) ?? -1) + 1 }
    }

    private static func base(of emoji: String) -> String {
        if tones[emoji] != nil { return emoji }
        return tones.first { $0.value.contains(emoji) }?.key ?? emoji
    }

    static var recents: [String] { UserDefaults.standard.stringArray(forKey: recentsKey) ?? [] }

    static func noteUsed(_ emoji: String) {
        UserDefaults.standard.set(Array(([emoji] + recents.filter { $0 != emoji }).prefix(30)), forKey: recentsKey)
    }
}
