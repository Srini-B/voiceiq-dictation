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
        /// Names of the folders the user filed it in, by name.
        public var folders: [String]
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
        /// The part of the transcript shown, such as "12:00 to 20:00"; absent when it is all there.
        public var range: String?
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

    /// A folder by its id, else by its name (any case): a name can look like another folder's id.
    public func folder(_ reference: String) -> MeetingFolder? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let folders = meetings.folders()
        return folders.first { $0.id.uuidString.caseInsensitiveCompare(reference) == .orderedSame }
            ?? folders.first { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
    }

    public func folderNames() -> [String] { meetings.folders().map(\.name) }

    /// Newest first. `query` matches the title, the notes or what was said;
    /// `folder` keeps only the meetings filed in it.
    public func meetings(query: String?, since: Date?, limit: Int, folder: MeetingFolder? = nil) -> [MeetingListing] {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let folders = meetings.foldersSnapshot()
        var found: [MeetingListing] = []
        for meta in meetings.list() where since == nil || meta.startedAt >= since! {
            if let folder, !folders.resolve(meetings.storedFolderIDs(of: meta.id)).contains(folder.id) { continue }
            let notes = try? meetings.loadNotes(id: meta.id)
            let transcript = (try? meetings.loadTranscript(id: meta.id)) ?? []
            var listing = self.listing(meta, notes: notes, transcript: transcript, folders: folders)
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

    /// `reference` is a meeting id or "latest". With a range, only the turns that overlap it.
    public func meeting(_ reference: String, range: TranscriptRange? = nil) throws -> Meeting {
        let meta = try self.meta(reference)
        let notes = try? meetings.loadNotes(id: meta.id)
        let transcript = (try? meetings.loadTranscript(id: meta.id)) ?? []
        return Meeting(
            meeting: listing(meta, notes: notes, transcript: transcript, folders: meetings.foldersSnapshot()), notes: notes,
            range: range?.label,
            transcript: transcript.filter { range?.includes($0) ?? true }.map {
                Turn(speaker: meta.displayName($0.speaker, notes: notes), start: $0.start, end: $0.end, text: $0.text)
            },
            chat: meetings.loadChat(id: meta.id, setAsideUnreadable: false)
        )
    }

    /// The meeting as the app exports it (notes above the transcript, with
    /// speaker names and [mm:ss] times), then the questions asked about it.
    /// With a range, the transcript holds only the turns that overlap it.
    public func meetingMarkdown(_ reference: String, range: TranscriptRange? = nil) throws -> String {
        let meta = try self.meta(reference)
        var text = try meetings.markdown(id: meta.id, parts: .both, range: range)
        let chat = meetings.loadChat(id: meta.id, setAsideUnreadable: false)
        if !chat.isEmpty {
            text += "\n## Questions asked in VoiceiQ\n"
            for turn in chat { text += "\n**Q:** \(turn.question)\n\n**A:** \(turn.answer)\n" }
        }
        let folders = folderNames(of: meta.id, in: meetings.foldersSnapshot())
        var header = folders.isEmpty ? "" : "Folders: \(folders.joined(separator: ", "))\n"
        if let range { header += "Transcript shown: \(range.label) only\n" }
        return "Meeting id: \(meta.id.uuid.uuidString)\n\(header)\n" + text
    }

    private func meta(_ reference: String) throws -> MeetingMeta {
        let all = meetings.list()
        if reference.lowercased() == "latest", let newest = all.first { return newest }
        guard let uuid = UUID(uuidString: reference), let meta = all.first(where: { $0.id.uuid == uuid }) else {
            throw Failure.notFound
        }
        return meta
    }

    private func listing(_ meta: MeetingMeta, notes: MeetingNotes?, transcript: [TranscriptSegment],
                         folders: MeetingFoldersSnapshot) -> MeetingListing {
        let speakers = (transcript.contains { $0.speaker == MeetingSpeaker.you } ? [MeetingSpeaker.you] : [])
            + MeetingSpeaker.others(in: transcript)
        let status: (String, String?) = switch meta.status {
        case .recording: ("recording", nil)
        case .transcribing: ("transcribing", nil)
        case .summarizing: ("summarizing", nil)
        case .done: ("done", nil)
        case .failed(let reason): ("failed", reason)
        }
        let title = meta.shownTitle(notes: notes) ?? "Meeting"
        return MeetingListing(
            id: meta.id.uuid.uuidString, title: title, startedAt: meta.startedAt, endedAt: meta.endedAt,
            durationSeconds: meta.durationSeconds.rounded(), status: status.0, failure: status.1,
            speakers: speakers.map { meta.displayName($0, notes: notes) }, hasNotes: notes != nil,
            folders: folderNames(of: meta.id, in: folders), matches: nil
        )
    }

    /// By name, like the folder list.
    private func folderNames(of meeting: MeetingID, in folders: MeetingFoldersSnapshot) -> [String] {
        let filed = Set(folders.resolve(meetings.storedFolderIDs(of: meeting)))
        return folders.folders.filter { filed.contains($0.id) }.map(\.name)
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
