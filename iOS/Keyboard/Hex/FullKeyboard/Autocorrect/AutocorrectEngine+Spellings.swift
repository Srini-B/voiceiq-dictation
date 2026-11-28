import Foundation

/// The typing model's own spellings (`HEXKeyboard/TypingModel/<lang>.spellings`, written by
/// `scripts/build-typing-model.py` and byte-identical to Android's): words people write with
/// capitals the model's lowercase word list can't hold ("chatgpt" -> "ChatGPT", "github" ->
/// "GitHub", "figma" -> "Figma"), whatever the phone's dictionary knows.
@MainActor
extension AutocorrectEngine {
    /// `word`, all lowercase or with only a capital first letter (a sentence's start: "Chatgpt"),
    /// as the layout language's model spells it, or as you spell the same letters with capitals
    /// ("Fitzgerald" from Contacts over the model's "FitzGerald"); nil when the model has no
    /// spelling of its own, or with Auto-capitalization off.
    func modelSpelling(of word: String) -> String? {
        let lower = word.lowercased()
        guard addsCapitals, word == lower || word.dropFirst() == lower.dropFirst(),
              let model = contextModel ?? decoder?.model, model.language == language.rawValue,
              let spelled = HexWordList.bundled(model.language, "spellings")?.text(of: lower) else { return nil }
        // Contacts and Dictionary spell names on purpose; learned words and fixes may carry a sentence's
        // capital. An all-caps contact ("UBER") is shouting, unless it is your Dictionary's spelling.
        return lexiconTerms.first { term in
            term != lower && term.caseInsensitiveCompare(lower) == .orderedSame
                && (term != term.uppercased() || isVocabularySpelling(term))
        } ?? spelled
    }

    /// A model word (lowercase) as the strip offers it before it is cased like what you typed:
    /// its own spelling, or the capital of a name the dictionary knows only capitalised ("mary"
    /// -> "Mary"), as space and Swipe typing put them in. Neither with Auto-capitalization off.
    func stripSpelling(of word: String) -> String {
        if let spelled = modelSpelling(of: word) { return spelled }
        guard addsCapitals, word.count >= 2, word == word.lowercased(), let first = word.first else { return word }
        let capitalised = first.uppercased() + word.dropFirst()
        return checker.isWordValid(capitalised) && !checker.isWordValid(word) ? capitalised : word
    }
}
