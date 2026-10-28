import Foundation
import GRDB

/// Queryable index over the session folders (which remain the source of truth —
/// meta.json per folder). The DB makes History fast to search and stats cheap.
public struct DictationRecord: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "dictation"

    public var id: String
    public var folder: String
    public var startedAt: Date
    public var status: String
    public var targetAppName: String?
    public var targetAppBundleID: String?
    public var durationSeconds: Double?
    public var rawTranscript: String?
    public var cleanedTranscript: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var pipelineSeconds: Double?
    /// The device that dictated it, for rows that came from iCloud. Nil for
    /// dictations made on this device.
    public var origin: String?
    /// When the row reached iCloud (this device's rows) or arrived from it.
    public var cloudSyncedAt: Date?

    public var displayText: String {
        cleanedTranscript ?? rawTranscript ?? ""
    }

    /// Rows from another device have no folder: the text is all there is.
    public var isFromOtherDevice: Bool { origin != nil }
    public var isInCloud: Bool { cloudSyncedAt != nil }
    public var hasFolder: Bool { !folder.isEmpty }

    public var folderURL: URL {
        URL(fileURLWithPath: folder, isDirectory: true)
    }

    public init(meta: SessionMeta, folder: URL) {
        self.id = meta.id.uuidString
        self.folder = folder.path
        self.startedAt = meta.startedAt
        self.status = meta.status.rawValue
        self.targetAppName = meta.targetAppName
        self.targetAppBundleID = meta.targetAppBundleID
        self.durationSeconds = meta.audioDurationSeconds
        self.rawTranscript = meta.rawTranscript
        self.cleanedTranscript = meta.cleanedTranscript
        self.errorCode = meta.errorCode
        self.errorMessage = meta.errorMessage
        self.pipelineSeconds = meta.pipelineSeconds
    }
}

public extension Notification.Name {
    /// Posted after any HistoryStore write so an open History pane refreshes as
    /// dictations land, retries drain, or rows are deleted — no polling.
    /// `object` is "sync" for writes that came from iCloud, nil otherwise.
    /// `userInfo[HistoryStore.deletedCloudIDsKey]` lists deleted rows that
    /// were in iCloud, so the deletion can follow them there.
    static let gtHistoryDidChange = Notification.Name("io.blue.voiceiq.history-changed")
}

public final class HistoryStore: @unchecked Sendable {
    let queue: DatabaseQueue

    public static let deletedCloudIDsKey = "deletedCloudIDs"

