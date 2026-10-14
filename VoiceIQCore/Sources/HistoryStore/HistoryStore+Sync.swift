import Foundation
import GRDB

/// What `HistorySync` reads and writes. Rows from another device carry
/// `origin` and no folder; this device's rows get `cloudSyncedAt` once their
/// text is in iCloud.
extension DictationRecord {
    /// A dictation made on another device, as it arrived from iCloud.
    public init(fromCloud id: String, text: String, startedAt: Date, durationSeconds: Double?,
                appName: String?, status: String, origin: String, syncedAt: Date) {
        self.id = id
        self.folder = ""
        self.startedAt = startedAt
        self.status = status
        self.targetAppName = appName
        self.durationSeconds = durationSeconds
        self.cleanedTranscript = text
        self.origin = origin
        self.cloudSyncedAt = syncedAt
    }

    /// Statuses whose text is final. Anything else is in flight, waiting for
    /// the user, or has no text worth another device's History.
    static let uploadableStatuses: [SessionMeta.Status] = [.inserted, .copiedToClipboard, .recovered]
}

extension HistoryStore {
    /// This device's finished dictations that are not in iCloud yet.
    public func pendingUploads() -> [DictationRecord] {
        let statuses = DictationRecord.uploadableStatuses.map(\.rawValue)
        return (try? queue.read { db in
            try DictationRecord
                .filter(sql: """
                    origin IS NULL AND cloudSyncedAt IS NULL
                    AND (cleanedTranscript IS NOT NULL OR rawTranscript IS NOT NULL)
                    AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))
                    """, arguments: StatementArguments(statuses))
                .order(sql: "startedAt ASC")
                .fetchAll(db)
        }) ?? []
    }

    public func markSynced(ids: [String], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        do {
            try queue.write { db in
                for id in ids {
                    try db.execute(sql: "UPDATE dictation SET cloudSyncedAt = ? WHERE id = ?", arguments: [date, id])
                }
            }
            Self.notifyChanged(fromSync: true)
        } catch {
            Log.history.error("HistoryStore: markSynced failed: \(error)")
        }
    }

    /// Rows fetched from iCloud. A row this device already has (its own
    /// upload coming back) only learns that it is in iCloud.
    public func applyFromCloud(_ rows: [DictationRecord]) {
        guard !rows.isEmpty else { return }
        do {
            try queue.write { db in
                for row in rows {
                    if try DictationRecord.exists(db, key: row.id) {
                        try db.execute(sql: "UPDATE dictation SET cloudSyncedAt = ? WHERE id = ?",
                                       arguments: [row.cloudSyncedAt, row.id])
                    } else {
                        try row.insert(db)
                    }
                }
            }
            Self.notifyChanged(fromSync: true)
        } catch {
            Log.history.error("HistoryStore: applyFromCloud failed: \(error)")
        }
    }

    /// Rows deleted on another device go here too, folder included: a folder
    /// left behind would come back at the next reindex and upload again.
    public func deleteFromCloud(ids: [String]) {
        guard !ids.isEmpty else { return }
        do {
            let rows = try queue.write { db -> [DictationRecord] in
                let rows = try DictationRecord.filter(keys: ids).fetchAll(db)
                for row in rows { try DictationRecord.deleteOne(db, key: row.id) }
                return rows
            }
            for row in rows where row.hasFolder { try? FileManager.default.removeItem(at: row.folderURL) }
            if !rows.isEmpty { Self.notifyChanged(fromSync: true) }
        } catch {
            Log.history.error("HistoryStore: deleteFromCloud failed: \(error)")
        }
    }

    /// The iCloud account went away, or its data did. Rows from other
    /// devices go; this device's rows are no longer known to be in iCloud.
    public func forgetCloud() {
        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM dictation WHERE origin IS NOT NULL")
                try db.execute(sql: "UPDATE dictation SET cloudSyncedAt = NULL")
            }
            Self.notifyChanged(fromSync: true)
        } catch {
            Log.history.error("HistoryStore: forgetCloud failed: \(error)")
        }
    }
}
