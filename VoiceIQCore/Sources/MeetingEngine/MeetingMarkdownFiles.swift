#if os(macOS)
import CryptoKit
import Foundation

/// Saves each finished meeting as Markdown in a folder the user chose, when
/// Settings has one (off by default). The file is what Export writes with
/// both parts, named "<title> <yyyy-MM-dd>.md". A later change rewrites it
/// only while it still holds exactly what VoiceiQ last wrote, so a file the
/// user edited, moved or deleted is left alone. That rule is Hex's
/// (anomalyco/hex, MIT, ee9b069a).
public struct MeetingMarkdownFiles: Sendable {
    let store: MeetingStore
    let folder: URL
    /// What VoiceiQ last wrote for each meeting.
    let ledgerURL: URL

    public init(store: MeetingStore, folder: URL,
                ledgerURL: URL = FileLayout.appSupportRoot.appendingPathComponent("meeting-markdown-files.json")) {
        self.store = store
        self.folder = folder
        self.ledgerURL = ledgerURL
    }

    public enum Outcome: Equatable, Sendable {
        /// Not finished, or no notes yet.
        case notReady
        case wrote(URL)
        case unchanged(URL)
        /// The file is no longer what VoiceiQ wrote.
        case leftAlone(URL)
    }

    struct Written: Codable, Equatable {
        var folder: String
        /// "<title> <date>", before any " 2".
        var name: String
        var file: String
        var sha256: String
    }

    /// Writes or rewrites the meeting's file. Call from a background queue.
    public func save(_ id: MeetingID) throws -> Outcome {
        guard let meta = store.list().first(where: { $0.id == id }), case .done = meta.status,
              let notes = try? store.loadNotes(id: id) else { return .notReady }
        let data = Data(try store.markdown(id: id, parts: .both).utf8)
        let hash = Self.sha256(data)
        let name = Self.name(title: meta.shownTitle(notes: notes) ?? "Meeting", startedAt: meta.startedAt)
        let key = id.uuid.uuidString
        var ledger = (try? JSONDecoder().decode([String: Written].self, from: Data(contentsOf: ledgerURL))) ?? [:]

        var previous: URL?, sameName: URL?
        if let written = ledger[key], written.folder == folder.standardizedFileURL.path {
            let file = folder.appendingPathComponent(written.file)
            guard let current = try? Data(contentsOf: file), Self.sha256(current) == written.sha256 else { return .leftAlone(file) }
            if written.sha256 == hash, written.name == name { return .unchanged(file) }
            previous = file
            if written.name == name { sameName = file }
        }
        let url = sameName ?? freeURL(name)
        try data.write(to: url, options: .atomic)
        if let previous, previous != url { try? FileManager.default.removeItem(at: previous) }
        ledger[key] = Written(folder: folder.standardizedFileURL.path, name: name, file: url.lastPathComponent, sha256: hash)
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
        return .wrote(url)
    }

    /// "<title> <date>.md", then " 2", " 3" while the name is taken.
    private func freeURL(_ name: String) -> URL {
        var number = 1
        while true {
            let url = folder.appendingPathComponent(number == 1 ? "\(name).md" : "\(name) \(number).md")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }

    static func name(title: String, startedAt: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        // Finder shows ":" as "/", and "/" separates paths; a leading dot hides the file.
        var title = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines)).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        // Filenames are limited to 255 bytes; leave room for " yyyy-MM-dd", " 99" and ".md".
        title = String(title.prefix(120))
        while title.utf8.count > 200 { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        return "\(title.isEmpty ? "Meeting" : title) \(day.string(from: startedAt))"
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let queue = DispatchQueue(label: "io.blue.voiceiq.meeting-markdown-files", qos: .utility)

    /// Saves each meeting whose files change, while Settings has a folder.
    /// Runs off the caller's thread; a failure is logged and nothing else.
    public static func follow(_ store: MeetingStore) {
        NotificationCenter.default.addObserver(forName: .gtMeetingsDidChange, object: nil, queue: nil) { note in
            guard let raw = note.userInfo?[MeetingStore.idKey] as? String, let uuid = UUID(uuidString: raw) else { return }
            MeetingMarkdownFiles.queue.async {
                guard let folder = SettingsStore().meetingMarkdownFolder else { return }
                do {
                    switch try MeetingMarkdownFiles(store: store, folder: folder).save(MeetingID(uuid: uuid)) {
                    case .wrote(let url): Log.meeting.info("meeting saved as Markdown: \(url.lastPathComponent)")
                    case .leftAlone(let url):
                        Log.meeting.info("meeting Markdown not rewritten: \(url.lastPathComponent) was changed outside VoiceiQ")
                    case .notReady, .unchanged: break
                    }
                } catch {
                    Log.meeting.error("meeting Markdown could not be saved: \(error)")
                }
            }
        }
    }
}

public extension SettingsStore {
    /// Where each finished meeting is saved as Markdown; nil, the default, saves none.
    var meetingMarkdownFolder: URL? {
        Self.defaults.string(forKey: "meetingMarkdownFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func setMeetingMarkdownFolder(_ folder: URL?) {
        Self.set(folder?.path, forKey: "meetingMarkdownFolder")
    }
}
#endif
