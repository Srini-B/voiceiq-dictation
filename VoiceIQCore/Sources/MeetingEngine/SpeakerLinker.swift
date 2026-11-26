import Foundation

/// A transcribed word placed on the track's own timeline, under a meeting-wide id.
public struct TimedWord: Codable, Equatable, Sendable {
    public var text: String
    public var speaker: String
    public var start: Double
    public var end: Double
}

/// Keeps speaker ids stable across requests.
///
/// The transcription API numbers speakers per request, so "spk:0" in one
/// window says nothing about "spk:0" in the next. Each request therefore
/// starts with a few seconds of every speaker already identified, and the
/// labels the API gives those clips name the speakers in the new window.
/// MEASURED 2026-09-27 on a four-voice synthetic call cut into 80 s windows:
/// one 8 s clip per speaker linked 60% of turns correctly; up to 20 s per
/// speaker in several clips linked 100%.
public enum SpeakerLinker {
    /// Reference audio per known speaker.
    static let anchorSeconds = 20.0
    /// Fewer than this many seconds of a label inside a speaker's clips is noise.
    static let minimumVote = 1.0
    /// The share of a label's anchor time that must fall on one speaker.
    static let minimumShare = 0.6

    /// Request-local label → meeting-wide id, from where each label spoke
    /// inside the anchor clips. A label with no clear owner stays unmapped and
    /// becomes a new speaker; an id is never given to two labels.
    public static func link(words: [DiarizedWord], anchors: [String: ClosedRange<Double>]) -> [String: String] {
        var votes: [String: [String: Double]] = [:]
        for word in words {
            guard let label = word.speaker, let start = word.start, let end = word.end else { continue }
            for (id, span) in anchors {
                let overlap = min(end, span.upperBound) - max(start, span.lowerBound)
                if overlap > 0 { votes[label, default: [:]][id, default: 0] += overlap }
            }
        }
        var mapping: [String: String] = [:], used = Set<String>()
        let ordered = votes.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }
        for (label, byID) in ordered {
            let total = byID.values.reduce(0, +)
            guard let (id, seconds) = byID.max(by: { $0.value < $1.value }), !used.contains(id),
                  seconds >= minimumVote, seconds >= minimumShare * total else { continue }
            mapping[label] = id; used.insert(id)
        }
        return mapping
    }

    /// Consecutive words of one speaker, joined across pauses under `gap`
    /// seconds. A turn that has run `paragraph` seconds ends at its next
    /// sentence end, so a long monologue reads as paragraphs with their own times.
    public static func turns(_ words: [TimedWord], gap: Double = 1.0, paragraph: Double = .infinity) -> [TimedWord] {
        var out: [TimedWord] = []
        for word in words {
            if var last = out.last, last.speaker == word.speaker, word.start - last.end < gap,
               last.end - last.start < paragraph || !endsSentence(last.text) {
                last.end = max(last.end, word.end)
                last.text = TranscriptText.join(last.text, word.text)
                out[out.count - 1] = last
            } else {
                out.append(word)
            }
        }
        return out
    }

    /// Each speaker's turns, then all turns in time order. When two people
    /// talk at once, each keeps one entry instead of alternating word by word.
    public static func overlappingTurns(_ words: [TimedWord], gap: Double = 1.0, paragraph: Double = .infinity) -> [TimedWord] {
        Dictionary(grouping: words, by: \.speaker).values
            .flatMap { turns($0.sorted { $0.start < $1.start }, gap: gap, paragraph: paragraph) }
            .sorted { $0.start < $1.start }
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!。？！".contains(last)
    }

    /// The longest turns of each speaker, up to `anchorSeconds` in total.
    public static func anchorClips(_ words: [TimedWord]) -> [String: [ClosedRange<Double>]] {
        var bySpeaker: [String: [TimedWord]] = [:]
        for turn in turns(words) where turn.end - turn.start >= 1.5 {
            bySpeaker[turn.speaker, default: []].append(turn)
        }
        return bySpeaker.mapValues { turns in
            var total = 0.0, clips: [ClosedRange<Double>] = []
            for turn in turns.sorted(by: { $0.end - $0.start > $1.end - $1.start }) where total < anchorSeconds {
                let length = min(turn.end - turn.start, anchorSeconds - total)
                clips.append(turn.start...(turn.start + length)); total += length
            }
            return clips.sorted { $0.lowerBound < $1.lowerBound }
        }
    }
}

enum TranscriptText {
    static func join(_ text: String, _ word: String) -> String {
        let punctuation = CharacterSet(charactersIn: ".,!?;:%)]}")
        if let scalar = word.unicodeScalars.first, punctuation.contains(scalar) { return text + word }
        return text.isEmpty ? word : text + " " + word
    }

    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Share of `a`'s character bigrams found in `b`. Works for any script.
    static func containment(_ a: String, in b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        func grams(_ s: String) -> Set<String> {
            let chars = Array(s)
            guard chars.count > 1 else { return [s] }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
        }
        let x = grams(a), y = grams(b)
        return Double(x.intersection(y).count) / Double(x.count)
    }
}
