import Foundation

/// A folder the user files meetings in, like a tag: a meeting can be in
/// several, and deleting a folder leaves its meetings where they are.
public struct MeetingFolder: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Set at creation and at every rename; the newer copy wins in sync.
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

/// The folder list and when each deleted folder was deleted, so a delete on
/// one device is not undone by another's copy. Which meetings are in a
/// folder is kept with each meeting (`MeetingStore.folderIDs(of:)`).
public struct MeetingFoldersSnapshot: Codable, Equatable, Sendable {
    public var folders: [MeetingFolder]
    /// Folder id (UUID string) → deletion time.
    public var tombstones: [String: Date]
    /// Folder id (UUID string) → the folder it was combined into: two
    /// folders with one name, made apart on two devices, become one.
    /// Meetings filed in the old id count as filed in the new one, so none
    /// has to go to iCloud again. Kept for good: the meetings keep the old id.
    public var aliases: [String: UUID]

    public init(folders: [MeetingFolder] = [], tombstones: [String: Date] = [:], aliases: [String: UUID] = [:]) {
        self.folders = folders; self.tombstones = tombstones; self.aliases = aliases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decode([MeetingFolder].self, forKey: .folders)
        tombstones = try c.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
        aliases = try c.decodeIfPresent([String: UUID].self, forKey: .aliases) ?? [:]
    }

    /// The live folders these stored ids stand for, each once, in order.
    public func resolve(_ ids: [UUID]) -> [UUID] {
        let live = Set(folders.map(\.id))
        var seen = Set<UUID>()
        return ids.map(canonical).filter { live.contains($0) && seen.insert($0).inserted }
    }

    /// The folder an id stands for now: itself, or the end of the chain of
    /// folders it became, however long.
    func canonical(_ id: UUID) -> UUID {
        var id = id, seen: Set<UUID> = [id]
        while let next = aliases[id.uuidString], seen.insert(next).inserted { id = next }
        return id
    }

    /// As long as the dictionary keeps its deletions.
    static let tombstoneLifetime = DictionarySnapshot.tombstoneLifetime

    /// The same on every device, whatever the order: the newer copy of each
    /// folder wins, and a delete wins over any copy it postdates. Two folders
    /// with one name (any case) become the older one (`aliases`).
    public static func merge(_ a: MeetingFoldersSnapshot, _ b: MeetingFoldersSnapshot, now: Date = Date()) -> MeetingFoldersSnapshot {
        let tombstones = a.tombstones.merging(b.tombstones) { max($0, $1) }
            .filter { now.timeIntervalSince($0.value) < tombstoneLifetime }
        var aliases = a.aliases.merging(b.aliases) { $0.uuidString < $1.uuidString ? $0 : $1 }
        var byID: [UUID: MeetingFolder] = [:]
        for folder in a.folders + b.folders {
            if let existing = byID[folder.id], !isNewer(folder, than: existing) { continue }
            byID[folder.id] = folder
        }
        let alive = byID.values.filter { folder in
            aliases[folder.id.uuidString] == nil && (tombstones[folder.id.uuidString].map { folder.updatedAt > $0 } ?? true)
        }.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString }
        var byName: [String: UUID] = [:]
        var kept: [MeetingFolder] = []
        for folder in alive {
            let key = folder.name.lowercased()
            if let survivor = byName[key] { aliases[folder.id.uuidString] = survivor; continue }
            byName[key] = folder.id
            kept.append(folder)
        }
        return MeetingFoldersSnapshot(folders: kept.sorted(by: MeetingStore.byName), tombstones: tombstones, aliases: aliases)
    }

    private static func isNewer(_ folder: MeetingFolder, than other: MeetingFolder) -> Bool {
        folder.updatedAt != other.updatedAt ? folder.updatedAt > other.updatedAt : folder.name > other.name
    }
}

public extension Notification.Name {
    /// Posted after the folder list changes, with `object` = "sync" when
    /// `MeetingFolderSync` made the change. A meeting filed in or out of a
    /// folder posts `gtMeetingsDidChange` instead.
    static let gtMeetingFoldersDidChange = Notification.Name("io.blue.voiceiq.meeting-folders-changed")
}

/// Folders, for the Meetings views, coding agents, and importers. Every edit
/// happens on the main actor, like the other meeting edits.
extension MeetingStore {
    /// Beside the meeting folders; `list()` skips it, having no meta.json.
    var foldersURL: URL { root.appendingPathComponent("folders.json") }
    /// In each meeting's folder: the ids of the folders it is in.
    static let folderIDsFile = "folder-ids.json"

