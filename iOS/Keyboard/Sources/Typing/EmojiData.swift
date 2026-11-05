import Foundation

/// The emoji the keyboard offers (scripts/generate-keyboard-data.py): by
/// category, by the words that find them, and with their skin tones. Recents
/// and the last skin tone live in the keyboard's own defaults.
enum EmojiData {
    /// The newest Emoji version this iOS draws; newer ones would show as empty
    /// boxes. Per Emojipedia's Apple changelogs: Emoji 15.1 arrived in iOS 17.4,
    /// 16.0 in iOS 18.4, 17.0 in iOS 26.4. iOS 17.0 draws 15.0.
    private static let newestDrawn: Double = {
        if #available(iOS 26.4, *) { return 17.0 }
        if #available(iOS 18.4, *) { return 16.0 }
        if #available(iOS 17.4, *) { return 15.1 }
        return 15.0
    }()

    /// The data writes emoji newer than Emoji 15.0 with their version
    /// ("🫩@16.0"). Every emoji the keyboard offers passes through here, so
    /// one this iOS can't draw is nil and left out.
    private static func drawable(_ token: Substring) -> String? {
        let parts = token.split(separator: "@", maxSplits: 1)
        guard let emoji = parts.first else { return nil }
        if parts.count == 2, Double(parts[1]).map({ $0 > newestDrawn }) ?? true { return nil }
        return String(emoji)
    }

    static let groups: [(name: String, emoji: [String])] = lines("emoji").compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), parts[1].split(separator: " ").compactMap(drawable))
    }

    private struct Named {
        let emoji: String
        let tones: [String]
        let words: [Substring]
    }

    private static let named: [Named] = lines("emoji-words").compactMap { line in
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard let emoji = drawable(parts[0]) else { return nil }
        let tones = parts.count > 1 ? parts[1].split(separator: " ").map(drawable) : []
        return Named(emoji: emoji,
                     tones: tones.contains(nil) ? [] : tones.compactMap { $0 },
                     words: parts.count > 2 ? parts[2].split(separator: " ") : [])
    }

    /// Each emoji that takes a skin tone, to its five toned forms.
    private static let tones: [String: [String]] = Dictionary(
        named.filter { !$0.tones.isEmpty }.map { ($0.emoji, $0.tones) }, uniquingKeysWith: { a, _ in a })

    /// Everything above, for recents saved where newer emoji were drawn.
    private static let offered = Set(groups.flatMap(\.emoji) + tones.values.joined())

    /// The word that brings up an emoji while typing ("pizza" → 🍕), the
    /// first this iOS draws when the best is too new.
    private static let shortcuts: [Substring: String] = Dictionary(
        lines("emoji-shortcuts").compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let emoji = parts[1].split(separator: " ").lazy.compactMap(drawable).first
            else { return nil }
            return (parts[0], emoji)
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

    static var recents: [String] { (UserDefaults.standard.stringArray(forKey: recentsKey) ?? []).filter(offered.contains) }

    static func noteUsed(_ emoji: String) {
        UserDefaults.standard.set(Array(([emoji] + recents.filter { $0 != emoji }).prefix(30)), forKey: recentsKey)
    }
}
