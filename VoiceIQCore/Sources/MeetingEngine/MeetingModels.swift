import CryptoKit
import Foundation

public enum CallSource: Equatable, Sendable, Codable {
    case app(bundleID: String, name: String)
    case browser(bundleID: String, host: String)
}

public enum MeetingPhase: Equatable, Sendable {
    case idle
    case callDetected(CallSource)
    case recording(MeetingID, since: Date)
    case failed(MeetingID, String)
}

public struct MeetingID: Hashable, Codable, Sendable, Identifiable {
    public let uuid: UUID
    public var id: UUID { uuid }
    public init(uuid: UUID = UUID()) { self.uuid = uuid }
}

/// One speaker turn. `speaker` is a meeting-wide id: "you" for the note
/// owner, "s1", "s2", … for everyone else. Recordings made before 2026-09-27
/// carry the API's chunk-local labels ("spk:0") and no times.
public struct TranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public var speaker: String
    public var text: String
    public var chunkIndex: Int
    /// Seconds from the start of the recording.
    public var start: Double?
    public var end: Double?
    /// Written only once the turn is edited, or when it repeats an earlier
    /// turn word for word, so transcripts saved before ids existed (and the
    /// digests sync compares) stay as they were.
    var savedID: String?
    public init(speaker: String, text: String, chunkIndex: Int, start: Double? = nil, end: Double? = nil) {
        self.speaker = speaker; self.text = text; self.chunkIndex = chunkIndex; self.start = start; self.end = end
    }

    /// Names the turn for editing and deleting (`MeetingStore.editTranscriptSegment`):
    /// stays the same when other turns are edited or deleted, and when its own words are.
    public var id: String { savedID ?? contentID }

    var contentID: String {
        let key = [speaker, text, String(chunkIndex), start.map { "\($0)" } ?? "", end.map { "\($0)" } ?? ""]
        return SHA256.hash(data: Data(key.joined(separator: "\u{1F}").utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Gives each exact repeat of an earlier turn (a second "Yeah." with no
    /// times) an id of its own.
    static func distinctIDs(_ transcript: [TranscriptSegment]) -> [TranscriptSegment] {
        var seen = Set<String>()
        return transcript.map { segment in
            var segment = segment, copy = 1
            while !seen.insert(segment.id).inserted {
                copy += 1
                segment.savedID = "\(segment.contentID)-\(copy)"
            }
            return segment
        }
    }
}

/// One heading in the transcript: a speaker and their lines, with other
/// people's one- or two-word replies as asides (`MeetingSpeaker.turns`).
public struct TranscriptTurn: Equatable, Sendable, Identifiable {
    public struct Line: Equatable, Sendable, Identifiable {
        public var segment: TranscriptSegment
        /// Someone else's short reply inside this speaker's run.
        public var aside: Bool
        public var id: String { segment.id }
        public init(segment: TranscriptSegment, aside: Bool) { self.segment = segment; self.aside = aside }
    }
    public var speaker: String
    public var lines: [Line]
    public init(speaker: String, lines: [Line]) { self.speaker = speaker; self.lines = lines }
    public var id: String { lines.first?.id ?? speaker }
    public var start: Double? { lines.first?.segment.start }
}

public enum MeetingSpeaker {
    public static let you = "you"

    /// "You", "Speaker 2", or a legacy label as stored.
    public static func defaultName(_ id: String) -> String {
        if id == you { return "You" }
        if id.hasPrefix("s"), let number = Int(id.dropFirst()) { return "Speaker \(number)" }
        return id
    }

    /// Everyone but the note owner, in order of first turn.
    public static func others(in transcript: [TranscriptSegment]) -> [String] {
        var seen: [String] = []
        for segment in transcript where segment.speaker != you && !seen.contains(segment.speaker) { seen.append(segment.speaker) }
        return seen
    }

    /// The transcript as it reads: one heading per run of one speaker's lines.
    /// A reply of one or two words from someone else ("Okay.", "Yes.") is an
    /// aside inside the run when the run's speaker goes on after it (or the
    /// transcript ends), instead of a heading of its own; a short line that
    /// opens its speaker's next turn ("Good point." then more) keeps its
    /// heading. A lone Latin letter ("a") is a transcription fragment and is
    /// left out. MEASURED 2026-11-27 on AMI ES2004a: seven headings for ten
    /// lines before asides, as "Okay." and "Yes." alternated speakers.
    public static func turns(in transcript: [TranscriptSegment]) -> [TranscriptTurn] {
        let lines = transcript.filter { !isFragment($0.text) }
        var turns: [TranscriptTurn] = []
        for (index, segment) in lines.enumerated() {
            if let last = turns.last, last.speaker == segment.speaker {
                turns[turns.count - 1].lines.append(.init(segment: segment, aside: false))
            } else if let last = turns.last, isShortReply(segment.text),
                      // Who speaks next past other short replies ("Okay." then "Yes." from two people).
                      lines[(index + 1)...].first(where: { $0.speaker == last.speaker || $0.speaker == segment.speaker || !isShortReply($0.text) })
                          .map({ $0.speaker == last.speaker }) ?? true {
                turns[turns.count - 1].lines.append(.init(segment: segment, aside: true))
            } else {
                turns.append(TranscriptTurn(speaker: segment.speaker, lines: [.init(segment: segment, aside: false)]))
            }
        }
        return turns
    }

    /// One or two words, and short: Chinese or Japanese is written without
    /// spaces, so a whole turn there is one "word" (Codex review).
    static func isShortReply(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return words <= 2 && text.count <= (isUnspaced(text) ? 6 : 20)
    }

    /// Chinese, Japanese or Thai, written without spaces between words. Korean
    /// spaces its words, so it counts words as Latin does (Neon).
    static func isUnspaced(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter(\.properties.isAlphabetic)
        let unspaced = letters.filter { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF: return true
            default: return false
            }
        }
        // Two such letters are enough: "SlackとZoomを確認します。" has more Latin letters.
        return unspaced.count >= 2
    }

    /// A single Latin letter and nothing else. "B." (an answer), "I.", a
    /// digit or a one-character word in another script stays.
    public static func isFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 1 && trimmed.first.map { $0.isASCII && $0.isLetter } == true
    }

    /// A speaker's name colour as light and dark RGB: green for the note
    /// owner, then one hue per other speaker in `others` order.
    public static func colorHex(_ id: String, others: [String]) -> (light: UInt32, dark: UInt32) {
        if id == you { return (0x188038, 0x81C995) }
        return hues[(others.firstIndex(of: id) ?? 0) % hues.count]
    }

    private static let hues: [(light: UInt32, dark: UInt32)] = [
        (0x1A73E8, 0x8AB4F8), (0x8E44C9, 0xC58AF9), (0xD35400, 0xFCAD70), (0xC2185B, 0xF48FB1),
        (0x00897B, 0x80CBC4), (0xA0790B, 0xFDD663), (0x5C6BC0, 0x9FA8DA), (0x6D4C41, 0xBCAAA4),
    ]

    /// A name the user typed wins over one the notes model found in the conversation.
    public static func displayName(_ id: String, names: [String: String], suggested: [SpeakerSuggestion]?) -> String {
        if let name = names[id], !name.isEmpty { return name }
        if let name = suggested?.first(where: { $0.label == defaultName(id) })?.name, !name.isEmpty { return name }
        return defaultName(id)
    }
}

public struct ActionItem: Codable, Equatable, Sendable {
    public var text: String
    public var owner: String?
    public var deadline: String?
    public init(text: String, owner: String? = nil, deadline: String? = nil) {
        self.text = text; self.owner = owner; self.deadline = deadline
    }
}

/// A section the notes model adds for the kind of meeting it recognised.
public struct NoteSection: Codable, Equatable, Sendable {
    public var title: String
    public var items: [String]
    public init(title: String, items: [String]) { self.title = title; self.items = items }
}

/// A name the conversation itself gives a speaker, with the words that show it.
public struct SpeakerSuggestion: Codable, Equatable, Sendable {
    public var label: String
    public var name: String?
    public var evidence: String?
    public init(label: String, name: String?, evidence: String?) { self.label = label; self.name = name; self.evidence = evidence }

    /// The model sometimes gives several quotes as a list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        evidence = (try? c.decodeIfPresent(String.self, forKey: .evidence))
            ?? (try? c.decodeIfPresent([String].self, forKey: .evidence))?.joined(separator: " / ")
    }
}

