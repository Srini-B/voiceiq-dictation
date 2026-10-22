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
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var speaker: String
    public var text: String
    public var chunkIndex: Int
    /// Seconds from the start of the recording.
    public var start: Double?
    public var end: Double?
    public init(speaker: String, text: String, chunkIndex: Int, start: Double? = nil, end: Double? = nil) {
        self.speaker = speaker; self.text = text; self.chunkIndex = chunkIndex; self.start = start; self.end = end
    }
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
                                    ("Coming up", "what happens next")]
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
                              evidence: "On screen while this speaker talked (\(match.seen) of \(match.of) snapshots)")
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
