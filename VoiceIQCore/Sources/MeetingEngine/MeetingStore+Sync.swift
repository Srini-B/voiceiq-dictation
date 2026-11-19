import CryptoKit
import Foundation

/// A meeting as it travels through iCloud: everything but the audio.
public struct SyncedMeeting: Codable, Equatable, Sendable {
    public var meta: MeetingMeta
    public var notes: MeetingNotes?
    public var transcript: [TranscriptSegment]
    public var chat: [MeetingChatTurn]

    public init(meta: MeetingMeta, notes: MeetingNotes?, transcript: [TranscriptSegment], chat: [MeetingChatTurn]) {
        self.meta = meta; self.notes = notes; self.transcript = transcript; self.chat = chat
    }

    /// Names the content, so a meeting goes up again only when it changed.
    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What this device knows of a meeting's copy in iCloud, in its `cloud.json`.
/// No file: the meeting was never sent or received.
struct MeetingCloudState: Codable, Equatable {
    /// The digest of the content last sent or received.
    var digest: String
    /// The record's system fields, so the next save goes over that copy.
    var systemFields: Data?
    /// The meeting came from another device; it goes when the iCloud account does.
    var arrived: Bool
}

/// What `MeetingSync` reads and writes. Only finished meetings go up; one
/// that is recording or being written up waits until it is done again.
extension MeetingStore {
    private static let cloudFile = "cloud.json"

    /// Meetings deleted on this device whose records iCloud has not yet
    /// confirmed gone. Written by `delete(id:)` and read by `applyFromCloud`,
    /// both on the main actor, so a meeting deleted here never comes back
    /// from a fetch that was already on its way. Kept apart from the sync
    /// engine, so a delete made before sync started is still sent.
    var pendingDeletes: Set<String> {
        get { ids(in: "deletes.json") }
        set { save(ids: newValue, in: "deletes.json") }
    }

    /// Meetings from iCloud that could not be written here (a full disk),
    /// new or half updated. `MeetingSync` fetches them again, since the
    /// engine will not; until then they do not go up, and the copy fetched
    /// again replaces whatever was half written.
    var failedImports: Set<String> {
        get { ids(in: "retry.json") }
        set { save(ids: newValue, in: "retry.json") }
    }

