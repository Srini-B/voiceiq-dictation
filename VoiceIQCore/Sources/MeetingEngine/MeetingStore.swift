import Foundation

public extension Notification.Name {
    /// Posted after a meeting's files are written or its folder is deleted,
    /// with `object` = "sync" when `MeetingSync` made the change and
    /// `userInfo[MeetingStore.idKey]` = the meeting's id.
    static let gtMeetingsDidChange = Notification.Name("io.blue.voiceiq.meetings-changed")
    /// An AssemblyAI key was saved (`KeychainStore.saveAPIKey`).
    static let apiKeySaved = Notification.Name("io.blue.voiceiq.api-key-saved")
}

public final class MeetingStore: @unchecked Sendable {
    public let root: URL
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value }()
    private let decoder = JSONDecoder()

    public init(root: URL = FileLayout.meetingsRoot) { self.root = root }
    public func folder(for id: MeetingID) -> URL? {
        try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(id.uuid.uuidString) }
    }
    public func create(meta: MeetingMeta) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let date = meta.startedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let folder = root.appendingPathComponent("\(date)-\(meta.id.uuid.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        Self.notifyChanged(meta.id)
        return folder
    }
    public func list() -> [MeetingMeta] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { try? load(MeetingMeta.self, from: $0.appendingPathComponent("meta.json")) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    public func loadTranscript(id: MeetingID) throws -> [TranscriptSegment] { TranscriptSegment.distinctIDs(try loadStoredTranscript(id: id)) }
    /// As on disk, for sync: `loadTranscript`'s ids for repeated turns are not saved until an edit.
    func loadStoredTranscript(id: MeetingID) throws -> [TranscriptSegment] { try load([TranscriptSegment].self, from: requiredFolder(id).appendingPathComponent("transcript.json")) }
    public func loadNotes(id: MeetingID) throws -> MeetingNotes { try load(MeetingNotes.self, from: requiredFolder(id).appendingPathComponent("notes.json")) }
    public func save(meta: MeetingMeta) throws { try save(meta, id: meta.id, name: "meta.json") }
    public func save(transcript: [TranscriptSegment], id: MeetingID) throws { try save(transcript, id: id, name: "transcript.json") }
    public func save(notes: MeetingNotes, id: MeetingID) throws { try save(notes, id: id, name: "notes.json") }
    /// Questions asked about the meeting and their answers; empty before the first.
    /// A chat.json that no longer decodes is moved aside to chat-unreadable-<time>.json,
    /// so the next answer starts a new chat instead of overwriting the old one.
    /// Read-only callers pass `setAsideUnreadable: false` to leave it in place.
    public func loadChat(id: MeetingID, setAsideUnreadable: Bool = true) -> [MeetingChatTurn] {
        guard let folder = try? requiredFolder(id) else { return [] }
        let url = folder.appendingPathComponent("chat.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        if let turns = try? load([MeetingChatTurn].self, from: url) { return turns }
        guard setAsideUnreadable else { return [] }
        let aside = folder.appendingPathComponent("chat-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return []
    }
    public func save(chat: [MeetingChatTurn], id: MeetingID) throws { try save(chat, id: id, name: "chat.json") }
    /// Every delete is sent to iCloud too. Whether a meeting is there cannot
    /// be told from its folder: a first upload may be on its way while a redo
    /// has the meeting unfinished again. Deleting a record that never went up
    /// fails with `unknownItem`, which sync takes as done.
    public func delete(id: MeetingID) throws {
        let folder = try requiredFolder(id)
        if (try? load(MeetingMeta.self, from: folder.appendingPathComponent("meta.json")))?.importedFrom != nil {
            deletedImports.insert(id.uuid.uuidString)
        }
        try FileManager.default.removeItem(at: folder)
        pendingDeletes.insert(id.uuid.uuidString)
        Self.notifyChanged(id, deletedFromCloud: true)
    }
    public func renameSpeaker(id: MeetingID, label: String, name: String) throws {
        var meta = try load(MeetingMeta.self, from: requiredFolder(id).appendingPathComponent("meta.json"))
        meta.speakerNames[label] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(meta: meta)
    }
    /// Empty puts back the title from the notes.
    public func renameMeeting(id: MeetingID, title: String) throws {
        var meta = try load(MeetingMeta.self, from: requiredFolder(id).appendingPathComponent("meta.json"))
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.userTitle = title.isEmpty ? nil : title
        try save(meta: meta)
    }
    /// New words for one turn; its speaker, times and id stay, and so does
    /// every other turn. The notes are not written again. Nothing happens
    /// when the turn is gone, as after a sync replaced the transcript.
    public func editTranscriptSegment(_ segmentID: TranscriptSegment.ID, text: String, meeting id: MeetingID) throws {
        var transcript = try loadTranscript(id: id)
        guard let index = transcript.firstIndex(where: { $0.id == segmentID }) else { return }
        transcript[index].savedID = segmentID
        transcript[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(transcript: transcript, id: id)
    }
    /// Removes one turn and leaves every other one as it was.
    public func deleteTranscriptSegment(_ segmentID: TranscriptSegment.ID, meeting id: MeetingID) throws {
        var transcript = try loadTranscript(id: id)
        guard let index = transcript.firstIndex(where: { $0.id == segmentID }) else { return }
        transcript.remove(at: index)
        try save(transcript: transcript, id: id)
    }
    /// Name-like text read off the screen while recording; see `ScreenNameSampler`.
    public func save(screenSamples: [ScreenNameSample], id: MeetingID) throws { try save(screenSamples, id: id, name: "screen-names.json") }
    public func loadScreenSamples(id: MeetingID) -> [ScreenNameSample]? {
        try? load([ScreenNameSample].self, from: requiredFolder(id).appendingPathComponent("screen-names.json"))
    }

    public struct ExportParts: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let notes = ExportParts(rawValue: 1), transcript = ExportParts(rawValue: 2)
        public static let both: ExportParts = [.notes, .transcript]
    }

    /// The meeting as one Markdown document: the notes, the transcript, or the notes above the transcript.
    /// With a range, the transcript holds only the turns that overlap it and its heading names the range.
    public func markdown(id: MeetingID, parts: ExportParts, range: TranscriptRange? = nil) throws -> String {
        let folder = try requiredFolder(id), meta = try load(MeetingMeta.self, from: folder.appendingPathComponent("meta.json"))
        let notes = try? loadNotes(id: id)
        var lines = ["# \(meta.displayTitle(notes: notes) ?? "Meeting")", "", meta.startedAt.formatted(date: .long, time: .shortened),
                     meta.importedFrom.map { "Imported from \($0)" } ?? Duration.seconds(meta.durationSeconds.rounded())
                         .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))]
        if parts.contains(.notes), let notes {
            lines += ["", "## Summary", notes.summary]
            for section in notes.sections ?? [] { append(section.title, section.items, to: &lines) }
            append("Decisions", notes.decisions, to: &lines)
            if !notes.actions.isEmpty { lines += ["", "## Action items"] + notes.actions.map { item in
                var suffix = [item.owner, item.deadline].compactMap { $0 }.joined(separator: " · ")
                if !suffix.isEmpty { suffix = " (\(suffix))" }; return "- [ ] \(item.text)\(suffix)"
            }}
            append("Notes", notes.notes, to: &lines)
        }
        if parts.contains(.transcript) {
            let transcript = ((try? loadTranscript(id: id)) ?? []).filter { range?.includes($0) ?? true }
            lines += ["", range.map { "## Transcript (\($0.label))" } ?? "## Transcript", ""] + transcript.map { segment in
                let time = segment.start.map { "[\(MeetingNotesPrompt.clock($0))] " } ?? ""
                return "\(time)**\(meta.displayName(segment.speaker, notes: notes)):** \(segment.text)\n"
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }
    func requiredFolder(_ id: MeetingID) throws -> URL {
        guard let folder = folder(for: id) else { throw CocoaError(.fileNoSuchFile) }; return folder
    }
    func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T { try decoder.decode(type, from: Data(contentsOf: url)) }
    func save<T: Encodable>(_ value: T, id: MeetingID, name: String, fromSync: Bool = false) throws {
        try encoder.encode(value).write(to: requiredFolder(id).appendingPathComponent(name), options: .atomic)
        Self.notifyChanged(id, fromSync: fromSync)
    }

    public static let idKey = "meetingID"
    /// In `userInfo`: true when the deleted meeting may be in iCloud.
    public static let deletedFromCloudKey = "deletedFromCloud"

    static func notifyChanged(_ id: MeetingID, fromSync: Bool = false, deletedFromCloud: Bool = false) {
        NotificationCenter.default.post(name: .gtMeetingsDidChange, object: fromSync ? "sync" : nil,
                                        userInfo: [idKey: id.uuid.uuidString, deletedFromCloudKey: deletedFromCloud])
    }
    private func append(_ title: String, _ items: [String], to lines: inout [String]) { if !items.isEmpty { lines += ["", "## \(title)"] + items.map { "- \($0)" } } }
}
