import Foundation

/// Name-like text read off the screen at one moment of a recording.
public struct ScreenNameSample: Codable, Equatable, Sendable {
    /// Seconds from the start of the recording.
    public var time: Double
    public var names: [String]
    /// Names marked as the note owner's own ("Priya Raman (me)", "Priya (Host, me)", "Priya (You)").
    public var me: [String]?
    /// Lone capitalised words on a line of their own ("Nihal"). Mostly UI;
    /// `match` keeps the ones that stay on screen and are no UI word.
    public var single: [String]?
    /// People in the call, the owner included, from the call app's
    /// participants button ("People (3)").
    public var count: Int?
    public init(time: Double, names: [String], me: [String]? = nil, single: [String]? = nil, count: Int? = nil) {
        self.time = time; self.names = names; self.me = me; self.single = single; self.count = count
    }
}

/// What the screen said about who was in the meeting.
public struct ScreenNames: Codable, Equatable, Sendable {
    public struct Match: Codable, Equatable, Sendable {
        public var name: String
        /// Snapshots showing the name while only this speaker talked, out of all such snapshots.
        public var seen: Int
        public var of: Int
        /// Why the name was given, when it was not seen on screen while they talked.
        public var reason: String? = nil
    }
    /// Name-like text seen on screen, most frequent first. Can hold titles or
    /// product names; the notes model picks out the people.
    public var seen: [String]
    /// Speaker id → the name on screen while that speaker alone was talking.
    /// "you" comes from the owner marker call apps put on the user's own tile or row.
    public var speakers: [String: Match]
    /// How many other people the call showed (its participant count), when it
    /// showed any.
    public var remote: Int?
    /// The call had more other people than the transcript has far-side
    /// speakers: one speaker id probably holds several people. Silent
    /// listeners count too, so this is a likelihood, not a finding.
    public var probablyMerged: Bool?

    public init(seen: [String], speakers: [String: Match], remote: Int? = nil, probablyMerged: Bool? = nil) {
        self.seen = seen; self.speakers = speakers; self.remote = remote; self.probablyMerged = probablyMerged
    }
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