    /// Meetings whose copy in iCloud was not found when this device saved
    /// over it, with when that was. They do not go up until a fetch that
    /// started after then has finished: if it brought a delete from another
    /// device, the meeting is gone; if not (the zone was made again), it goes
    /// up as a new record (`releaseHeld`).
    var heldUploads: [String: Date] {
        get {
            (try? Data(contentsOf: syncFolder.appendingPathComponent("held.json")))
                .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        }
        set {
            let url = syncFolder.appendingPathComponent("held.json")
            if newValue.isEmpty { try? FileManager.default.removeItem(at: url); return }
            try? FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Its copy in iCloud was not found: forget that copy, and hold it back.
    func hold(id: MeetingID, at date: Date = Date()) {
        // The hold first: stopped between the two writes, the meeting is held
        // with its old change tag, which can only meet unknownItem again.
        heldUploads[id.uuid.uuidString] = date
        if var state = loadCloudState(id: id), state.systemFields != nil {
            state.systemFields = nil
            try? saveCloudState(state, id: id)
        }
    }

    /// Meetings held before `fetchStarted` that a finished fetch did not
    /// delete. They may go up again; returns those that should.
    func releaseHeld(before fetchStarted: Date) -> [MeetingID] {
        let released = heldUploads.filter { $0.value < fetchStarted }.keys
        guard !released.isEmpty else { return [] }
        heldUploads = heldUploads.filter { $0.value >= fetchStarted }
        return released.compactMap(UUID.init(uuidString:)).map { MeetingID(uuid: $0) }.filter(needsUpload)
    }

    /// Beside the meeting folders; `list()` skips it, having no meta.json.
    var syncFolder: URL { root.appendingPathComponent(".sync", isDirectory: true) }

    private func ids(in file: String) -> Set<String> {
        (try? Data(contentsOf: syncFolder.appendingPathComponent(file)))
            .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    private func save(ids: Set<String>, in file: String) {
        let url = syncFolder.appendingPathComponent(file)
        if ids.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(ids) { try? data.write(to: url, options: .atomic) }
    }

    /// What goes up for a meeting: its content and the system fields of the
    /// copy it goes over, read together.
    /// Nil for a meeting that must not go up now (see `needsUpload`), even
    /// when a save of it was already queued.
    func outgoing(id: MeetingID) -> (meeting: SyncedMeeting, systemFields: Data?)? {
        guard !failedImports.contains(id.uuid.uuidString), heldUploads[id.uuid.uuidString] == nil else { return nil }
        return synced(id: id).map { ($0, loadCloudState(id: id)?.systemFields) }
    }

    func loadCloudState(id: MeetingID) -> MeetingCloudState? {
        guard let folder = folder(for: id) else { return nil }
        return try? load(MeetingCloudState.self, from: folder.appendingPathComponent(Self.cloudFile))
    }

    func saveCloudState(_ state: MeetingCloudState?, id: MeetingID) throws {
        guard let url = folder(for: id)?.appendingPathComponent(Self.cloudFile) else { return }
        if let state {
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The meeting as it would go up, or nil while it is not finished or a
    /// file of it cannot be read, so a read error never goes up as no notes
    /// or an empty transcript.
    func synced(id: MeetingID) -> SyncedMeeting? {
        guard let folder = folder(for: id),
              let meta = try? load(MeetingMeta.self, from: folder.appendingPathComponent("meta.json")),
              meta.status == .done else { return nil }
        let notes = try? loadNotes(id: id), transcript = try? loadTranscript(id: id)
        let exists = { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        if notes == nil && exists("notes.json") || transcript == nil && exists("transcript.json") { return nil }
        return SyncedMeeting(meta: meta, notes: notes, transcript: transcript ?? [], chat: loadChat(id: id))
    }

    /// Finished, and changed since it was last sent or received.
    func needsUpload(id: MeetingID) -> Bool {
        guard !failedImports.contains(id.uuid.uuidString), heldUploads[id.uuid.uuidString] == nil,
              let meeting = synced(id: id) else { return false }
        return loadCloudState(id: id)?.digest != meeting.digest
    }

    func pendingUploads() -> [MeetingID] { list().map(\.id).filter(needsUpload) }

    /// `sent` is in iCloud now, as the record whose system fields are given.
    func markSent(_ sent: SyncedMeeting, systemFields: Data) {
        let id = sent.meta.id
        guard folder(for: id) != nil else { return }
        let arrived = loadCloudState(id: id)?.arrived ?? false
        try? saveCloudState(MeetingCloudState(digest: sent.digest, systemFields: systemFields, arrived: arrived), id: id)
    }

    /// A meeting fetched from iCloud, or the copy there that refused this
    /// device's save. With no change of its own since it last synced, this
    /// device takes it as it is. With one, this device's meeting stays and
    /// only gains the questions asked on the other device; the result is
    /// true, and it goes up over the copy in iCloud.
    @discardableResult
    func applyFromCloud(_ remote: SyncedMeeting, systemFields: Data) -> Bool {
        let id = remote.meta.id
        guard !pendingDeletes.contains(id.uuid.uuidString) else { return false }
        guard folder(for: id) != nil else {
            let date = remote.meta.startedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            let folder = root.appendingPathComponent("\(date)-\(id.uuid.uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try write(remote)
                try saveCloudState(MeetingCloudState(digest: remote.digest, systemFields: systemFields, arrived: true), id: id)
                failedImports.remove(id.uuid.uuidString)
            } catch {
                // Half written (a full disk): gone, and fetched again whole (`failedImports`).
                try? FileManager.default.removeItem(at: folder)
                failedImports.insert(id.uuid.uuidString)
                Log.meeting.error("meeting sync: could not save \(id.uuid.uuidString, privacy: .public): \(error)")
            }
            return false
        }
        let state = loadCloudState(id: id)
        let local = synced(id: id)
        let retrying = failedImports.contains(id.uuid.uuidString)
        let changedHere = !retrying && (local == nil || local?.digest != state?.digest)
        let stored = MeetingCloudState(digest: remote.digest, systemFields: systemFields, arrived: state?.arrived ?? false)
        guard local != remote else {
            try? saveCloudState(stored, id: id)
            failedImports.remove(id.uuid.uuidString)
            return false
        }
        do {
            if changedHere {
                let chat = loadChat(id: id)
                let merged = Self.merge(chat, remote.chat)
                if merged != chat { try save(merged, id: id, name: "chat.json", fromSync: true) }
            } else {
                try write(remote)
            }
            // Without its digest the import would read as an edit made here.
            try saveCloudState(stored, id: id)
        } catch {
            Log.meeting.error("meeting sync: could not update \(id.uuid.uuidString, privacy: .public): \(error)")
            // Its files may be half from each version: never sent, fetched again whole.
            if !changedHere { failedImports.insert(id.uuid.uuidString) }
            // A merge that could not be saved is not sent now, or the save would
            // meet the same conflict and fail again at once. The change here stays
            // pending and is merged again at the next edit or launch.
            return false
        }
        failedImports.remove(id.uuid.uuidString)
        return changedHere
    }

    /// Both devices' questions, each once, in the order they were asked.
    static func merge(_ chat: [MeetingChatTurn], _ other: [MeetingChatTurn]) -> [MeetingChatTurn] {
        let known = Set(chat.map(\.id))
        return (chat + other.filter { !known.contains($0.id) }).sorted { $0.askedAt < $1.askedAt }
    }

    private func write(_ meeting: SyncedMeeting) throws {
        let id = meeting.meta.id
        if let notes = meeting.notes {
            try save(notes, id: id, name: "notes.json", fromSync: true)
        } else if let url = folder(for: id)?.appendingPathComponent("notes.json"),
                  FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try save(meeting.transcript, id: id, name: "transcript.json", fromSync: true)
        try save(meeting.chat, id: id, name: "chat.json", fromSync: true)
        try save(meeting.meta, id: id, name: "meta.json", fromSync: true)
    }

    /// Deleted on another device. The audio goes with it, and a retry of it
    /// that is still out is not applied.
    func deleteFromCloud(id: MeetingID) {
        failedImports.remove(id.uuid.uuidString)
        heldUploads[id.uuid.uuidString] = nil
        guard let folder = folder(for: id) else { return }
        try? FileManager.default.removeItem(at: folder)
        Self.notifyChanged(id, fromSync: true)
    }

    /// The iCloud account went away, or its data did. Meetings from other
    /// devices go; this device's meetings are no longer known to be in iCloud.
    func forgetCloud() {
        heldUploads = [:]
        for meta in list() {
            guard let state = loadCloudState(id: meta.id) else { continue }
            if state.arrived { deleteFromCloud(id: meta.id) } else { try? saveCloudState(nil, id: meta.id) }
        }
    }
}
