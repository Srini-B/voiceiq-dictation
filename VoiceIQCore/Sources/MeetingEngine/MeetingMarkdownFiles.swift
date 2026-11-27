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
        guard let meta = try? store.load(MeetingMeta.self, from: store.requiredFolder(id).appendingPathComponent("meta.json")),
              case .done = meta.status, (try? store.loadNotes(id: id)) != nil else { return .notReady }
        let markdown = try store.markdown(id: id, parts: .both)
        // The name comes from the document's own "# title" line, so a rename
        // saved meanwhile cannot pair one title's name with another's body.
        let name = Self.name(title: String(markdown.prefix { $0 != "\n" }.dropFirst(2)), startedAt: meta.startedAt)
        let data = Data(markdown.utf8)
        let hash = Self.sha256(data)
        let key = id.uuid.uuidString, path = folder.standardizedFileURL.path
        // Only a missing ledger starts empty: an unreadable one would give every meeting a " 2" copy.
        var ledger: [String: Written] = [:]
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            ledger = try JSONDecoder().decode([String: Written].self, from: Data(contentsOf: ledgerURL))
        }
        // The ledger is written before the file, so a failed ledger write changes nothing on disk.
        func record(_ written: Written?) throws {
            ledger[key] = written
            try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
        }

        if let written = ledger[key], written.folder == path {
            let previous = folder.appendingPathComponent(written.file)
            guard let current = try? Data(contentsOf: previous), Self.sha256(current) == written.sha256 else { return .leftAlone(previous) }
            if written.sha256 == hash, written.name == name { return .unchanged(previous) }
            // The file is VoiceiQ's, so a rename moves it, including one that
            // changes only letter case on a case-insensitive disk.
            let url = written.name == name ? previous : freeURL(name, sameFileAs: previous)
            try record(Written(folder: path, name: name, file: url.lastPathComponent, sha256: hash))
            do {
                if url != previous { try FileManager.default.moveItem(at: previous, to: url) }
            } catch { try? record(written); throw error }
            do {
                try data.write(to: url, options: .atomic)
            } catch { try? record(Written(folder: path, name: name, file: url.lastPathComponent, sha256: written.sha256)); throw error }
            return .wrote(url)
        }
        // A file that appears at the free name before the write (a sync client, another app) is kept; the next number is tried.
        while true {
            let url = freeURL(name)
            try record(Written(folder: path, name: name, file: url.lastPathComponent, sha256: hash))
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return .wrote(url)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                try? record(nil)
                throw error
            }
        }
    }

    /// "<title> <date>.md", then " 2", " 3" while the name is taken by a file other than `own`.
    private func freeURL(_ name: String, sameFileAs own: URL? = nil) -> URL {
        let ownID = own.flatMap { try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier }
        var number = 1
        while true {
            let url = folder.appendingPathComponent(number == 1 ? "\(name).md" : "\(name) \(number).md")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            if let ownID, let id = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
               id.isEqual(ownID) { return url }
            number += 1
        }
    }

    static func name(title: String, startedAt: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        // Finder shows ":" as "/", and "/" separates paths; a leading dot hides the file.
        var title = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)).joined(separator: "-")
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
                    // The meeting's id, not its title or the folder: DebugLog keeps the text of .auto values.
                    switch try MeetingMarkdownFiles(store: store, folder: folder).save(MeetingID(uuid: uuid)) {
                    case .wrote: Log.meeting.info("meeting \(raw, privacy: .public) saved as Markdown")
                    case .leftAlone:
                        Log.meeting.info("meeting Markdown not rewritten: the file for \(raw, privacy: .public) was changed outside VoiceiQ")
                    case .notReady, .unchanged: break
                    }
                } catch {
                    let error = error as NSError
                    Log.meeting.error("meeting Markdown could not be saved for \(raw, privacy: .public): \(error.domain, privacy: .public) \(error.code)")
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
