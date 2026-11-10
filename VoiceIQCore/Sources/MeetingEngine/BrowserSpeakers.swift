import Foundation
import VoiceIQSpeech

/// The far side's speakers from the VoiceiQ Meetings Chrome extension: which
/// WebRTC source was loud when, one source per participant
/// (`BrowserSpeakerEvent`). It knows people apart that sound alike, which
/// diarizing the audio cannot always do, so where it has a word covered it
/// decides who said it.
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
        Log.meeting.info("browser speakers: \(Set(tab.flatMap(\.active)).count, privacy: .public) sources on \(tab[0].page, privacy: .public)")
        BrowserSpeakerLog.prune(root: logRoot)
    }

    private static func busy(_ events: [BrowserSpeakerEvent]) -> Int { events.filter { !$0.active.isEmpty }.count }

    /// How long one event holds without the next: the extension repeats the
    /// state every second while anyone talks, so a longer gap is a lost page.
    static let hold: Double = 3
    /// A word counts as said while its source was loud this close to it.
    static let slack: Double = 0.3

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
        // everyone into one stream with no contributing sources; the diarizer
        // knows that better.
        guard tellsPeopleApart(saved.events) else { return words }
        let spans = Dictionary(grouping: spans(saved), by: \.id).mapValues { $0.map(\.range).sorted { $0.lowerBound < $1.lowerBound } }
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
        var heard: [Int: String] = [:], votes: [String: [String: Double]] = [:]
        for index in far {
            let word = words[index]
            guard let id = loudest(from: word.start, to: max(word.end, word.start + 0.01)) else { continue }
            heard[index] = id
            votes[word.speaker, default: [:]][id, default: 0] += max(word.end - word.start, 0.1)
        }
        guard !far.isEmpty, Double(heard.count) >= 0.3 * Double(far.count) else { return words }
        let likely = votes.mapValues { $0.max { $0.value < $1.value }!.key }
        var out = words
        for index in far {
            out[index].speaker = "browser " + (heard[index] ?? likely[words[index].speaker] ?? "diarizer \(words[index].speaker)")
        }
        return renumber(out)
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
}
