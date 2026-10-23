import Foundation

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
        try save(meta, in: folder, name: "meta.json")
        return folder
    }
    public func list() -> [MeetingMeta] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { try? load(MeetingMeta.self, from: $0.appendingPathComponent("meta.json")) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    public func loadTranscript(id: MeetingID) throws -> [TranscriptSegment] { try load([TranscriptSegment].self, from: requiredFolder(id).appendingPathComponent("transcript.json")) }
    public func loadNotes(id: MeetingID) throws -> MeetingNotes { try load(MeetingNotes.self, from: requiredFolder(id).appendingPathComponent("notes.json")) }
    public func save(meta: MeetingMeta) throws { try save(meta, in: requiredFolder(meta.id), name: "meta.json") }
    public func save(transcript: [TranscriptSegment], id: MeetingID) throws { try save(transcript, in: requiredFolder(id), name: "transcript.json") }
    public func save(notes: MeetingNotes, id: MeetingID) throws { try save(notes, in: requiredFolder(id), name: "notes.json") }
    public func delete(id: MeetingID) throws { try FileManager.default.removeItem(at: requiredFolder(id)) }
    public func renameSpeaker(id: MeetingID, label: String, name: String) throws {
        var meta = try load(MeetingMeta.self, from: requiredFolder(id).appendingPathComponent("meta.json"))
        meta.speakerNames[label] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(meta: meta)
    }
    /// Name-like text read off the screen while recording; see `ScreenNameSampler`.
    public func save(screenSamples: [ScreenNameSample], id: MeetingID) throws { try save(screenSamples, in: requiredFolder(id), name: "screen-names.json") }
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
    public func markdown(id: MeetingID, parts: ExportParts) throws -> String {
        let folder = try requiredFolder(id), meta = try load(MeetingMeta.self, from: folder.appendingPathComponent("meta.json"))
        let notes = try? loadNotes(id: id)
        var lines = ["# \(notes?.title ?? meta.title ?? "Meeting")", "", meta.startedAt.formatted(date: .long, time: .shortened),
                     Duration.seconds(meta.durationSeconds.rounded())
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
            let transcript = (try? loadTranscript(id: id)) ?? []
            lines += ["", "## Transcript", ""] + transcript.map { segment in
                let time = segment.start.map { "[\(MeetingNotesPrompt.clock($0))] " } ?? ""
                return "\(time)**\(meta.displayName(segment.speaker, notes: notes)):** \(segment.text)\n"
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }
    private func requiredFolder(_ id: MeetingID) throws -> URL {
        guard let folder = folder(for: id) else { throw CocoaError(.fileNoSuchFile) }; return folder
    }
    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T { try decoder.decode(type, from: Data(contentsOf: url)) }
    private func save<T: Encodable>(_ value: T, in folder: URL, name: String) throws { try encoder.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic) }
    private func append(_ title: String, _ items: [String], to lines: inout [String]) { if !items.isEmpty { lines += ["", "## \(title)"] + items.map { "- \($0)" } } }
}
