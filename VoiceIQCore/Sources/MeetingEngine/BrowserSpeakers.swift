import Foundation
import VoiceIQSpeech

/// The far side's speakers from the VoiceiQ Meetings Chrome extension: which
/// WebRTC source was loud when, one source per participant, and the names the
/// meeting page lit as talking (`BrowserSpeakerEvent`). It knows people apart
/// that sound alike, which diarizing the audio cannot always do, so where it
/// has a word covered it decides who said it, and the names name them.
public enum BrowserSpeakers {
    static let fileName = "browser-speakers.json"

    struct Saved: Codable, Equatable {
        /// The meeting's start, Unix milliseconds: event times are counted from it.
        var start: Double
        var events: [BrowserSpeakerEvent]
    }

    /// Copies the events of the meeting's tab from the extension's log into
    /// the meeting folder, where a retry finds them too. With several call
    /// tabs open, the one on the detected meeting page, else the busiest. A
    /// call in a known call app has none: a browser tab is another call.
    public static func save(meta: MeetingMeta, folder: URL, logRoot: URL? = nil) {
        guard let end = meta.endedAt else { return }
        #if os(macOS)
        // An app the detector only found to look like a call can be a Chromium browser it does not list.
        if case let .app(id, _) = meta.source, CallApps.known[id] != nil { return }
        #endif
        let events = BrowserSpeakerLog.events(from: meta.startedAt.addingTimeInterval(-5), to: end.addingTimeInterval(5), root: logRoot)
        let tabs = Dictionary(grouping: events) { "\($0.tab) \($0.page)" }.values
            .filter { tab in tab.contains { !$0.active.isEmpty } }
        var host: String?
        if case let .browser(_, page) = meta.source { host = page }
        // `host` can be a title match ("Meet - ") rather than a host, so no match still falls back.
        let onPage = tabs.filter { tab in host.map { tab[0].page.hasPrefix($0) } ?? false }
        guard let tab = (onPage.isEmpty ? Array(tabs) : onPage).max(by: { busy($0) < busy($1) }) else { return }
        let saved = Saved(start: meta.startedAt.timeIntervalSince1970 * 1000, events: tab)
        try? JSONEncoder().encode(saved).write(to: folder.appendingPathComponent(fileName), options: .atomic)
        Log.meeting.info("browser speakers: \(Set(tab.flatMap(\.active)).count, privacy: .public) sources on \(URL(string: "https://\(tab[0].page)")?.host ?? "a page", privacy: .public)")
        BrowserSpeakerLog.prune(root: logRoot)
    }

    private static func busy(_ events: [BrowserSpeakerEvent]) -> Int { events.filter { !$0.active.isEmpty }.count }

    /// How long one event holds without the next: the extension repeats the
    /// state every second while anyone talks, so a longer gap is a lost page.
    static let hold: Double = 3
    /// A word counts as said while its source was loud this close to it.
    static let slack: Double = 0.3
    /// How long a meeting page may keep the last speaker's tile lit, or take
    /// to light the next one, after the voice changed.
    static let tileLag: Double = 1.5

    /// Far-side words relabelled by the extension's timeline; the owner's
    /// words stay theirs. A word whose time overlaps one source's loud
    /// stretches more than twice as much as any other's is that source's.
    /// Any other far-side word goes where most of its
    /// diarizer speaker's words went. Without a timeline in the folder, or
    /// with one that covers too few words to be this meeting's, the words
    /// come back as they were.
    public static func apply(_ words: [TimedWord], folder: URL) -> [TimedWord] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return words }
        return apply(words, saved: saved)
    }

    static func apply(_ words: [TimedWord], saved: Saved) -> [TimedWord] {
        // One source is a call with one person, or a service that mixes
        // everyone into one stream with no contributing sources (Zoom). There
        // the names the page lit as talking tell people apart when it lit two
        // or more; otherwise the diarizer knows better.
        let timeline: Saved, byNames: Bool
        if tellsPeopleApart(saved.events) { (timeline, byNames) = (saved, false) }
        else if Set(saved.events.flatMap { $0.names ?? [] }).count >= 2 { (timeline, byNames) = (byName(saved), true) }
        else { return words }
        let spans = Dictionary(grouping: spans(timeline), by: \.id).mapValues { $0.map(\.range).sorted { $0.lowerBound < $1.lowerBound } }
        let longest = hold + 2 * slack
        // Judged by overlap, not the word's midpoint: the recognizer often
        // starts a word half a second early or stretches the last word of a
        // turn over the silence after it.
        func loudest(from start: Double, to end: Double) -> String? {
            let covered = spans.mapValues { ranges -> Double in
                // No stretch is longer than `longest`, so earlier ones end before `start`.
                var low = 0, high = ranges.count
                while low < high {
                    let middle = (low + high) / 2
                    if ranges[middle].lowerBound < start - longest { low = middle + 1 } else { high = middle }
                }
                var total = 0.0, reached = start
                for range in ranges[low...] {
                    guard range.lowerBound < end else { break }
                    let upper = min(range.upperBound, end)
                    if upper > reached { total += upper - max(range.lowerBound, reached); reached = upper }
                }
                return total
            }.filter { $0.value > 0 }.sorted { $0.value > $1.value }
            guard let best = covered.first else { return nil }
            return covered.count == 1 || best.value > 2 * covered[1].value ? best.key : nil
        }
        let far = words.indices.filter { words[$0].speaker != MeetingSpeaker.you }
        var heard: [Int: String] = [:]
        for index in far {
            let word = words[index]
            if let id = loudest(from: word.start, to: max(word.end, word.start + 0.01)) { heard[index] = id }
        }
        guard !far.isEmpty, Double(heard.count) >= 0.3 * Double(far.count) else { return words }
        if byNames { heard = steadied(heard, words: words) }
        var votes: [String: [String: Double]] = [:]
        for (index, id) in heard {
            votes[words[index].speaker, default: [:]][id, default: 0] += max(words[index].end - words[index].start, 0.1)
        }
        let likely = votes.mapValues { $0.max { $0.value < $1.value }!.key }
        var out = words
        for index in far {
            out[index].speaker = "browser " + (heard[index] ?? likely[words[index].speaker] ?? "diarizer \(words[index].speaker)")
        }
        return renumber(out)
    }

    /// Lit tiles trail the voices, so the first `tileLag` seconds of a
    /// diarizer turn can still show the previous speaker's name. Those words
    /// take the name heard first after that stretch of the same turn; a turn
    /// too short to have one keeps no name there, so its words follow the
    /// diarizer. Later changes of name within a turn still split it: that is
    /// how one mixed stream is told apart.
    static func steadied(_ heard: [Int: String], words: [TimedWord]) -> [Int: String] {
        var out = heard, index = 0
        while index < words.count {
            var end = index
            while end + 1 < words.count, words[end + 1].speaker == words[index].speaker { end += 1 }
            let settle = words[index].start + tileLag
            if words[index].speaker != MeetingSpeaker.you {
                let settled = (index...end).first(where: { words[$0].start >= settle && heard[$0] != nil }).flatMap { heard[$0] }
                for word in index...end where words[word].start < settle && heard[word] != nil { out[word] = settled }
            }
            index = end + 1
        }
        return out
    }

    /// Ids other than the owner's renumbered in order of first appearance, so
    /// the list reads Speaker 1, Speaker 2 with no gaps.
    static func renumber(_ words: [TimedWord]) -> [TimedWord] {
        var mapping: [String: String] = [MeetingSpeaker.you: MeetingSpeaker.you]
        return words.map { word in
            if mapping[word.speaker] == nil { mapping[word.speaker] = "s\(mapping.count)" }
            var renamed = word; renamed.speaker = mapping[word.speaker]!; return renamed
        }
    }

    /// At least two sources were loud. Stream ids alone (`ssrc`) must also
    /// take turns: a mixed stream that reconnects comes back under a new id,
    /// so its ids follow one another and none is loud again. Turns count only
    /// where one stream was loud, because the old and new stream can overlap.
    static func tellsPeopleApart(_ events: [BrowserSpeakerEvent]) -> Bool {
        let ids = Set(events.flatMap(\.active))
        guard ids.count >= 2 else { return false }
        if ids.contains(where: { $0.hasPrefix("csrc:") }) { return true }
        var order: [String] = []
        for event in events where event.active.count == 1 && event.active[0] != order.last { order.append(event.active[0]) }
        return Set(order).count < order.count
    }

    /// Each source's loud stretches, in meeting seconds.
    static func spans(_ saved: Saved) -> [(id: String, range: ClosedRange<Double>)] {
        let events = saved.events
        return events.indices.flatMap { index -> [(id: String, range: ClosedRange<Double>)] in
            let event = events[index]
            let start = (event.t - saved.start) / 1000
            let next = index + 1 < events.count ? (events[index + 1].t - saved.start) / 1000 : start + hold
            let end = min(next, start + hold)
            return event.active.map { ($0, (start - slack)...(end + slack)) }
        }
    }

    /// The timeline with the names the page lit in place of the sources.
    static func byName(_ saved: Saved) -> Saved {
        Saved(start: saved.start, events: saved.events.map { event in
            var named = event; named.active = event.names ?? []; return named
        })
    }

    /// Names the far-side speakers of a finished transcript, from any
    /// provider, by the names the meeting page lit while they talked. A
    /// speaker takes a name lit for at least half of their talk and more than
    /// twice as long as any other, not counting the first `tileLag` seconds
    /// after the speaker changes; a name goes to one speaker only, the one
    /// it overlaps most. These names win over the ones read off the screen,
    /// and every lit name joins `seen`. Without names in the folder, `screen`
    /// comes back as it was.
    public static func name(_ screen: ScreenNames?, transcript: [TranscriptSegment], folder: URL) -> ScreenNames? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return screen }
        return name(screen, transcript: transcript, saved: saved)
    }

    static func name(_ screen: ScreenNames?, transcript: [TranscriptSegment], saved: Saved) -> ScreenNames? {
        // A redo keeps the meta, and its speaker ids may have changed since these names were given.
        var screen = screen
        if let fromScreen = screen?.speakers.filter({ $0.value.talkSeconds == nil }) { screen?.speakers = fromScreen }
        let named = byName(saved)
        let lit = Dictionary(grouping: spans(named), by: \.id).mapValues { merged($0.map(\.range)) }
        guard !lit.isEmpty else { return screen }
        var overlap: [String: [String: Double]] = [:], talked: [String: Double] = [:]
        // Tiles trail the voices: until `tileLag` seconds after the speaker
        // changes, they still show who spoke before, across every segment of
        // that turn.
        var previous: String?, settled = -Double.infinity
        for segment in transcript {
            guard let first = segment.start, let end = segment.end else { continue }
            if segment.speaker != previous { settled = first + tileLag }
            previous = segment.speaker
            let start = max(first, settled)
            guard segment.speaker != MeetingSpeaker.you, end > start else { continue }
            talked[segment.speaker, default: 0] += end - start
            for (name, ranges) in lit {
                let covered = ranges.reduce(0) { $0 + max(0, min($1.upperBound, end) - max($1.lowerBound, start)) }
                if covered > 0 { overlap[segment.speaker, default: [:]][name, default: 0] += covered }
            }
        }
        let candidates = overlap.compactMap { speaker, names -> (speaker: String, name: String, seconds: Double)? in
            let ranked = names.sorted { $0.value > $1.value }
            let best = ranked[0], talk = talked[speaker] ?? 0
            guard best.value >= 0.5 * talk, ranked.count == 1 || best.value > 2 * ranked[1].value else { return nil }
            return (speaker, best.key, best.value)
        }.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.speaker < $1.speaker }
        let talk = self.talk(named)
        var out = screen ?? ScreenNames(seen: [], speakers: [:]), used = Set<String>()
        for candidate in candidates where !used.contains(candidate.name) {
            used.insert(candidate.name)
            out.speakers = out.speakers.filter { $0.value.name != candidate.name }
            out.speakers[candidate.speaker] = .init(
                name: candidate.name, seen: Int(candidate.seconds.rounded()), of: Int((talked[candidate.speaker] ?? 0).rounded()),
                talkStart: talk[candidate.name]?.start, talkSeconds: talk[candidate.name]?.seconds)
        }
        let byTime = talk.sorted { $0.value.seconds != $1.value.seconds ? $0.value.seconds > $1.value.seconds : $0.key < $1.key }.map(\.key)
        out.seen = Array((byTime + out.seen.filter { !talk.keys.contains($0) }).prefix(ScreenSpeakerNames.seenLimit))
        return out
    }

    /// When the page first lit each name, in meeting seconds, and for how
    /// many seconds in all; an event lasts as in `spans`, without the slack.
    /// Only time after the recording started counts.
    static func talk(_ saved: Saved) -> [String: (start: Double, seconds: Double)] {
        var out: [String: (start: Double, seconds: Double)] = [:]
        for (index, event) in saved.events.enumerated() {
            let start = (event.t - saved.start) / 1000
            let next = index + 1 < saved.events.count ? (saved.events[index + 1].t - saved.start) / 1000 : start + hold
            let from = max(start, 0), to = min(next, start + hold)
            guard to > from else { continue }
            for name in event.active {
                let before = out[name] ?? (from, 0)
                out[name] = (min(before.start, from), before.seconds + to - from)
            }
        }
        return out
    }

    /// Overlapping ranges joined, in order.
    static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { out.append(range) }
        }
        return out
    }
}
