import Foundation

/// Name-like text read off the screen at one moment of a recording.
public struct ScreenNameSample: Codable, Equatable, Sendable {
    /// Seconds from the start of the recording.
    public var time: Double
    public var names: [String]
    /// Names marked as the note owner's own ("Priya Raman (me)", "Priya (Host, me)", "Priya (You)").
    public var me: [String]?
    public init(time: Double, names: [String], me: [String]? = nil) { self.time = time; self.names = names; self.me = me }
}

/// What the screen said about who was in the meeting.
public struct ScreenNames: Codable, Equatable, Sendable {
    public struct Match: Codable, Equatable, Sendable {
        public var name: String
        /// Snapshots showing the name while only this speaker talked, out of all such snapshots.
        public var seen: Int
        public var of: Int
    }
    /// Name-like text seen on screen, most frequent first. Can hold titles or
    /// product names; the notes model picks out the people.
    public var seen: [String]
    /// Speaker id → the name on screen while that speaker alone was talking.
    /// "you" comes from the owner marker call apps put on the user's own tile or row.
    public var speakers: [String: Match]
}

/// Names speakers from what the meeting app showed while they talked.
///
/// Call apps show the active speaker's tile with a name tag. A name that is on
/// screen in most snapshots taken while one speaker talks, and clearly more
/// often than it is on screen overall, is that speaker's name. A name that is
/// always on screen (a gallery of tiles, a browser tab title) carries no
/// signal and only joins `seen`.
/// MEASURED 2026-10-22 on a 17-minute Zoom recording with 7 speakers and a
/// snapshot every 5 s: 6 speakers named, all correct; the seventh's tag was
/// covered by notification banners. One snapshot every 30 s named only 1.
public enum ScreenSpeakerNames {
    /// The active-speaker tile trails the voice by about a second.
    static let lag = 1.0
    static let minimumShare = 0.5
    static let minimumLift = 1.5
    static let minimumSeen = 2
    static let seenLimit = 30