    static func notifyChanged(fromSync: Bool = false, deletedCloudIDs: [String] = []) {
        NotificationCenter.default.post(
            name: .gtHistoryDidChange, object: fromSync ? "sync" : nil,
            userInfo: deletedCloudIDs.isEmpty ? nil : [deletedCloudIDsKey: deletedCloudIDs]
        )
    }

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        queue = try Self.openOrRecreate(at: databaseURL)
        try migrate()
    }

    /// A corrupt index must not disable history/recovery forever — the folders
    /// are the source of truth, so quarantine and rebuild (audit L6).
    private static var configuration: Configuration {
        var config = Configuration()
        // WAL + NORMAL: the folders are the source of truth and reindex() rebuilds
        // the index from them, so a rollback journal's per-write fsync buys
        // nothing but launch stalls (17.6ms → 4.9ms measured on 47 sessions).
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return config
    }

    private static func openOrRecreate(at databaseURL: URL) throws -> DatabaseQueue {
        do {
            let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            // Probe readability so corruption surfaces here, not at first query.
            _ = try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA schema_version") }
            return queue
        } catch {
            Log.history.error("HistoryStore: open failed (\(error)) — quarantining and recreating index")
            let quarantine = databaseURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).sqlite")
            try? FileManager.default.moveItem(at: databaseURL, to: quarantine)
            return try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        }
    }

    public static func standard() throws -> HistoryStore {
        try HistoryStore(databaseURL: FileLayout.appSupportRoot.appendingPathComponent("history.sqlite"))
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: DictationRecord.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("folder", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("status", .text).notNull().indexed()
                t.column("targetAppName", .text)
                t.column("targetAppBundleID", .text)
                t.column("durationSeconds", .double)
                t.column("rawTranscript", .text)
                t.column("cleanedTranscript", .text)
                t.column("errorCode", .text)
                t.column("pipelineSeconds", .double)
            }
        }
        migrator.registerMigration("v2-errorMessage") { db in
            try db.alter(table: DictationRecord.databaseTableName) { t in
                t.add(column: "errorMessage", .text)
            }
        }
        migrator.registerMigration("v3-cloud") { db in
            try db.alter(table: DictationRecord.databaseTableName) { t in
                t.add(column: "origin", .text)
                t.add(column: "cloudSyncedAt", .datetime)
            }
        }
        migrator.registerMigration("v4-stats", migrate: Self.createStatTable)
        try migrator.migrate(queue)
    }

    // MARK: - Writes

    public func upsert(meta: SessionMeta, folder: URL) {
        var record = DictationRecord(meta: meta, folder: folder)
        do {
            try queue.write { db in
                // The folder knows nothing about iCloud; keep what sync wrote
                // while the synced text and status still match. A Retry that
                // changes them makes the row an upload again.
                if let stored = try DictationRecord.fetchOne(db, key: record.id),
                   stored.displayText == record.displayText, stored.status == record.status {
                    record.cloudSyncedAt = stored.cloudSyncedAt
                }
                try record.save(db)
                try Self.recordStat(of: record, in: db)
            }
            Self.notifyChanged()
        } catch {
            Log.history.error("HistoryStore: upsert failed: \(error)")
        }
    }

    public func delete(id: String, removeFolder: Bool) {
        do {
            let record = try queue.write { db -> DictationRecord? in
                let record = try DictationRecord.fetchOne(db, key: id)
                try DictationRecord.deleteOne(db, key: id)
                return record
            }
            if removeFolder, let record, record.hasFolder {
                try? FileManager.default.removeItem(at: record.folderURL)
            }
            Self.notifyChanged(deletedCloudIDs: record.map(Self.cloudIDs) ?? [])
        } catch {
            Log.history.error("HistoryStore: delete failed: \(error)")
        }
    }

    /// The row's id when a copy of it may be in iCloud.
    static func cloudIDs(_ record: DictationRecord) -> [String] {
        record.mayBeInCloud ? [record.id] : []
    }

    /// Removes rows in `statuses` that started before `cutoff`, with their
    /// folders. Returns how many went. Retention is this device's setting,
    /// so the copies in iCloud stay.
    @discardableResult
    public func deleteExpired(before cutoff: Date, statuses: [String]) -> Int {
        do {
            let expired = try queue.write { db -> [DictationRecord] in
                let rows = try DictationRecord
                    .filter(sql: "startedAt < ? AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))",
                            arguments: StatementArguments([cutoff] + statuses))
                    .fetchAll(db)
                for row in rows { try DictationRecord.deleteOne(db, key: row.id) }
                return rows
            }
            for row in expired where row.hasFolder { try? FileManager.default.removeItem(at: row.folderURL) }
            if !expired.isEmpty { Self.notifyChanged() }
            return expired.count
        } catch {
            Log.history.error("HistoryStore: deleteExpired failed: \(error)")
            return 0
        }
    }

    public func deleteAll(removeFolders: Bool, sparing activeFolder: URL? = nil) {
        do {
            let inCloud = try queue.write { db -> [String] in
                let ids = try DictationRecord.fetchAll(db).filter(\.mayBeInCloud).map(\.id)
                try DictationRecord.deleteAll(db)
                return ids
            }
            Self.notifyChanged(deletedCloudIDs: inCloud)
        } catch {
            Log.history.error("HistoryStore: deleteAll failed: \(error)")
        }
        if removeFolders {
            // Sweep the DIRECTORY, not the query — the visible-records filter hides
            // cancelled sessions whose audio would otherwise survive (audit #5).
            // The live session's folder is spared (audit L7).
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: FileLayout.recordingsRoot, includingPropertiesForKeys: nil
            )) ?? []
            for folder in folders where folder.hasDirectoryPath {
                if let activeFolder, folder.standardizedFileURL == activeFolder.standardizedFileURL {
                    continue
                }
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Rebuild the index from the folders on disk (launch reconciliation).
    /// Folders are the source of truth: rows whose folders vanished (external
    /// cleanup, Finder deletion) are pruned, never shown as ghosts. Rows from
    /// another device never had a folder and stay.
    public func reindex(recordingsRoot: URL = FileLayout.recordingsRoot) {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: recordingsRoot, includingPropertiesForKeys: nil
        )) ?? []
        for folder in folders where folder.hasDirectoryPath {
            if let meta = SessionMeta.read(from: folder) {
                upsert(meta: meta, folder: folder)
            }
        }
        // Prune orphaned rows — from the UNFILTERED table. records() hides
        // silent/short-cancelled rows, and exactly those would otherwise linger
        // forever as invisible ghosts after external folder cleanup.
        let all = (try? queue.read { db in
            try DictationRecord.fetchAll(db)
        }) ?? []
        let orphans = all.filter {
            !$0.isFromOtherDevice && !FileManager.default.fileExists(atPath: $0.folder)
        }
        for orphan in orphans {
            delete(id: orphan.id, removeFolder: false)
        }
        if !orphans.isEmpty {
            Log.history.info("reindex pruned \(orphans.count) orphaned row(s)")
        }
    }

    // MARK: - Reads

    public func record(id: String) -> DictationRecord? {
        try? queue.read { db in try DictationRecord.fetchOne(db, key: id) }
    }

    public func records(matching query: String? = nil, limit: Int = 500) -> [DictationRecord] {
        // History is a library of words + things needing attention — never an
        // event log. Visible: anything with a transcript; retryable failures and
        // offline-queued items; long cancelled recordings (recoverable). Silent
        // rows and short cancels are discarded at the source and filtered here
        // for legacy data. In-flight statuses (recording/recorded/transcribing)
        // are NOT visible: the live session would surface in the attention shelf
        // with Retry/Discard controls that double-upload or destroy it mid-flight
        // (production pass 2); crash recovery reads them via interruptedRecords()
        // and normalizes every one at launch.
        let visible = """
            (rawTranscript IS NOT NULL OR cleanedTranscript IS NOT NULL
             OR status IN ('failed','queuedForRetry')
             OR (status = 'cancelled' AND durationSeconds >= 10))
            AND status != 'silent'
            """
        return (try? queue.read { db in
            if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                // Escape LIKE wildcards so "100%" finds "100%" (audit L28).
                let escaped = query
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                return try DictationRecord
                    .filter(sql: "(rawTranscript LIKE ? ESCAPE '\\' OR cleanedTranscript LIKE ? ESCAPE '\\' OR targetAppName LIKE ? ESCAPE '\\') AND \(visible)",
                            arguments: [pattern, pattern, pattern])
                    .order(sql: "startedAt DESC")
                    .limit(limit)
                    .fetchAll(db)
            }
            return try DictationRecord
                .filter(sql: visible)
                .order(sql: "startedAt DESC")
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    /// Every row id, visibility filter bypassed — test-only observability.
    func allIDsForTesting() -> [String] {
        (try? queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM dictation ORDER BY startedAt")
        }) ?? []
    }

    /// Sessions the RetryQueue should drain: offline-queued plus transient failures.
    public func retryableRecords() -> [DictationRecord] {
        (try? queue.read { db in
            try DictationRecord
                .filter(sql: "status = ? OR (status = ? AND errorCode IN (?, ?, ?))",
                        arguments: [SessionMeta.Status.queuedForRetry.rawValue,
                                    SessionMeta.Status.failed.rawValue,
                                    "network", "timeout", "rate_limit"])
                .order(sql: "startedAt ASC")
                .fetchAll(db)
        }) ?? []
    }

    /// Non-terminal sessions found at launch = the app died mid-flight.
    public func interruptedRecords() -> [DictationRecord] {
        (try? queue.read { db in
            try DictationRecord
                .filter(sql: "status IN (?, ?, ?)",
                        arguments: [SessionMeta.Status.recording.rawValue,
                                    SessionMeta.Status.recorded.rawValue,
                                    SessionMeta.Status.transcribing.rawValue])
                .order(sql: "startedAt DESC")
                .fetchAll(db)
        }) ?? []
    }
}