public struct MeetingNotes: Codable, Equatable, Sendable {
    /// One of `MeetingKind`'s raw values; notes made before 2026-09-27 have none.
    public var type: String?
    public var title: String
    public var summary: String
    public var sections: [NoteSection]?
    public var decisions: [String]
    public var actions: [ActionItem]
    public var notes: [String]
    public var speakers: [SpeakerSuggestion]?
    /// The people among the names seen on screen; titles and product names left out.
    public var participants: [String]?
    public init(type: String? = nil, title: String, summary: String, sections: [NoteSection]? = nil,
                decisions: [String], actions: [ActionItem], notes: [String], speakers: [SpeakerSuggestion]? = nil,
                participants: [String]? = nil) {
        self.type = type; self.title = title; self.summary = summary; self.sections = sections
        self.decisions = decisions; self.actions = actions; self.notes = notes; self.speakers = speakers
        self.participants = participants
    }

    /// The model leaves out empty lists now and then; a missing list is empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        sections = try c.decodeIfPresent([NoteSection].self, forKey: .sections)
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actions = try c.decodeIfPresent([ActionItem].self, forKey: .actions) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        speakers = try c.decodeIfPresent([SpeakerSuggestion].self, forKey: .speakers)
        participants = try c.decodeIfPresent([String].self, forKey: .participants)
    }
}