    static func byName(_ a: MeetingFolder, _ b: MeetingFolder) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        return order != .orderedSame ? order == .orderedAscending : a.id.uuidString < b.id.uuidString
    }

    /// Every folder, by name.
    public func folders() -> [MeetingFolder] { foldersSnapshot().folders }

    /// A new folder, or the folder that already has this name (any case), so
    /// an import run twice files into the same folders.
    @discardableResult
    public func createFolder(named name: String, now: Date = Date()) throws -> MeetingFolder {
        let name = try Self.folderName(name)
        var snapshot = try readFoldersSnapshot()
        if let existing = snapshot.folders.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let folder = MeetingFolder(name: name, createdAt: now)
        snapshot.folders.append(folder)
        try saveFolders(snapshot)
        return folder
    }

    /// To the name of another folder, the two become one (`MeetingFoldersSnapshot.aliases`).
    public func renameFolder(_ id: UUID, to name: String, now: Date = Date()) throws {
        let name = try Self.folderName(name)
        var snapshot = try readFoldersSnapshot()
        guard let index = snapshot.folders.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        guard snapshot.folders[index].name != name else { return }
        snapshot.folders[index].name = name
        snapshot.folders[index].updatedAt = max(now, snapshot.folders[index].updatedAt.addingTimeInterval(0.001))
        try saveFolders(snapshot)
    }

    /// The meetings in it stay, in their other folders too. Its id stays in
    /// their `folder-ids.json` and is skipped from then on: removing it would
    /// send every one of those meetings to iCloud again.
    public func deleteFolder(_ id: UUID, now: Date = Date()) throws {
        var snapshot = try readFoldersSnapshot()
        guard let folder = snapshot.folders.first(where: { $0.id == id }) else { return }
        snapshot.folders.removeAll { $0.id == id }
        snapshot.tombstones[id.uuidString] = max(now, folder.updatedAt.addingTimeInterval(0.001))
        try saveFolders(snapshot)
    }

    /// The folders the meeting is in that still exist, in the order it was filed.
    public func folderIDs(of meeting: MeetingID) -> [UUID] {
        foldersSnapshot().resolve(storedFolderIDs(of: meeting))
    }

    /// Files the meeting in exactly these folders. The meeting must exist.
    public func setFolderIDs(_ ids: [UUID], for meeting: MeetingID) throws {
        var seen = Set<UUID>()
        let ids = ids.filter { seen.insert($0).inserted }
        guard ids != storedFolderIDs(of: meeting) else { return }
        try writeFolderIDs(ids, id: meeting)
    }

    /// Files the meeting in the folder, or takes it out. Other stored ids stay,
    /// even of folders this device does not know yet: the folder list syncs
    /// apart from the meetings and may arrive later.
    public func setMeeting(_ meeting: MeetingID, inFolder folder: UUID, _ member: Bool) throws {
        let snapshot = foldersSnapshot()
        var ids = try readStoredFolderIDs(of: meeting)
        ids.removeAll { snapshot.canonical($0) == snapshot.canonical(folder) }
        if member { ids.append(folder) }
        try setFolderIDs(ids, for: meeting)
    }

    // MARK: Files

    /// No file: no folders. A file that cannot be read is treated as none
    /// here, and `synced(id:)` keeps such a meeting from going up.
    func storedFolderIDs(of meeting: MeetingID) -> [UUID] { (try? readStoredFolderIDs(of: meeting)) ?? [] }

    /// For changing: no file is no folders, but a file that cannot be read
    /// throws, so toggling one folder never drops the others.
    func readStoredFolderIDs(of meeting: MeetingID) throws -> [UUID] {
        guard let folder = folder(for: meeting) else { return [] }
        let url = folder.appendingPathComponent(Self.folderIDsFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try load([UUID].self, from: url)
    }

    /// Empty removes the file, so a meeting in no folder syncs as it did
    /// before folders existed.
    func writeFolderIDs(_ ids: [UUID], id: MeetingID, fromSync: Bool = false) throws {
        if !ids.isEmpty { return try save(ids, id: id, name: Self.folderIDsFile, fromSync: fromSync) }
        let url = try requiredFolder(id).appendingPathComponent(Self.folderIDsFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        Self.notifyChanged(id, fromSync: fromSync)
    }

    /// For reading: a list that cannot be read shows as none.
    func foldersSnapshot() -> MeetingFoldersSnapshot { (try? readFoldersSnapshot()) ?? MeetingFoldersSnapshot() }

    /// For changing: no file is no folders, but a file that cannot be read
    /// throws, so an edit or a sync never saves over folders it could not read.
    func readFoldersSnapshot() throws -> MeetingFoldersSnapshot {
        guard FileManager.default.fileExists(atPath: foldersURL.path) else { return MeetingFoldersSnapshot() }
        return try load(MeetingFoldersSnapshot.self, from: foldersURL)
    }

    func saveFolders(_ snapshot: MeetingFoldersSnapshot, fromSync: Bool = false) throws {
        // Combines a folder renamed to another's name, and sorts.
        let snapshot = MeetingFoldersSnapshot.merge(snapshot, MeetingFoldersSnapshot())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: foldersURL, options: .atomic)
        NotificationCenter.default.post(name: .gtMeetingFoldersDidChange, object: fromSync ? "sync" : nil)
    }

    public enum FolderNameError: Error, LocalizedError {
        case empty
        public var errorDescription: String? { "A folder needs a name." }
    }

    private static func folderName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FolderNameError.empty }
        return trimmed
    }
}
