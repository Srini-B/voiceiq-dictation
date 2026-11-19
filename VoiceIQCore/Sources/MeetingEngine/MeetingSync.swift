import CloudKit
import Foundation

/// Keeps meetings the same on the Mac and iPhone through the user's private
/// CloudKit database, while "Sync meetings with iCloud" is on
/// (`SettingsStore.syncsMeetings`, off by default, per device). Without an
/// iCloud account, or without the container entitlement (Debug builds on the
/// Mac), meetings stay local.
///
/// One record per meeting, `Meeting` in zone `Meetings`, named by the meeting
/// id. Its `payload` is a `SyncedMeeting` (meta, notes, transcript and chat;
/// never the audio) as LZFSE-compressed JSON. A meeting goes up once it is
/// done, and again whenever it changes on either device: renamed speakers,
/// redone notes, a new question. When both devices changed it, the one that
/// sends last keeps its notes and names, and the questions from both stay
/// (`MeetingStore.applyFromCloud`). Deleting a meeting deletes its record,
/// and the other device drops its copy. Turning the setting off stops
/// syncing on this device and keeps every meeting it has.
public actor MeetingSync {
    public static let shared = MeetingSync()

    static let zoneID = CKRecordZone.ID(zoneName: "Meetings")
    static let recordType = "Meeting"
    static let payloadKey = "payload"
    /// A record holds at most 1 MB; a compressed meeting of several hours is
    /// a few hundred KB.
    static let maxPayloadBytes = 900_000

    private var engine: CKSyncEngine?
    private let store = MeetingStore()
    private var observers: [any NSObjectProtocol] = []

    private init() {}

    private static var stateURL: URL {
        FileLayout.appSupportRoot.appendingPathComponent("meeting-sync-state.json")
    }

    /// Meetings deleted on this device whose records iCloud has not yet
    /// confirmed gone. Kept apart from the engine, so a delete made while
    /// sync is off still reaches iCloud once it is on again.
    private static var deletesURL: URL {
        FileLayout.appSupportRoot.appendingPathComponent("meeting-sync-deletes.json")
    }

    private var deletes: Set<String> {
        get { (try? Data(contentsOf: Self.deletesURL)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? [] }
        set {
            if newValue.isEmpty { try? FileManager.default.removeItem(at: Self.deletesURL) }
            else if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: Self.deletesURL, options: .atomic) }
        }
    }

    /// Syncs while the setting is on, from now on.
    public func start() {
        guard observers.isEmpty else { return }
        guard HistorySync.hasContainerEntitlement else {
            Log.meeting.info("meeting sync: no iCloud container entitlement, meetings stay on this device")
            return
        }
        observers = [
            NotificationCenter.default.addObserver(forName: .gtSettingDidChange, object: nil, queue: nil) { note in
                guard note.object as? String == SettingsStore.meetingSyncKey else { return }
                Task { await MeetingSync.shared.settingChanged() }
            },
            NotificationCenter.default.addObserver(forName: .gtMeetingsDidChange, object: nil, queue: nil) { note in
                guard note.object as? String != "sync",
                      let id = (note.userInfo?[MeetingStore.idKey] as? String).flatMap(UUID.init(uuidString:)) else { return }
                let deleted = note.userInfo?[MeetingStore.deletedFromCloudKey] as? Bool ?? false
                Task { await MeetingSync.shared.localChanged(MeetingID(uuid: id), deleted: deleted) }
            },
        ]
        if SettingsStore().syncsMeetings { enable() }
    }

    /// Call when the app comes to the front: iOS delivers no push to a
    /// suspended app.
    public func refresh() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
        } catch {
            Log.meeting.error("meeting sync: fetch failed: \(error)")
        }
    }

    private func settingChanged() async {
        if SettingsStore().syncsMeetings {
            enable()
        } else if let engine {
            self.engine = nil
            await engine.cancelOperations()
            Log.meeting.info("meeting sync stopped")
        }
    }

    private func enable() {
        guard engine == nil else { return }
        let state = (try? Data(contentsOf: Self.stateURL))
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let container = CKContainer(identifier: HistorySync.containerID)
        let engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: state, delegate: self
        ))
        self.engine = engine
        if state == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        enqueueAll()
        engine.state.add(pendingRecordZoneChanges: deletes.compactMap(UUID.init(uuidString:))
            .map { .deleteRecord(Self.recordID(MeetingID(uuid: $0))) })
        Log.meeting.info("meeting sync started")
    }

    private func localChanged(_ id: MeetingID, deleted: Bool) {
        if deleted {
            deletes.insert(id.uuid.uuidString)
            engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(Self.recordID(id))])
            return
        }
        guard let engine else { return }
        if store.needsUpload(id: id) {
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(Self.recordID(id))])
        }
    }

    private func enqueueAll() {
        let pending = store.pendingUploads()
        guard let engine, !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending.map { .saveRecord(Self.recordID($0)) })
    }

    private static func recordID(_ id: MeetingID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuid.uuidString, zoneID: zoneID)
    }

    private static func meetingID(_ recordID: CKRecord.ID) -> MeetingID? {
        UUID(uuidString: recordID.recordName).map { MeetingID(uuid: $0) }
    }
}

// MARK: - Records