    /// Name tags in OCR'd or Accessibility lines: "Priya Raman", "Priya Raman - Product",
    /// "Max Woolf | Staff …", "Alvise | Frontend", Zoom's tile "Priya Raman, Computer audio muted".
    /// Two to four capitalised words, or one followed by a separator; a comma
    /// only after two or more words, since "Thanks, Max" is not a name.
    public static func candidates(in lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            // Counters such as "Participants (3)" are UI, not a name.
            guard let match = text.firstMatch(of: tag), text.wholeMatch(of: counter) == nil else { continue }
            let name = String(match.output.1)
            let words = name.split(separator: " ").count
            let next = text.dropFirst(name.count).trimmingCharacters(in: .whitespaces).first
            guard next == nil ? words >= 2 : (next != "," || words >= 2), !out.contains(name) else { continue }
            out.append(name)
        }
        return out
    }

    /// The note owner's name, from a tag the call app marks as theirs: Zoom's
    /// "Priya Raman (me)" or "(Host, me)", Meet's and Teams' "(You)".
    public static func owner(in lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            guard let match = line.trimmingCharacters(in: .whitespaces).firstMatch(of: mine) else { continue }
            let name = String(match.output.1)
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    nonisolated(unsafe) private static let mine = #/^(\p{Lu}[\p{L}'’.-]+(?: \p{Lu}[\p{L}'’.-]+){0,3})\s*\((?:[^)]*,\s*)?(?i:me|you)\)/#

    nonisolated(unsafe) private static let counter = #/.*\(\d+\)/#
    nonisolated(unsafe) private static let tag = #/^(\p{Lu}[\p{L}'’.-]+(?: \p{Lu}[\p{L}'’.-]+){0,3})\s*(?:[-–|(,]|$)/#

    public static func match(samples: [ScreenNameSample], transcript: [TranscriptSegment]) -> ScreenNames? {
        guard !samples.isEmpty else { return nil }
        let samples = folded(samples)
        var total: [String: Int] = [:]
        for sample in samples { for name in sample.names { total[name, default: 0] += 1 } }

        var alone: [String: Int] = [:]
        var together: [String: [String: Int]] = [:]
        for sample in samples {
            guard let speaker = onlySpeaker(at: sample.time, in: transcript), speaker != MeetingSpeaker.you else { continue }
            alone[speaker, default: 0] += 1
            for name in sample.names { together[speaker, default: [:]][name, default: 0] += 1 }
        }

        struct Candidate { let speaker: String, name: String, seen: Int, of: Int, score: Double }
        var candidates: [Candidate] = []
        for (speaker, names) in together {
            let of = alone[speaker] ?? 0
            for (name, seen) in names {
                let share = Double(seen) / Double(of)
                let lift = share / (Double(total[name] ?? 0) / Double(samples.count))
                guard seen >= minimumSeen, share >= minimumShare, lift >= minimumLift else { continue }
                candidates.append(Candidate(speaker: speaker, name: name, seen: seen, of: of, score: lift * Double(seen)))
            }
        }
        var speakers: [String: ScreenNames.Match] = [:], used = Set<String>()
        // The owner's name only from the owner marker: active-speaker views never
        // show the owner their own tile, so a name on screen while they talk is
        // someone else's.
        var marked: [String: Int] = [:]
        for sample in samples { for name in Set(sample.me ?? []) { marked[name, default: 0] += 1 } }
        if let (name, count) = marked.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
           count >= minimumSeen, transcript.contains(where: { $0.speaker == MeetingSpeaker.you }) {
            speakers[MeetingSpeaker.you] = .init(name: name, seen: count, of: samples.count)
            used.insert(name)
        }
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard speakers[candidate.speaker] == nil, !used.contains(candidate.name) else { continue }
            speakers[candidate.speaker] = .init(name: candidate.name, seen: candidate.seen, of: candidate.of)
            used.insert(candidate.name)
        }
        let seen = total.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(seenLimit).map(\.key)
        return ScreenNames(seen: seen, speakers: speakers)
    }

    private static func onlySpeaker(at time: Double, in transcript: [TranscriptSegment]) -> String? {
        var found: String?
        for segment in transcript {
            guard let start = segment.start, let end = segment.end,
                  start + lag <= time, time <= end + lag else { continue }
            if let found, found != segment.speaker { return nil }
            found = segment.speaker
        }
        return found
    }

    /// Presence badges call apps draw right after the name.
    /// MEASURED 2026-10-22: Zoom's tag read "Robert Hunt Busy" and "Robert HuntBusy".
    static let statusWords = ["Busy", "Away", "Offline", "Presenting"]

    static func withoutStatus(_ name: String) -> String {
        for word in statusWords where name.hasSuffix(word) {
            let rest = name.dropLast(word.count).trimmingCharacters(in: .whitespaces)
            if rest.contains(" ") { return rest }
        }
        return name
    }

    /// OCR reads one tag several ways ("Halil Coban", "Hall Coban", "Halll Coban").
    /// Each spelling folds into the most frequent close spelling, so votes are not split.
    static func folded(_ samples: [ScreenNameSample]) -> [ScreenNameSample] {
        let samples = samples.map { ScreenNameSample(time: $0.time, names: $0.names.map(withoutStatus), me: $0.me) }
        var counts: [String: Int] = [:]
        for sample in samples { for name in Set(sample.names) { counts[name, default: 0] += 1 } }
        var heads: [String] = [], canonical: [String: String] = [:]
        for name in counts.keys.sorted(by: { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }) {
            let head = heads.first { similarity(name, $0) >= 0.8 }
            if head == nil { heads.append(name) }
            canonical[name] = head ?? name
        }
        return samples.map { sample in
            var names: [String] = []
            for name in sample.names { let head = canonical[name] ?? name; if !names.contains(head) { names.append(head) } }
            return ScreenNameSample(time: sample.time, names: names, me: sample.me?.map { canonical[$0] ?? $0 })
        }
    }

    /// 1 − edit distance / longer length, ignoring case.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var previous = row[0]; row[0] = i
            for j in 1...y.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }
}
