import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

/// Keeps the final text of every dictation the same on the Mac and iPhone
/// through the user's private CloudKit database. Always on, like the
/// dictionary: there is no setting. Without an iCloud account, or without the
/// container entitlement (Debug builds on the Mac), History stays local.
///
/// One record per dictation, `Dictation` in zone `History`, named by the
/// dictation id. Records never change: a dictation's text is final before it
/// is uploaded (`HistoryStore.pendingUploads`). Deleting a row in History
/// deletes its record, and the other device drops its copy. Retention purges
/// are local and leave the copies in iCloud alone.
public actor HistorySync {
    public static let shared = HistorySync()

    static let containerID = "iCloud.io.blue.voiceiq"
    static let zoneID = CKRecordZone.ID(zoneName: "History")
    static let recordType = "Dictation"

    private var engine: CKSyncEngine?
    private var store: HistoryStore?
    private var deviceName = ""
    private var observer: (any NSObjectProtocol)?

    private init() {}

    private static var stateURL: URL {
        FileLayout.appSupportRoot.appendingPathComponent("history-sync-state.json")
    }

    /// `deviceName` labels this device's dictations on the other one.
    public func start(deviceName: String) {
        guard engine == nil else { return }
        guard Self.hasContainerEntitlement else {
            Log.history.info("history sync: no iCloud container entitlement, History stays on this device")
            return
        }
        guard let store = try? HistoryStore.standard() else { return }
        self.store = store
        self.deviceName = deviceName

        let state = (try? Data(contentsOf: Self.stateURL))
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let container = CKContainer(identifier: Self.containerID)
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: state, delegate: self
        )
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if state == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        observer = NotificationCenter.default.addObserver(forName: .gtHistoryDidChange, object: nil, queue: nil) { note in
            guard note.object as? String != "sync" else { return }
            let deleted = note.userInfo?[HistoryStore.deletedCloudIDsKey] as? [String] ?? []
            Task { await HistorySync.shared.localChanged(deletedIDs: deleted) }
        }
        enqueueUploads()
        Log.history.info("history sync started as \(deviceName, privacy: .public)")
    }

    /// Call when the app comes to the front: iOS delivers no push to a
    /// suspended app, and a Mac that slept may have missed one.
    public func refresh() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
        } catch {
            Log.history.error("history sync: fetch failed: \(error)")
        }
    }

    private func localChanged(deletedIDs: [String]) {
        guard let engine else { return }
        if !deletedIDs.isEmpty {
            engine.state.add(pendingRecordZoneChanges: deletedIDs.map { .deleteRecord(Self.recordID($0)) })
        }
        enqueueUploads()
    }

    private func enqueueUploads() {
        guard let engine, let store else { return }
        let pending = store.pendingUploads()
        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending.map { .saveRecord(Self.recordID($0.id)) })
    }

    private static func recordID(_ id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }

    /// CloudKit raises an Objective-C exception when the container is not in
    /// the entitlements, which is the case for ad-hoc Debug builds on the Mac.
    private static var hasContainerEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerID) ?? false
        #else
        return true
        #endif
    }
}

// MARK: - Records

extension HistorySync {
    private static func record(for row: DictationRecord, deviceName: String) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(row.id))
        record["text"] = row.displayText
        record["startedAt"] = row.startedAt
        record["durationSeconds"] = row.durationSeconds
        record["appName"] = row.targetAppName
        record["device"] = deviceName
        record["status"] = row.status
        return record
    }

    private static func row(from record: CKRecord, syncedAt: Date) -> DictationRecord? {
        guard let text = record["text"] as? String, let startedAt = record["startedAt"] as? Date else { return nil }
        return DictationRecord(
            fromCloud: record.recordID.recordName, text: text, startedAt: startedAt,
            durationSeconds: record["durationSeconds"] as? Double,
            appName: record["appName"] as? String,
            status: record["status"] as? String ?? SessionMeta.Status.inserted.rawValue,
            origin: record["device"] as? String ?? "another device",
            syncedAt: syncedAt
        )
    }
}

// MARK: - CKSyncEngineDelegate

extension HistorySync: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let event):
            if let data = try? JSONEncoder().encode(event.stateSerialization) {
                try? data.write(to: Self.stateURL, options: .atomic)
            }
        case .accountChange(let event):
            accountChanged(event)
        case .fetchedDatabaseChanges(let event):
            if event.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                Log.history.info("history sync: zone deleted in iCloud, starting over")
                store?.forgetCloud()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                enqueueUploads()
            }
        case .fetchedRecordZoneChanges(let event):
            let now = Date()
            let rows = event.modifications.compactMap { Self.row(from: $0.record, syncedAt: now) }
            store?.applyFromCloud(rows)
            store?.deleteFromCloud(ids: event.deletions.map(\.recordID.recordName))
            if !rows.isEmpty || !event.deletions.isEmpty {
                Log.history.info("history sync: fetched \(rows.count) row(s), \(event.deletions.count) deletion(s)")
            }
        case .sentRecordZoneChanges(let event):
            sentRecordZoneChanges(event, syncEngine: syncEngine)
        case .sentDatabaseChanges(let event):
            for failure in event.failedZoneSaves {
                Log.history.error("history sync: zone save failed: \(failure.error)")
            }
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard let store else { return nil }
        let deviceName = deviceName
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            guard let row = store.record(id: recordID.recordName), !row.isFromOtherDevice else {
                // Deleted locally before it went up.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return Self.record(for: row, deviceName: deviceName)
        }
    }

    private func sentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) {
        var synced = event.savedRecords.map(\.recordID.recordName)
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in event.failedRecordSaves {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // Already there, from an earlier install or the other device.
                synced.append(recordID.recordName)
            case .zoneNotFound:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                retry.append(.saveRecord(recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                 .operationCancelled, .requestRateLimited:
                break
            default:
                Log.history.error("history sync: save failed for \(recordID.recordName, privacy: .public): \(failure.error)")
            }
        }
        for (recordID, error) in event.failedRecordDeletes where error.code != .unknownItem {
            Log.history.error("history sync: delete failed for \(recordID.recordName, privacy: .public): \(error)")
        }
        syncEngine.state.add(pendingRecordZoneChanges: retry)
        store?.markSynced(ids: synced)
        if !synced.isEmpty || !event.deletedRecordIDs.isEmpty {
            Log.history.info("history sync: sent \(synced.count) row(s), \(event.deletedRecordIDs.count) deletion(s)")
        }
    }

    private func accountChanged(_ event: CKSyncEngine.Event.AccountChange) {
        switch event.changeType {
        case .signIn:
            engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            enqueueUploads()
        case .switchAccounts:
            store?.forgetCloud()
            engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            enqueueUploads()
        case .signOut:
            store?.forgetCloud()
        @unknown default:
            break
        }
    }
}