/// The kinds of meeting the notes model recognises. Each adds its own
/// sections; `general` adds none.
public enum MeetingKind: String, CaseIterable, Sendable {
    case general, standup, oneOnOne = "one_on_one", salesCall = "sales_call"
    case customerInterview = "customer_interview", jobInterview = "job_interview"
    case planning, statusUpdate = "status_update", retrospective, designReview = "design_review"
    case incidentReview = "incident_review", training, brainstorm, presentation

    public var displayName: String {
        switch self {
        case .general: return "Meeting"
        case .standup: return "Standup"
        case .oneOnOne: return "One-on-one"
        case .salesCall: return "Sales call"
        case .customerInterview: return "Customer interview"
        case .jobInterview: return "Job interview"
        case .planning: return "Planning"
        case .statusUpdate: return "Status update"
        case .retrospective: return "Retrospective"
        case .designReview: return "Design review"
        case .incidentReview: return "Incident review"
        case .training: return "Training"
        case .brainstorm: return "Brainstorm"
        case .presentation: return "Presentation"
        }
    }

    /// What the meeting looks like, for the model's choice.
    public var looksLike: String {
        switch self {
        case .general: return "anything that fits no other type"
        case .standup: return "a short round where each person gives updates and blockers"
        case .oneOnOne: return "two people, usually a manager and a report, on progress, feedback, and growth"
        case .salesCall: return "selling to a prospect or customer"
        case .customerInterview: return "learning from a user or customer about their needs"
        case .jobInterview: return "assessing a candidate for a role"
        case .planning: return "deciding what to do next, scope, priorities, and dates"
        case .statusUpdate: return "reporting progress, risks, and next steps on ongoing work"
        case .retrospective: return "looking back at finished work to improve"
        case .designReview: return "reviewing a proposed design or technical approach"
        case .incidentReview: return "analysing an outage or failure after it happened"
        case .training: return "one person teaching, onboarding, or walking others through setup or steps"
        case .brainstorm: return "generating ideas without settling on one"
        case .presentation: return "one person presenting to an audience, with questions"
        }
    }

    /// Section titles, in order. The prompt is built from this table so the
    /// model and the app can never disagree about a type's layout.
    public var sections: [(title: String, covers: String)] {
        switch self {
        case .general: return []
        case .standup: return [("Updates", "per person, what they finished and what they will do next"),
                               ("Blockers", "anything stopping someone, with who is blocked")]
        case .oneOnOne: return [("Updates", "what each person reported since last time"),
                                ("Feedback", "feedback given in either direction"),
                                ("Growth and goals", "career, goals, and development topics")]
        case .salesCall: return [("Customer context", "who the customer is and how they work today"),
                                 ("Needs and pain points", "problems they want solved"),
                                 ("Objections and concerns", "hesitations raised"),
                                 ("Budget and timeline", "money, timing, and decision process mentioned")]
        case .customerInterview: return [("Background", "the interviewee and their context"),
                                         ("Current workflow", "how they do the job today"),
                                         ("Pain points", "frustrations and problems"),
                                         ("Product feedback", "reactions to the product or idea"),
                                         ("Key insights", "the most important learnings")]
        case .jobInterview: return [("Candidate background", "experience and history described"),
                                    ("Questions and answers", "the main questions and how they were answered"),
                                    ("Strengths", "strengths shown in the conversation"),
                                    ("Concerns", "gaps or concerns raised")]
        case .planning: return [("Goals", "what the plan is meant to achieve"),
                                ("Scope and priorities", "what is in, out, and first"),
                                ("Timeline", "dates and milestones"),
                                ("Risks", "risks and dependencies")]
        case .statusUpdate: return [("Progress", "what moved forward"),
                                    ("Risks and blockers", "what is late, at risk, or stuck"),
                                    ("Coming up", "upcoming events and dates; tasks belong in actions")]
        case .retrospective: return [("Went well", "what worked"),
                                     ("Did not go well", "what did not work"),
                                     ("Improvements", "changes proposed for next time")]
        case .designReview: return [("Proposal", "what was proposed and why"),
                                    ("Options considered", "alternatives discussed"),
                                    ("Concerns and trade-offs", "objections, risks, and trade-offs")]
        case .incidentReview: return [("Timeline", "what happened, in order"),
                                      ("Impact", "who and what was affected"),
                                      ("Root cause", "why it happened"),
                                      ("Prevention", "changes to stop it recurring")]
        case .training: return [("Topics covered", "what was taught or explained"),
                                ("Steps shown", "procedures walked through, in order"),
                                ("Questions raised", "questions asked, with answers when given")]
        case .brainstorm: return [("Ideas", "ideas raised"),
                                  ("Favoured ideas", "ideas that got support")]
        case .presentation: return [("Key points", "the main points presented"),
                                    ("Questions and answers", "questions from the audience and the answers")]
        }
    }
}