    /// Lone capitalised words on a line of their own, such as a tile reading
    /// "Nihal". `candidates` drops them since most are UI ("Meet", "Chat");
    /// `match` keeps the ones that stay on screen and are not UI words.
    public static func singleNames(in lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.wholeMatch(of: single) != nil, !uiWords.contains(text.lowercased()), !out.contains(text) else { continue }
            out.append(text)
        }
        return out
    }

    /// People in the call from a participants button or header: "People (3)",
    /// "Participants 3", "Show everyone (3)", "3 participants".
    public static func participantCount(in lines: [String]) -> Int? {
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = text.wholeMatch(of: countAfter) ?? text.wholeMatch(of: countBefore), let count = Int(match.output.1), count > 0 {
                return count
            }
        }
        return nil
    }

    nonisolated(unsafe) private static let single = #/\p{Lu}[\p{L}'’.-]{1,30}/#
    nonisolated(unsafe) private static let countAfter = #/(?i:people|participants|attendees|everyone|show everyone|in call|in this call)\s*[(:]?\s*(\d{1,4})\s*\)?/#
    nonisolated(unsafe) private static let countBefore = #/(\d{1,4})\s+(?i:participants|people|attendees|in call)/#

    /// Single words call apps and browsers show that are not names.
    static let uiWords: Set<String> = [
        "meet", "chat", "people", "participants", "attendees", "everyone", "activities", "present", "presenting",
        "presentation", "you", "me", "host", "cohost", "mute", "unmute", "muted", "camera", "microphone", "mic", "more",
        "leave", "join", "share", "record", "recording", "reactions", "captions", "settings", "details", "info", "apps",
        "view", "gallery", "speaker", "spotlight", "pin", "unpin", "raise", "hand", "search", "admit", "remove",
        "google", "teams", "zoom", "slack", "discord", "webex", "jitsi", "whereby", "chrome", "calendar", "gmail",
        "inbox", "home", "meeting", "meetings", "call", "calls", "video", "audio", "connecting", "waiting", "lobby",
        "effects", "whiteboard", "layout", "tiles", "sidebar", "fullscreen", "close", "cancel", "done", "ok", "send",
        "message", "messages", "notifications", "help", "feedback", "menu", "options", "network", "controls",
        "toolbar", "new", "open", "edit", "file", "window", "tab", "tabs", "bookmarks", "history", "profile",
        "account", "back", "forward", "reload", "live", "rec", "busy", "away", "offline", "available", "guest",
        "now", "today", "yesterday", "files", "notes", "tasks", "contacts", "react", "hide", "show", "unknown",
        // Chrome's own bars over a call page (2026-11-28 probe: "Infobar Container", "Relaunch", "Install"),
        // vdo.ninja's label on a silent tile ("No Audio") and its list of guests
        // off stage in an active-speaker view ("Not Visible", 2026-11-28 probe).
        "infobar", "container", "relaunch", "install", "update", "no", "not", "visible",
    ]

    /// Other people the call showed: the participants button less the owner.
    /// A count read in only one snapshot is a misread.
    public static func expectedRemote(samples: [ScreenNameSample]) -> Int? {
        var counts: [Int: Int] = [:]
        for count in samples.compactMap(\.count) { counts[count, default: 0] += 1 }
        guard let count = counts.filter({ $0.value >= minimumSeen }).keys.max() else { return nil }
        return max(0, count - 1)
    }

    /// `expectedRemote` from what a meeting folder kept.
    public static func expectedRemote(folder: URL) -> Int? {
        let samples = (try? JSONDecoder().decode([ScreenNameSample].self,
                                                 from: Data(contentsOf: folder.appendingPathComponent("screen-names.json")))) ?? []
        return expectedRemote(samples: samples)
    }

    nonisolated(unsafe) private static let mine = #/^(\p{Lu}[\p{L}'’.-]+(?: \p{Lu}[\p{L}'’.-]+){0,3})\s*\((?:[^)]*,\s*)?(?i:me|you)\)/#

    nonisolated(unsafe) private static let counter = #/.*\(\d+\)/#
    nonisolated(unsafe) private static let tag = #/^(\p{Lu}[\p{L}'’.-]+(?: \p{Lu}[\p{L}'’.-]+){0,3})\s*(?:[-–|(,]|$)/#

    public static func match(samples: [ScreenNameSample], transcript: [TranscriptSegment]) -> ScreenNames? {
        guard !samples.isEmpty else { return nil }
        let (steadied, cut, partial) = withSteadySingles(samples)
        let samples = folded(steadied.map { sample in
            var out = sample
            out.names.removeAll(where: isUIText)
            return out
        })
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
                guard seen >= minimumSeen, share >= minimumShare, lift >= minimumLift, !partial.contains(name) else { continue }
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

        // A name always on screen tells nothing about who talked when, but
        // with one other person in the call and one far-side speaker, it is
        // theirs.
        let far = Set(transcript.map(\.speaker)).subtracting([MeetingSpeaker.you])
        let remote = expectedRemote(samples: samples)
        let owners = Set(marked.keys)
        let others = total.filter { $0.value * 2 >= samples.count && !owners.contains($0.key) }.map(\.key)
        // A dropped cut tag may have been a second person ("Dan" beside "Dana
        // Smith"), and a kept partial one is; unless the participant count
        // says there is only one.
        if far.count == 1, let speaker = far.first, speakers[speaker] == nil, others.count == 1, (remote ?? 1) <= 1,
           (!cut && partial.isEmpty) || remote == 1,
           !used.contains(others[0]) {
            speakers[speaker] = .init(name: others[0], seen: total[others[0]] ?? 0, of: samples.count)
        }
        let ranked = total.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let merged = remote.map { !far.isEmpty && $0 > far.count }
        return ScreenNames(seen: Array(ranked.prefix(seenLimit)), speakers: speakers, remote: remote,
                           probablyMerged: merged == true ? true : nil)
    }

    /// The one far-side speaker left without a name gets the one invitee left
    /// unmatched, when the invite lists as many other people as the far side
    /// has voices and that speaker said enough to be a person, not a stray
    /// sound. Wispr Flow names the last voice the same way, and also keeps the
    /// number when the evidence is short of that.
    /// `named` holds the far-side names already known, by speaker id.
    public static func byElimination(_ screen: ScreenNames?, transcript: [TranscriptSegment], named: [String: String],
                                     invited: [String]) -> ScreenNames? {
        // Without the owner on their own track (a mic-only or in-room
        // recording) any voice may be the owner's, so none is known to be remote.
        guard transcript.contains(where: { $0.speaker == MeetingSpeaker.you }) else { return screen }
        let far = MeetingSpeaker.others(in: transcript)
        let unnamed = far.filter { named[$0] == nil }
        guard unnamed.count == 1, let speaker = unnamed.first, far.count == invited.count else { return screen }
        let left = invited.filter { invitee in !named.values.contains { sameName($0, invitee) } }
        let words = transcript.filter { $0.speaker == speaker }.reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard left.count == 1, words >= minimumEliminationWords else { return screen }
        var out = screen ?? ScreenNames(seen: [], speakers: [:])
        out.speakers[speaker] = .init(name: left[0], seen: 0, of: 0, reason: "The only invitee not matched to another voice")
        return out
    }

    /// Names a far-side voice that answers right after someone addresses an
    /// invitee or an on-screen name ("Nihal, can you give us the status?").
    /// MEASURED 2026-11-28: the notes model on the gateway named these voices
    /// in one run and not the next, with the same transcript; done here, the
    /// names stay the same and the notes are written with them. A voice
    /// answering two names keeps neither. Elimination waits for the notes,
    /// which can find a self-introduction ("I'm Rahul, covering for Sara").
    public static func byAddress(_ screen: ScreenNames?, transcript: [TranscriptSegment], invited: [String]) -> ScreenNames? {
        // A far-side voice that may hold two people answers for both (Neon on #129).
        guard screen?.probablyMerged != true else { return screen }
        let known = (screen?.speakers ?? [:]).values.map(\.name)
        // Known names and every invitee stay candidates, so "Sara" with Sara
        // and Sara Smith invited, or with one Sara already named, is nobody's.
        // Only a screen name that is one of those people's is dropped.
        var names: [String] = []
        for name in known + invited where !names.contains(where: { $0.lowercased() == name.lowercased() }) { names.append(name) }
        let people = names
        for name in (screen?.seen ?? []).filter({ !isUIText($0) })
        where !people.contains(where: { sameName($0, name) }) && !names.contains(name) { names.append(name) }
        var votes: [String: Set<String>] = [:]
        for (index, turn) in transcript.enumerated() {
            guard let name = addressed(in: turn.text, among: names), !known.contains(where: { sameName($0, name) }),
                  // The very next segment: one where the addresser goes on means no answer came.
                  index + 1 < transcript.count, case let answer = transcript[index + 1], answer.speaker != turn.speaker,
                  answer.speaker != MeetingSpeaker.you, screen?.speakers[answer.speaker] == nil,
                  // Speech that overlaps the address is an interjection, not the answer.
                  (answer.start ?? .infinity) >= (turn.end ?? 0) - lag,
                  // "Sara is out today": an answer about the person is not from them.
                  !answer.text.split(whereSeparator: { !$0.isLetter }).contains(where: { heard(String($0), as: name) }) else { continue }
            votes[answer.speaker, default: []].insert(name)
        }
        var out = screen ?? ScreenNames(seen: [], speakers: [:])
        for (speaker, answered) in votes where answered.count == 1 {
            // Every vote counts, a voice that answered two names included.
            guard let name = answered.first, !votes.contains(where: { $0.key != speaker && $0.value.contains(name) }) else { continue }
            // A voice that introduced itself by another name is left to the notes.
            let introduced = transcript.filter { $0.speaker == speaker }.flatMap { introductions(in: $0.text) }
            guard introduced.allSatisfy({ heard($0, as: name) }) else { continue }
            out.speakers[speaker] = .init(name: name, seen: 0, of: 0, reason: "Answered right after being addressed as \(name)")
        }
        return screen == nil && out.speakers.isEmpty ? nil : out
    }

    nonisolated(unsafe) private static let introduction = #/(?:I['’]m|I am|[Tt]his is|[Mm]y name is) (\p{Lu}[\p{L}'’-]+)/#

    /// Names a speaker gives themselves: "I'm Rahul", "this is Dana".
    static func introductions(in text: String) -> [String] {
        text.matches(of: introduction).map { String($0.output.1) }
    }

    /// The listed name the turn's sentences open with, followed by a comma:
    /// "Sara, you first." and "Muhammed, where are we?" ("Muhammed Hafeed"),
    /// not "Thanks Alex," or "Fair point Grace." A head matching two names,
    /// or a turn addressing two people, is nobody's.
    static func addressed(in text: String, among names: [String]) -> String? {
        var found: Set<String> = []
        for sentence in text.split(whereSeparator: { ".?!".contains($0) }) {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            let head = trimmed.prefix { $0 != "," }
            guard head.count < trimmed.count else { continue }
            let words = head.split(separator: " ")
            guard (1...3).contains(words.count), words.allSatisfy({ $0.first?.isUppercase == true }),
                  !openers.contains(words[0].lowercased()) else { continue }
            let matches = names.filter { heard(String(head), as: $0) }
            if matches.count > 1 { return nil }
            found.formUnion(matches)
        }
        return found.count == 1 ? found.first : nil
    }

    /// Words that open a sentence before a comma and are not names: "Next,"
    /// is not a slide titled "Next Steps", nor "Well," Tom Wells (Neon on #129).
    static let openers: Set<String> = ["well", "next", "right", "sure", "great", "good", "wait", "thanks", "okay",
                                       "so", "first", "back", "still", "also", "just", "look", "stop", "now"]

    /// `byElimination` once the notes are written: every name the meeting
    /// shows for a far-side speaker counts as known, and the calendar's
    /// invitees are the people expected.
    public static func byElimination(meta: MeetingMeta, transcript: [TranscriptSegment], notes: MeetingNotes) -> ScreenNames? {
        var named: [String: String] = [:]
        for id in MeetingSpeaker.others(in: transcript) {
            let name = meta.displayName(id, notes: notes)
            if name != MeetingSpeaker.defaultName(id) { named[id] = name }
        }
        return byElimination(meta.screenNames, transcript: transcript, named: named, invited: meta.calendarEvent?.attendees ?? [])
    }

    /// Fewer words than this from the last unnamed voice and it may be echo or a notification sound.
    static let minimumEliminationWords = 10

    /// "Muhammed Hafeed" and "Hafeed", "Nihal" and "nihal": one name holds all of the other's words.
    /// A spoken head ("Sarah", "Muhammad") is a name when each of its words is
    /// one of the name's words or spelt within one letter in five of it, as
    /// transcription spells names ("Sara Lindqvist", "Muhammed Hafeed").
    /// MEASURED 2026-11-28: s2-echo and s3-echo heard "Muhammad" and "Sarah".
    static func heard(_ head: String, as name: String) -> Bool {
        let words = name.lowercased().split(separator: " ").map(String.init)
        return head.lowercased().split(separator: " ").allSatisfy { spoken in
            // The same first letter, so "Right," is not Chris Wright nor "Thanks," Tom Hanks.
            words.contains { $0 == spoken || ($0.first == spoken.first && min($0.count, spoken.count) >= 4
                                               && similarity($0, String(spoken)) >= 0.8) }
        }
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = Set(a.lowercased().split(separator: " ")), y = Set(b.lowercased().split(separator: " "))
        return !x.isEmpty && !y.isEmpty && (x.isSubset(of: y) || y.isSubset(of: x))
    }

    /// Names made only of UI words, such as "Google Meet".
    static func isUIText(_ name: String) -> Bool {
        name.split(separator: " ").allSatisfy { uiWords.contains($0.lowercased()) }
    }

    /// Single words join a snapshot's names when they stay on screen in at
    /// least a quarter of the snapshots, except a steady longer name's first
    /// word: whole, it is that person ("Muhammed" of "Muhammed Hafeed"); cut
    /// short by at most two letters, it is most likely their tag cut by OCR or
    /// a control bar (`cut`). MEASURED 2026-11-28, vdo.ninja: "May" of "Maya
    /// Patel" was named a speaker that was Daniel Okafor, read as "Danie". A
    /// shorter start joins but only starts another name (`partial`): a person
    /// of their own ("Dan" beside "Daniel Okafor") or a tag cut further, so it
    /// is seen but never given a voice. The cut tag shares snapshots with the
    /// full one ("May" and "Maya Patel" at 14.1 s), so co-occurrence cannot
    /// tell them apart.
    static func withSteadySingles(_ samples: [ScreenNameSample]) -> (samples: [ScreenNameSample], cut: Bool, partial: Set<String>) {
        var counts: [String: Int] = [:], named: [String: Int] = [:]
        for sample in samples {
            for word in Set(sample.single ?? []) { counts[word, default: 0] += 1 }
            for name in Set(sample.names) { named[name, default: 0] += 1 }
        }
        let firsts = named.filter { $0.value >= minimumSeen && $0.key.contains(" ") && !isUIText($0.key) }
            .keys.compactMap { $0.split(separator: " ").first.map(String.init) }
        var steady = Set<String>(), partial = Set<String>(), cut = false
        for (word, count) in counts where count >= minimumSeen && Double(count) >= 0.25 * Double(samples.count) {
            let longer = firsts.filter { $0.hasPrefix(word) }
            if longer.contains(word) { continue }
            if longer.contains(where: { $0.count - word.count <= 2 }) { cut = true; continue }
            if !longer.isEmpty { partial.insert(word) }
            steady.insert(word)
        }
        let out = samples.map { sample in
            var out = sample
            for word in sample.single ?? [] where steady.contains(word) && !out.names.contains(word) { out.names.append(word) }
            return out
        }
        return (out, cut, partial)
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
        let samples = samples.map { ScreenNameSample(time: $0.time, names: $0.names.map(withoutStatus), me: $0.me, single: $0.single, count: $0.count) }
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
            return ScreenNameSample(time: sample.time, names: names, me: sample.me?.map { canonical[$0] ?? $0 }, single: sample.single, count: sample.count)
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
