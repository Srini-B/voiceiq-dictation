import CryptoKit
import Foundation

/// One meeting from Granola's account export (Settings › Profile › Generate
/// CSV), as the export gives it. The export carries no audio, duration,
/// attendees, folders or speaker names; see docs/GRANOLA_IMPORT.md.
public struct GranolaMeeting: Equatable, Sendable {
    public var documentID: String
    public var title: String
    /// When the note was created in Granola, which is when the meeting started.
    public var createdAt: Date
    /// Granola's AI notes, in Markdown.
    public var summary: String
    /// What the user typed during the meeting.
    public var notes: String
    public var transcript: String
    public var workspace: String

    /// The same for the same Granola note on every device and every import,
    /// so a repeat import or iCloud never makes a second copy.
    public var id: MeetingID { GranolaImport.meetingID(documentID: documentID) }
}

/// A row, a file, or a meeting that was left out, and why.
public struct GranolaSkip: Equatable, Sendable, Identifiable {
    public var id = UUID()
    /// "export.csv, row 12", or the meeting's date.
    public var place: String
    public var title: String?
    public var reason: String

    public init(place: String, title: String? = nil, reason: String) {
        self.place = place; self.title = title; self.reason = reason
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.place == rhs.place && lhs.title == rhs.title && lhs.reason == rhs.reason
    }
}

/// Everything read from one export file, before anything is saved.
public struct GranolaExport: Sendable {
    public var meetings: [GranolaMeeting]
    public var skipped: [GranolaSkip]
}

/// What an import would do, shown before it does it.
public struct GranolaImportPlan: Sendable {
    /// Oldest first.
    public var new: [GranolaMeeting]
    /// Already in VoiceiQ from an earlier import, here or on another device.
    public var existing: [GranolaMeeting]
    public var skipped: [GranolaSkip]
    public var total: Int { new.count + existing.count + skipped.count }
}

public struct GranolaImportReport: Sendable {
    public var imported: Int
    public var existing: Int
    public var skipped: [GranolaSkip]
}

public enum GranolaImportError: Error, LocalizedError, Equatable {
    case unreadable(String)

    public var errorDescription: String? {
        switch self { case .unreadable(let reason): return reason }
    }
}

public enum GranolaImport {
    public static let sourceName = "Granola"
    /// The speaker of transcript lines Granola gives no label.
    public static let unlabeledSpeaker = "Transcript"
    /// Far above any real export (a year of daily meetings is tens of MB),
    /// low enough that a damaged size field cannot exhaust memory.
    static let maximumBytes = 512 * 1024 * 1024

    // MARK: - Reading

