import FluidAudio
import Foundation
import VoiceIQSpeech

enum EnglishText {
    /// Final transcripts only. `original` is the raw decoder text; `corrected`
    /// carries any vocabulary fix and is the input to inverse normalization.
    /// Normalization that yields nothing falls back to its input.
    static func output(original: String, corrected: String? = nil, confidence: Float? = nil) -> LocalSpeechOutput? {
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }
        let corrected = corrected?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? original
        let normalized = TextNormalizer().normalizeSentence(corrected)
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? corrected
        return LocalSpeechOutput(original: original, normalized: normalized, confidence: confidence)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