public enum MeetingStatus: Codable, Equatable, Sendable {
    case recording, transcribing, summarizing, done
    case failed(String)
}

/// What a meeting waiting for Gemini still needs (`MeetingMeta.waitsForGemini`).
public enum GeminiStep: String, Codable, Sendable {
    /// Transcribe the recording, then write the notes.
    case transcript
    /// Write the notes from the saved transcript.
    case notes
}

public struct MeetingMeta: Codable, Equatable, Sendable, Identifiable {
    public var id: MeetingID
    public var startedAt: Date
    public var endedAt: Date?
    public var source: CallSource?
    public var durationSeconds: Double
    public var status: MeetingStatus
    public var speakerNames: [String: String]
    public var title: String?
    /// Set once the transcript exists, when names were read off the screen.
    public var screenNames: ScreenNames?
    /// The typed names the current notes were written with. Nil for notes
    /// written before this was kept: as if written with none.
    public var notesSpeakerNames: [String: String]?
    /// The calendar event that was on when the recording started, if the calendar is connected.
    public var calendarEvent: CalendarMeetings.Event?
    /// The app the meeting was imported from ("Granola"); nil for one recorded
    /// here. An imported meeting has no audio and no known length.
    public var importedFrom: String?
    /// The title the user gave it (Rename…). It wins over the notes' title,
    /// which Redo notes writes into `title` again.
    public var userTitle: String?
    /// The step that failed only because Gemini could not be reached (no
    /// key, offline, timeout, a 5xx, a per-minute rate limit). It runs again when that changes
    /// (`MeetingEngine.transcribeWaiting`): the whole recording, or the notes
    /// alone from the saved transcript.
    public var waitsForGemini: GeminiStep?

    /// The user's title, else the notes', else the one stored with the
    /// meeting; nil when none of them has one.
    public func shownTitle(notes: MeetingNotes? = nil) -> String? {
        [userTitle, notes?.title, title].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The title to show: `shownTitle`, else the calendar event's.
    public func displayTitle(notes: MeetingNotes? = nil) -> String? {
        shownTitle(notes: notes) ?? calendarEvent.map(\.title).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "45 s" or "17 min", the same in the list and the notes.
    public var lengthText: String {
        durationSeconds < 60 ? "\(Int(durationSeconds)) s" : "\(Int(durationSeconds / 60)) min"
    }

    /// "Thu, Nov 26 · 11:50 PM · 17 min" under a note's title; an import has no length.
    public var whenText: String {
        let day = startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let time = startedAt.formatted(date: .omitted, time: .shortened)
        guard importedFrom == nil, durationSeconds >= 1 else { return "\(day) · \(time)" }
        return "\(day) · \(time) · \(lengthText)"
    }

    /// Speakers were named, renamed or cleared since the notes were written,
    /// so the notes may credit the wrong people.
    public var namesChangedSinceNotes: Bool {
        func typed(_ names: [String: String]) -> [String: String] { names.filter { !$0.value.isEmpty } }
        return typed(speakerNames) != typed(notesSpeakerNames ?? [:])
    }

    public init(id: MeetingID, startedAt: Date, endedAt: Date? = nil, source: CallSource? = nil,
                durationSeconds: Double = 0, status: MeetingStatus = .recording,
                speakerNames: [String: String] = [:], title: String? = nil, screenNames: ScreenNames? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.source = source
        self.durationSeconds = durationSeconds; self.status = status; self.speakerNames = speakerNames; self.title = title
        self.screenNames = screenNames
    }

    /// Names for speakers the user has not named: what the screen showed while
    /// they talked first, then what the notes model found in the conversation.
    public func suggestions(_ notes: MeetingNotes?) -> [SpeakerSuggestion] {
        let screen = (screenNames?.speakers ?? [:]).sorted { $0.key < $1.key }.map { id, match in
            SpeakerSuggestion(label: MeetingSpeaker.defaultName(id), name: match.name,
                              evidence: match.reason ?? "On screen while this speaker talked (\(match.seen) of \(match.of) snapshots)")
        }
        return screen + (notes?.speakers ?? [])
    }

    /// Every name this meeting knows of, for assigning speakers by hand.
    public func knownNames(_ notes: MeetingNotes?) -> [String] {
        let all = suggestions(notes).compactMap(\.name) + (notes?.participants ?? []) + speakerNames.values
        var seen = Set<String>()
        return all.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public func displayName(_ speaker: String, notes: MeetingNotes?) -> String {
        MeetingSpeaker.displayName(speaker, names: speakerNames, suggested: suggestions(notes))
    }
}
