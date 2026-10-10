import FluidAudio
import Foundation
import VoiceIQSpeech

enum EnglishVocabulary {
    static let maxTerms = 256
    static let maxAliases = 8
    static let maxLength = 64

    /// Trims, deduplicates, and bounds the user dictionary before any decoder sees it.
    static func terms(_ terms: [LocalSpeechOptions.Term]) -> [CustomVocabularyTerm] {
        func clean(_ text: String) -> String? {
            let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.isEmpty || text.count > maxLength ? nil : text
        }
        var seen = Set<String>()
        var result: [CustomVocabularyTerm] = []
        for term in terms {
            guard result.count < maxTerms else { break }
            guard let text = clean(term.text), seen.insert(text.lowercased()).inserted else { continue }
            var aliasSeen: Set<String> = [text.lowercased()]
            let aliases = term.aliases.compactMap(clean)
                .filter { aliasSeen.insert($0.lowercased()).inserted }
                .prefix(maxAliases)
            result.append(CustomVocabularyTerm(text: text, aliases: aliases.isEmpty ? nil : Array(aliases)))
        }
        return result
    }
}

/// CTC keyword spotting and constrained rescoring loaded only from the local
/// tools pack. `VocabularyBoostingSession` is avoided because it resolves
/// tokenizer and rescorer assets from FluidAudio's default download cache.
struct ParakeetVocabulary: Sendable {
    private let context: CustomVocabularyContext
    private let spotter: CtcKeywordSpotter
    private let rescorer: VocabularyRescorer

    static func load(from directory: URL, terms: [CustomVocabularyTerm]) async throws -> ParakeetVocabulary? {
        let tokenizer = try await CtcTokenizer.load(from: directory)
        let tokenized = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: term.text, aliases: term.aliases, ctcTokenIds: ids)
        }
        guard !tokenized.isEmpty else { return nil }
        try Task.checkCancellation()
        let models = try await CtcModels.loadDirect(from: directory, variant: .ctc110m)
        try Task.checkCancellation()
        let context = CustomVocabularyContext(terms: tokenized)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: context,
            config: VocabularyRescorer.Config(spotterRescueEnabled: false),
            ctcModelDirectory: directory
        )
        return ParakeetVocabulary(
            context: context, spotter: spotter, rescorer: rescorer
        )
    }

    /// `timings` and `samples` must share time zero. Nil leaves the transcript unchanged.
    func rescore(text: String, timings: [TokenTiming], samples: [Float]) async throws -> String? {
        guard !timings.isEmpty, !samples.isEmpty else { return nil }
        let spot = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: samples, customVocabulary: context, minScore: nil
        )
        guard !spot.logProbs.isEmpty else { return nil }
        try Task.checkCancellation()
        // A dictionary entry must beat the original's acoustic score without
        // an additive bonus. The permissive rescue pass inserts unspoken terms.
        let output = rescorer.ctcTokenRescore(
            transcript: text, tokenTimings: timings, logProbs: spot.logProbs,
            frameDuration: spot.frameDuration, cbw: 0,
            marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
            minSimilarity: 0.75
        )
        Log.transcription.notice("Parakeet vocabulary: \(spot.detections.count) detections, \(output.replacements.filter(\.shouldReplace).count) replacements")
        return output.wasModified ? output.text : nil
    }
}
