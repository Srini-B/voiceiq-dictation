import Foundation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Whether a word is ordinary language, found in the system spelling
/// dictionary. Auto-learn keeps only words that are not: names, product
/// terms, jargon. Editing "They" to "we" or "There's" to "there's" fixes
/// wording or case; it does not teach the model a new word.
///
/// Words are checked in lowercase. Capitalized, the spell checker accepts
/// many unknown words as possible proper nouns ("Kubernetes", "RevenueCat");
/// lowercase, it knows "there's" and "john" but not "kubernetes", "voiceiq"
/// or "priya" (measured 2026-09-28 with macOS's English dictionaries). The
/// iPhone asks `UITextChecker` the same way, for what the keyboard learns
/// from fixes to dictated text.
@MainActor
enum CommonWords {
    /// True when every word in `text` is in the spelling dictionary.
    static func isOrdinary(_ text: String) -> Bool {
        let words = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'-"))) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return true }
        return words.allSatisfy(isKnown)
    }

    #if os(macOS)
    /// The user's English variant first (en_IN, en_GB, …), then "en", so both
    /// "colour" and "color" count as ordinary.
    private static let languages: [String] = {
        let preferred = NSSpellChecker.shared.userPreferredLanguages.first { $0.hasPrefix("en") }
        return [preferred, "en"].compactMap { $0 }.reduce(into: []) { list, language in
            if !list.contains(language) { list.append(language) }
        }
    }()

    private static func isKnown(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        return languages.contains { language in
            checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }
    #elseif canImport(UIKit)
    /// The user's English variant first, then US and British English, as far
    /// as `UITextChecker` has them, so both "colour" and "color" count as ordinary.
    private static let languages: [String] = {
        let available = UITextChecker.availableLanguages
        let preferred = Locale.preferredLanguages.first { $0.hasPrefix("en") }?.replacingOccurrences(of: "-", with: "_")
        return [preferred, "en_US", "en_GB"].compactMap { $0 }.reduce(into: []) { list, language in
            if available.contains(language), !list.contains(language) { list.append(language) }
        }
    }()

    /// Without an English dictionary every word counts as known, so nothing is learned
    /// rather than ordinary words.
    private static func isKnown(_ word: String) -> Bool {
        guard !languages.isEmpty else { return true }
        let checker = UITextChecker()
        let range = NSRange(location: 0, length: (word as NSString).length)
        return languages.contains { language in
            checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false,
                                          language: language).location == NSNotFound
        }
    }
    #else
    private static func isKnown(_ word: String) -> Bool { true }
    #endif
}

extension LearnedCorrection {
    /// Only words the language does not already have: a name, a product term,
    /// jargon. Many Indian names are English words in lowercase ("Saran",
    /// "Ram", "Raja"), so a capitalized replacement for heard wording that was
    /// not ordinary either ("Sharon" → "Saran") is still a name, unless the
    /// capital only starts a sentence ("Sara, I'm late" → "Sorry, I'm late").
    /// Changing "They" to "We" or "Then" to "Than" teaches nothing.
    @MainActor var teachesNothing: Bool {
        guard CommonWords.isOrdinary(replacement) else { return false }
        return !(nameLike && !CommonWords.isOrdinary(original))
    }

    /// The dictionary already has this word, or already learned something
    /// from the same transcript wording. `protected` entries spelled as the
    /// original, and, for a revision, an entry learned from the same wording,
    /// do not count.
    func isKnown(in entries: [DictionaryEntry], protected: Set<UUID> = [], isRevision: Bool = false) -> Bool {
        let original = original.lowercased()
        let replacement = replacement.lowercased()
        return entries.contains {
            let term = $0.term.lowercased()
            let misspelling = $0.misspelling?.lowercased()
            let learnedFrom = $0.learnedFrom?.lowercased()
            return (term == original && !protected.contains($0.id)) || term == replacement
                || misspelling == original || misspelling == replacement
                || (!isRevision && learnedFrom == original && !protected.contains($0.id))
        }
    }
}

extension DictionaryStore {
    /// Adds what one fix taught as an auto-learned word, `learnedFrom` the
    /// wording it replaced, by the rules `EditLearner` learns a new word by:
    /// not a word the dictionary has or learned from that wording, and not
    /// ordinary language (`teachesNothing`). The iPhone keyboard's fixes to
    /// dictated text come here through the app (`DictionaryAddition.learnedFrom`).
    @MainActor @discardableResult
    public func learn(_ correction: LearnedCorrection) -> Bool {
        guard !correction.isKnown(in: entries()), !correction.teachesNothing else { return false }
        return add(term: correction.replacement, learnedFrom: correction.original, source: .auto)
    }
}