    /// Reads a ZIP of the export's CSV files, or one of those CSV files.
    /// Throws only when nothing at all can be read; bad rows are skipped.
    public static func read(_ url: URL) throws -> GranolaExport {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw GranolaImportError.unreadable("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard data.count <= maximumBytes else { throw GranolaImportError.unreadable("The file is larger than 512 MB.") }
        if url.pathExtension.lowercased() == "csv" {
            return try csvExport([(url.lastPathComponent, data)])
        }
        return try read(zip: data)
    }

    static func read(zip data: Data) throws -> GranolaExport {
        let archive: ZipArchive
        do { archive = try ZipArchive(data: data) } catch {
            throw GranolaImportError.unreadable(describe(error))
        }
        let candidates = archive.entries.filter { entry in
            let parts = entry.path.split(separator: "/")
            return !entry.isDirectory && !parts.contains("__MACOSX") && !(parts.last?.hasPrefix(".") ?? true)
                && entry.path.lowercased().hasSuffix(".csv")
        }
        guard !candidates.isEmpty else {
            throw GranolaImportError.unreadable("This ZIP has no CSV file in it. Choose the ZIP from Granola's export email.")
        }
        var total = 0
        var files: [(String, Data)] = []
        for entry in candidates {
            total += entry.size
            guard total <= maximumBytes else { throw GranolaImportError.unreadable("The export unpacks to more than 512 MB.") }
            do { files.append((entry.path, try archive.contents(of: entry))) } catch {
                throw GranolaImportError.unreadable(describe(error))
            }
        }
        return try csvExport(files)
    }

    private static func describe(_ error: Error) -> String {
        switch error as? ZipArchive.Failure {
        case .notAZip?: return "This isn't a ZIP file. Choose the ZIP from Granola's export email."
        case .unsupported(let what)?: return "This ZIP uses \(what), which VoiceiQ can't open. Unzip it and choose the CSV file inside."
        case .damaged(let what)?: return "This ZIP is damaged: \(what). Download the export again."
        case nil: return error.localizedDescription
        }
    }

    /// The meetings in every file that is a Granola notes CSV. A file with
    /// other columns is reported, not fatal, unless no file is usable.
    static func csvExport(_ files: [(String, Data)]) throws -> GranolaExport {
        var meetings: [GranolaMeeting] = [], skipped: [GranolaSkip] = [], seen = Set<String>(), usable = 0
        var lastProblem = "This file isn't a Granola notes export."
        for (name, data) in files {
            let file = (name as NSString).lastPathComponent
            guard let text = String(data: data, encoding: .utf8) else {
                lastProblem = "\(file) isn't UTF-8 text."
                skipped.append(GranolaSkip(place: file, reason: "Not UTF-8 text"))
                continue
            }
            let rows: [[String]]
            do { rows = try csvRows(text) } catch {
                lastProblem = "\(file) isn't valid CSV: \(error.localizedDescription)"
                skipped.append(GranolaSkip(place: file, reason: "Not valid CSV (\(error.localizedDescription))"))
                continue
            }
            guard let header = rows.first.map({ $0.map(column) }), let columns = Columns(header) else {
                lastProblem = "\(file) doesn't have Granola's columns (document_title, document_created, summary, notes, transcript)."
                skipped.append(GranolaSkip(place: file, reason: "Not a Granola notes file (unexpected columns)"))
                continue
            }
            usable += 1
            for (index, row) in rows.enumerated().dropFirst() {
                let place = "\(file), row \(index + 1)"
                switch columns.meeting(row) {
                case .failure(let reason):
                    skipped.append(GranolaSkip(place: place, title: columns.value("document_title", row), reason: reason.text))
                case .success(let meeting):
                    guard seen.insert(meeting.id.uuid.uuidString).inserted else {
                        skipped.append(GranolaSkip(place: place, title: meeting.title, reason: "Appears earlier in the export"))
                        continue
                    }
                    meetings.append(meeting)
                }
            }
        }
        guard usable > 0 else { throw GranolaImportError.unreadable(lastProblem) }
        return GranolaExport(meetings: meetings, skipped: skipped)
    }

    /// "Document Title" and "document_title" are the same column.
    private static func column(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_")
    }

    private struct Reason: Error { let text: String }

    private struct Columns {
        let index: [String: Int]
        let count: Int

        init?(_ header: [String]) {
            var index: [String: Int] = [:]
            for (position, name) in header.enumerated() where index[name] == nil { index[name] = position }
            // A title and a date make a meeting; without any content column it is some other CSV.
            guard index["document_title"] != nil, index["document_created"] != nil,
                  ["summary", "notes", "transcript"].contains(where: { index[$0] != nil }) else { return nil }
            self.index = index
            count = header.count
        }

        func value(_ name: String, _ row: [String]) -> String? {
            index[name].flatMap { $0 < row.count ? row[$0] : nil }.flatMap { $0.isEmpty ? nil : $0 }
        }

        func meeting(_ row: [String]) -> Result<GranolaMeeting, Reason> {
            guard row.count == count else {
                return .failure(Reason(text: "Has \(row.count) columns instead of \(count)"))
            }
            let text = { (name: String) in value(name, row)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            guard let created = value("document_created", row), let date = GranolaImport.date(created) else {
                return .failure(Reason(text: "No readable date (\(value("document_created", row) ?? "empty"))"))
            }
            let title = text("document_title").isEmpty ? "Untitled meeting" : text("document_title")
            let meeting = GranolaMeeting(
                documentID: text("document_id").isEmpty ? "\(title)|\(created)" : text("document_id"),
                title: title, createdAt: date, summary: text("summary"), notes: text("notes"),
                transcript: text("transcript"), workspace: text("workspace_name"))
            guard !meeting.summary.isEmpty || !meeting.notes.isEmpty || !meeting.transcript.isEmpty else {
                return .failure(Reason(text: "No notes, summary or transcript"))
            }
            return .success(meeting)
        }
    }

    static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        // Without a zone Granola's times are UTC, like the ones with a Z.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    struct CSVError: Error, LocalizedError {
        let errorDescription: String?
    }

    /// RFC 4180: quoted fields hold commas, quotes ("") and line breaks; rows
    /// end in LF or CRLF; a leading byte-order mark is dropped.
    static func csvRows(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, afterQuote = false, fieldStarted = false
        var scalars = text.unicodeScalars[...]
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        var iterator = scalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        func endRow() {
            row.append(field)
            if row != [""] { rows.append(row) }
            row = []; field = ""; fieldStarted = false; afterQuote = false
        }
        while let scalar = pending {
            pending = iterator.next()
            if quoted {
                if scalar == "\"" {
                    if pending == "\"" { field.unicodeScalars.append("\""); pending = iterator.next() } else { quoted = false; afterQuote = true }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"":
                guard !fieldStarted else { throw CSVError(errorDescription: "a quote in the middle of a field, row \(rows.count + 1)") }
                quoted = true; fieldStarted = true
            case ",":
                row.append(field); field = ""; fieldStarted = false; afterQuote = false
            case "\r":
                if pending == "\n" { pending = iterator.next() }
                endRow()
            case "\n":
                endRow()
            default:
                guard !afterQuote else { throw CSVError(errorDescription: "text after a closing quote, row \(rows.count + 1)") }
                field.unicodeScalars.append(scalar); fieldStarted = true
            }
        }
        guard !quoted else { throw CSVError(errorDescription: "a quoted field never ends") }
        if fieldStarted || !row.isEmpty || !field.isEmpty { endRow() }
        return rows
    }

    // MARK: - Mapping

    /// Granola's document id is a UUID, used as the meeting's own. Anything
    /// else is hashed into a UUID, so the same note always maps to the same meeting.
    static func meetingID(documentID: String) -> MeetingID {
        if let uuid = UUID(uuidString: documentID) { return MeetingID(uuid: uuid) }
        var bytes = Array(SHA256.hash(data: Data("granola:\(documentID)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50   // version 5 (name-based)
        bytes[8] = bytes[8] & 0x3F | 0x80   // RFC 4122 variant
        let uuid = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return MeetingID(uuid: UUID(uuid: uuid))
    }

    static func meta(_ meeting: GranolaMeeting) -> MeetingMeta {
        var meta = MeetingMeta(id: meeting.id, startedAt: meeting.createdAt, status: .done, title: meeting.title)
        meta.importedFrom = sourceName
        return meta
    }

    /// Granola's Markdown notes in VoiceiQ's shape: text before the first
    /// heading is the summary, each heading a section, except action items
    /// (next steps, to-dos, follow-ups) and decisions, which get their own
    /// places. What the user typed becomes Notes. Nil when there is neither.
    static func notes(_ meeting: GranolaMeeting) -> MeetingNotes? {
        var lead: [String] = [], sections: [NoteSection] = []
        for line in meeting.summary.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.allSatisfy({ "-*_=".contains($0) }) else { continue }
            if let heading = heading(trimmed) {
                sections.append(NoteSection(title: heading, items: []))
                continue
            }
            let item = listItem(line)
            if sections.isEmpty { lead.append(item.bullet ? "• \(item.text)" : item.text) } else {
                nest(item, into: &sections[sections.count - 1].items)
            }
        }
        var decisions: [String] = [], actions: [ActionItem] = [], kept: [NoteSection] = []
        for section in sections where !section.items.isEmpty {
            let title = section.title.lowercased()
            if ["action item", "next step", "to-do", "todo", "to do", "follow-up", "follow up", "followup"].contains(where: title.contains) {
                actions += section.items.map { ActionItem(text: $0) }
            } else if title.contains("decision") {
                decisions += section.items
            } else {
                kept.append(section)
            }
        }
        var typed: [String] = []
        for line in meeting.notes.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            nest(listItem(line), into: &typed)
        }
        guard !lead.isEmpty || !kept.isEmpty || !decisions.isEmpty || !actions.isEmpty || !typed.isEmpty else { return nil }
        return MeetingNotes(title: meeting.title,
                            summary: lead.isEmpty ? "Imported from Granola." : lead.joined(separator: "\n"),
                            sections: kept.isEmpty ? nil : kept, decisions: decisions, actions: actions, notes: typed)
    }

    /// A nested bullet goes under the item above it, as its own "◦" line.
    private static func nest(_ item: (text: String, bullet: Bool, nested: Bool), into items: inout [String]) {
        if item.nested, !items.isEmpty { items[items.count - 1] += "\n◦ \(item.text)" } else { items.append(item.text) }
    }

    /// "## Title", or a line that is all bold ("**Title**", "**Title:**").
    private static func heading(_ line: String) -> String? {
        if line.hasPrefix("#") {
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : plain(title)
        }
        if line.count > 4, line.hasPrefix("**"), line.hasSuffix("**") || line.hasSuffix("**:"),
           !line.dropFirst(2).dropLast(line.hasSuffix(":") ? 3 : 2).contains("**") {
            return plain(line).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        }
        return nil
    }

    /// A list line without its marker ("- ", "* ", "1. ", "[ ] "), and
    /// whether it was indented under another.
    private static func listItem(_ line: String) -> (text: String, bullet: Bool, nested: Bool) {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        var text = line.trimmingCharacters(in: .whitespaces)
        var bullet = false
        if let first = text.first, "-*+•".contains(first), text.dropFirst().first == " " {
            text = String(text.dropFirst(2)); bullet = true
        } else if let dot = text.firstIndex(where: { $0 == "." || $0 == ")" }), dot != text.startIndex,
                  text[..<dot].allSatisfy(\.isNumber), text[text.index(after: dot)...].first == " " {
            text = String(text[text.index(dot, offsetBy: 2)...]); bullet = true
        }
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) { text = String(text.dropFirst(box.count)) }
        return (plain(text), bullet, bullet && indent >= 2)
    }

    /// Bold and italic markers off; the notes show plain text.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// One turn per labelled line ("Me:", "Them:", "Speaker A:"); lines with
    /// no label continue the turn before. Granola's export usually has no
    /// labels, so its text arrives as paragraphs under `unlabeledSpeaker`.
    static func transcript(_ text: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = [], others: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let colon = line.firstIndex(of: ":") {
                let label = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let words = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                var speaker: String?
                if label == "me" || label == "you" { speaker = MeetingSpeaker.you }
                else if label == "them" || label == "speaker" || (label.hasPrefix("speaker ") && label.count <= 11) {
                    if !others.contains(label) { others.append(label) }
                    speaker = "s\(others.firstIndex(of: label)! + 1)"
                }
                if let speaker, !words.isEmpty {
                    segments.append(TranscriptSegment(speaker: speaker, text: words, chunkIndex: 0))
                    continue
                }
            }
            if let last = segments.last, last.speaker != unlabeledSpeaker || last.text.count < 1_200 {
                segments[segments.count - 1].text += "\n" + line
            } else {
                segments.append(TranscriptSegment(speaker: unlabeledSpeaker, text: line, chunkIndex: 0))
            }
        }
        return segments
    }

    // MARK: - Importing

    /// Sorts the export against what is already here, without saving anything.
    public static func plan(_ export: GranolaExport, store: MeetingStore) -> GranolaImportPlan {
        let here = Set(((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).map { $0.suffix(36).uppercased() })
        let deleted = store.pendingDeletes
        var plan = GranolaImportPlan(new: [], existing: [], skipped: export.skipped)
        for meeting in export.meetings.sorted(by: { $0.createdAt < $1.createdAt }) {
            let id = meeting.id.uuid.uuidString
            if here.contains(id) {
                plan.existing.append(meeting)
            } else if deleted.contains(id) {
                plan.skipped.append(GranolaSkip(place: meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
                                                title: meeting.title, reason: "You deleted it in VoiceiQ"))
            } else {
                plan.new.append(meeting)
            }
        }
        return plan
    }

    /// Saves each new meeting as a finished one, so it shows in Meetings, goes
    /// to iCloud and is readable by coding agents like any other. Runs on the
    /// main actor with every other meeting edit, yielding between meetings.
    @MainActor
    public static func run(_ plan: GranolaImportPlan, store: MeetingStore,
                           progress: (Int) -> Void = { _ in }) async -> GranolaImportReport {
        var report = GranolaImportReport(imported: 0, existing: plan.existing.count, skipped: plan.skipped)
        for (index, meeting) in plan.new.enumerated() {
            if index % 10 == 0 { progress(index); await Task.yield() }
            // Imported meanwhile, say by iCloud from another device's import.
            guard store.folder(for: meeting.id) == nil else { report.existing += 1; continue }
            do {
                // Each save queues an upload, which reads the files when it
                // goes, so the meeting goes up whole after the last one.
                _ = try store.create(meta: meta(meeting))
                let segments = transcript(meeting.transcript)
                if !segments.isEmpty { try store.save(transcript: segments, id: meeting.id) }
                if let notes = notes(meeting) { try store.save(notes: notes, id: meeting.id) }
                report.imported += 1
            } catch {
                // Half written would read as imported next time; take it out.
                if let folder = store.folder(for: meeting.id) { try? FileManager.default.removeItem(at: folder) }
                report.skipped.append(GranolaSkip(place: meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
                                                  title: meeting.title, reason: "Couldn't save: \(error.localizedDescription)"))
            }
        }
        progress(plan.new.count)
        return report
    }
}
