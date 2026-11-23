import Foundation

/// What coding agents can read: History's dictations and the meetings, from
/// the stores the app itself uses. Dictations and meetings that came from the
/// iPhone through iCloud are in those stores too. It only reads.
public struct AgentLibrary: Sendable {
    let history: HistoryStore?
    let meetings: MeetingStore

    public init(history: HistoryStore?, meetings: MeetingStore) {
        self.history = history
        self.meetings = meetings
    }

    public struct Dictation: Codable, Equatable, Sendable {
        public var id: String
        public var startedAt: Date
        /// The text as it was inserted: the cleaned transcript, else the raw one.
        public var text: String
        /// What was heard, when it differs from `text`.
        public var rawText: String?
        public var app: String?
        public var durationSeconds: Double?
        public var status: String
        /// The device it was dictated on, for dictations synced from another
        /// device. Nil for this Mac.
        public var device: String?
    }

    public struct MeetingListing: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var startedAt: Date
        public var endedAt: Date?
        public var durationSeconds: Double
        /// recording, transcribing, summarizing, done, or failed.
        public var status: String
        public var failure: String?
        /// Display names, the note owner first, then in order of first turn.
        public var speakers: [String]
        public var hasNotes: Bool
        /// Transcript lines that contain the search text, at most five.
        public var matches: [String]?
    }

    public struct Turn: Codable, Equatable, Sendable {
        public var speaker: String
        /// Seconds from the start of the recording.
        public var start: Double?
        public var end: Double?
        public var text: String
    }

    public struct Meeting: Codable, Equatable, Sendable {
        public var meeting: MeetingListing
        public var notes: MeetingNotes?
        public var transcript: [Turn]
        /// Questions asked about the meeting in VoiceiQ, with their answers.
        public var chat: [MeetingChatTurn]
    }

    public enum Failure: Error, Equatable {
        case notFound
    }

    // MARK: - Dictations

    /// Newest first. `query` matches the text or the app name.
    public func dictations(query: String?, since: Date?, limit: Int) -> [Dictation] {
        guard let history else { return [] }
        let rows = history.records(matching: query, limit: since == nil ? limit : 5000)
        return rows.filter { since == nil || $0.startedAt >= since! }.prefix(limit).map(Self.dictation)
    }

    public func dictation(id: String) throws -> Dictation {
        guard let record = history?.record(id: id) else { throw Failure.notFound }
        return Self.dictation(record)
    }

    private static func dictation(_ record: DictationRecord) -> Dictation {
        let raw = record.rawTranscript
        return Dictation(id: record.id, startedAt: record.startedAt, text: record.displayText,
                         rawText: raw == record.displayText ? nil : raw, app: record.targetAppName,
                         durationSeconds: record.durationSeconds, status: record.status, device: record.origin)
    }

    // MARK: - Meetings

    /// Newest first. `query` matches the title, the notes or what was said.
    public func meetings(query: String?, since: Date?, limit: Int) -> [MeetingListing] {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var found: [MeetingListing] = []
        for meta in meetings.list() where since == nil || meta.startedAt >= since! {
            let notes = try? meetings.loadNotes(id: meta.id)
            let transcript = (try? meetings.loadTranscript(id: meta.id)) ?? []
            var listing = self.listing(meta, notes: notes, transcript: transcript)
            if !needle.isEmpty {
                let lines = transcript.filter { $0.text.lowercased().contains(needle) }
                    .map { Self.line($0, meta: meta, notes: notes) }
                let inNotes = notes.map { Self.noteText($0).lowercased().contains(needle) } ?? false
                guard !lines.isEmpty || inNotes || listing.title.lowercased().contains(needle) else { continue }
                listing.matches = Array(lines.prefix(5))
            }
            found.append(listing)
            if found.count == limit { break }
        }
        return found
    }

    /// `reference` is a meeting id or "latest".
    public func meeting(_ reference: String) throws -> Meeting {
        let meta = try self.meta(reference)
        let notes = try? meetings.loadNotes(id: meta.id)
        let transcript = (try? meetings.loadTranscript(id: meta.id)) ?? []
        return Meeting(
            meeting: listing(meta, notes: notes, transcript: transcript), notes: notes,
            transcript: transcript.map {
                Turn(speaker: meta.displayName($0.speaker, notes: notes), start: $0.start, end: $0.end, text: $0.text)
            },
            chat: meetings.loadChat(id: meta.id, setAsideUnreadable: false)
        )
    }

    /// The meeting as the app exports it (notes above the transcript, with
    /// speaker names and [mm:ss] times), then the questions asked about it.
    public func meetingMarkdown(_ reference: String) throws -> String {
        let meta = try self.meta(reference)
        var text = try meetings.markdown(id: meta.id, parts: .both)
        let chat = meetings.loadChat(id: meta.id, setAsideUnreadable: false)
        if !chat.isEmpty {
            text += "\n## Questions asked in VoiceiQ\n"
            for turn in chat { text += "\n**Q:** \(turn.question)\n\n**A:** \(turn.answer)\n" }
        }
        return "Meeting id: \(meta.id.uuid.uuidString)\n\n" + text
    }

    private func meta(_ reference: String) throws -> MeetingMeta {
        let all = meetings.list()
        if reference.lowercased() == "latest", let newest = all.first { return newest }
        guard let uuid = UUID(uuidString: reference), let meta = all.first(where: { $0.id.uuid == uuid }) else {
            throw Failure.notFound
        }
        return meta
    }

    private func listing(_ meta: MeetingMeta, notes: MeetingNotes?, transcript: [TranscriptSegment]) -> MeetingListing {
        let speakers = (transcript.contains { $0.speaker == MeetingSpeaker.you } ? [MeetingSpeaker.you] : [])
            + MeetingSpeaker.others(in: transcript)
        let status: (String, String?) = switch meta.status {
        case .recording: ("recording", nil)
        case .transcribing: ("transcribing", nil)
        case .summarizing: ("summarizing", nil)
        case .done: ("done", nil)
        case .failed(let reason): ("failed", reason)
        }
        let title = notes.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? meta.title ?? "Meeting"
        return MeetingListing(
            id: meta.id.uuid.uuidString, title: title, startedAt: meta.startedAt, endedAt: meta.endedAt,
            durationSeconds: meta.durationSeconds.rounded(), status: status.0, failure: status.1,
            speakers: speakers.map { meta.displayName($0, notes: notes) }, hasNotes: notes != nil, matches: nil
        )
    }

    private static func line(_ segment: TranscriptSegment, meta: MeetingMeta, notes: MeetingNotes?) -> String {
        let time = segment.start.map { "[\(MeetingNotesPrompt.clock($0))] " } ?? ""
        return "\(time)\(meta.displayName(segment.speaker, notes: notes)): \(segment.text)"
    }

    private static func noteText(_ notes: MeetingNotes) -> String {
        ([notes.title, notes.summary] + notes.decisions + notes.notes + notes.actions.map(\.text)
            + (notes.sections ?? []).flatMap { [$0.title] + $0.items }).joined(separator: "\n")
    }
}