extension MeetingSync {
    static func record(for meeting: SyncedMeeting, systemFields: Data?) -> CKRecord? {
        guard let json = try? JSONEncoder().encode(meeting),
              let payload = try? (json as NSData).compressed(using: .lzfse) as Data else { return nil }
        guard payload.count <= maxPayloadBytes else {
            Log.meeting.error("meeting sync: \(meeting.meta.id.uuid.uuidString, privacy: .public) is too large to sync (\(payload.count) bytes)")
            return nil
        }
        let record = systemFields.flatMap(Self.record(systemFields:))
            ?? CKRecord(recordType: recordType, recordID: recordID(meeting.meta.id))
        record[payloadKey] = payload
        return record
    }

    static func meeting(from record: CKRecord) -> SyncedMeeting? {
        guard let payload = record[payloadKey] as? Data,
              let json = try? (payload as NSData).decompressed(using: .lzfse) as Data,
              let meeting = try? JSONDecoder().decode(SyncedMeeting.self, from: json),
              meeting.meta.id.uuid.uuidString == record.recordID.recordName else { return nil }
        return meeting
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(systemFields: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}

// MARK: - CKSyncEngineDelegate

extension MeetingSync: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // A turned-off engine can still deliver what it was doing.
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let event):
            if let data = try? JSONEncoder().encode(event.stateSerialization) {
                try? data.write(to: Self.stateURL, options: .atomic)
            }
        case .accountChange(let event):
            switch event.changeType {
            case .signIn:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                enqueueAll()
            case .switchAccounts:
                store.forgetCloud()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                enqueueAll()
            case .signOut:
                store.forgetCloud()
            @unknown default:
                break
            }
        case .fetchedDatabaseChanges(let event):
            if event.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                Log.meeting.info("meeting sync: zone deleted in iCloud, starting over")
                store.forgetCloud()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                enqueueAll()
            }
        case .fetchedRecordZoneChanges(let event):
            var changedHere: [CKSyncEngine.PendingRecordZoneChange] = []
            for modification in event.modifications {
                let record = modification.record
                guard let meeting = Self.meeting(from: record) else { continue }
                if store.applyFromCloud(meeting, systemFields: Self.systemFields(of: record)) {
                    changedHere.append(.saveRecord(record.recordID))
                }
            }
            for deletion in event.deletions {
                if let id = Self.meetingID(deletion.recordID) { store.deleteFromCloud(id: id) }
            }
            syncEngine.state.add(pendingRecordZoneChanges: changedHere)
            if !event.modifications.isEmpty || !event.deletions.isEmpty {
                Log.meeting.info("meeting sync: fetched \(event.modifications.count) meeting(s), \(event.deletions.count) deletion(s)")
            }
        case .sentRecordZoneChanges(let event):
            sentRecordZoneChanges(event, syncEngine: syncEngine)
        case .sentDatabaseChanges(let event):
            for failure in event.failedZoneSaves {
                Log.meeting.error("meeting sync: zone save failed: \(failure.error)")
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
        let store = store
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            guard let id = Self.meetingID(recordID), let meeting = store.synced(id: id),
                  let record = Self.record(for: meeting, systemFields: store.loadCloudState(id: id)?.systemFields) else {
                // Deleted, being redone, or too large: it goes up once it is done again.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return record
        }
    }

    private func sentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) {
        var again: [CKSyncEngine.PendingRecordZoneChange] = []
        var resend = false
        for record in event.savedRecords {
            guard let meeting = Self.meeting(from: record) else { continue }
            store.markSent(meeting, systemFields: Self.systemFields(of: record))
            // Changed again while it was on its way up.
            if store.needsUpload(id: meeting.meta.id) { again.append(.saveRecord(record.recordID)) }
        }
        for failure in event.failedRecordSaves {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // The other device saved it first: take its questions, then send ours over its copy.
                if let server = failure.error.serverRecord, let meeting = Self.meeting(from: server),
                   store.applyFromCloud(meeting, systemFields: Self.systemFields(of: server)) {
                    again.append(.saveRecord(recordID))
                    resend = true
                }
            case .unknownItem:
                // Gone from iCloud since this device last saw it: send it as new.
                if let id = Self.meetingID(recordID), var state = store.loadCloudState(id: id) {
                    state.systemFields = nil
                    store.saveCloudState(state, id: id)
                }
                again.append(.saveRecord(recordID))
                resend = true
            case .zoneNotFound:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                again.append(.saveRecord(recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                 .operationCancelled, .requestRateLimited:
                break
            default:
                Log.meeting.error("meeting sync: save failed for \(recordID.recordName, privacy: .public): \(failure.error)")
            }
        }
        var gone = Set(event.deletedRecordIDs.map(\.recordName))
        for (recordID, error) in event.failedRecordDeletes {
            if error.code == .unknownItem { gone.insert(recordID.recordName); continue }
            Log.meeting.error("meeting sync: delete failed for \(recordID.recordName, privacy: .public): \(error)")
        }
        if !gone.isEmpty { deletes.subtract(gone) }
        syncEngine.state.add(pendingRecordZoneChanges: again)
        if resend {
            // The engine does not schedule another send for a save that failed
            // (see HistorySync), so send now. Detached: CloudKit traps when the
            // delegate callback awaits the engine.
            Task.detached {
                do {
                    try await syncEngine.sendChanges()
                } catch {
                    Log.meeting.error("meeting sync: resend failed: \(error)")
                }
            }
        }
        if !event.savedRecords.isEmpty || !event.deletedRecordIDs.isEmpty {
            Log.meeting.info("meeting sync: sent \(event.savedRecords.count) meeting(s), \(event.deletedRecordIDs.count) deletion(s)")
        }
    }
}
