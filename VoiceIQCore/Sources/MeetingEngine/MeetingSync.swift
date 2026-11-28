import CloudKit
import Foundation

/// Keeps meetings the same on the Mac and iPhone through the user's private
/// CloudKit database. Always on, like History and the dictionary: there is
/// no setting. Without an iCloud account, or without the container
/// entitlement (Debug builds on the Mac), meetings stay local.
///
/// One record per meeting, `Meeting` in zone `Meetings`, named by the meeting
/// id. Its `payload` is a `SyncedMeeting` (meta, notes, transcript, chat and
/// the folders it is filed in; never the audio) as LZFSE-compressed JSON. A meeting goes up once it is
/// done, and again whenever it changes on either device: renamed speakers,
/// redone notes, a new question. When both devices changed it, the one that
/// sends last keeps its notes and names, and the questions from both stay
/// (`MeetingStore.applyFromCloud`). Deleting a meeting deletes its record,
/// and the other device drops its copy.
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
    /// Changes when the account changes or the zone goes, so a retry fetch
    /// that was out then is not applied.
    private var generation = 0
    /// When the fetch now running started; see `MeetingStore.heldUploads`.
    private var fetchStarted: Date?
    /// The current fetch could not read the zone, so it may have missed deletes.
    private var zoneFetchFailed = false

    private init() {}

    private static var stateURL: URL {
        FileLayout.appSupportRoot.appendingPathComponent("meeting-sync-state.json")
    }

    public func start() {
        guard observers.isEmpty, !CloudSync.isDisabledForTests else { return }
        guard HistorySync.hasContainerEntitlement else {
            Log.meeting.info("meeting sync: no iCloud container entitlement, meetings stay on this device")
            return
        }
        observers = [
            NotificationCenter.default.addObserver(forName: .gtMeetingsDidChange, object: nil, queue: nil) { note in
                guard note.object as? String != "sync",
                      let id = (note.userInfo?[MeetingStore.idKey] as? String).flatMap(UUID.init(uuidString:)) else { return }
                let deleted = note.userInfo?[MeetingStore.deletedFromCloudKey] as? Bool ?? false
                Task { await MeetingSync.shared.localChanged(MeetingID(uuid: id), deleted: deleted) }
            },
        ]
        enable()
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

    /// Meetings that arrived but could not be written here. The engine has
    /// moved past them, so they are fetched by id.
    private func retryFailedImports() async {
        let ids = store.failedImports.compactMap(UUID.init(uuidString:)).map { Self.recordID(MeetingID(uuid: $0)) }
        guard engine != nil, !ids.isEmpty else { return }
        let database = CKContainer(identifier: HistorySync.containerID).privateCloudDatabase
        let started = generation
        guard let results = try? await database.records(for: ids) else { return }
        for (recordID, result) in results {
            guard generation == started else { return }
            switch result {
            case .success(let record):
                guard let meeting = Self.meeting(from: record) else { continue }
                let fields = Self.systemFields(of: record)
                // Still waiting: a delete fetched meanwhile takes it off the list.
                _ = await onMain { store in
                    store.failedImports.contains(recordID.recordName) && store.applyFromCloud(meeting, systemFields: fields)
                }
            case .failure(let error as CKError) where error.code == .unknownItem:
                // Deleted in iCloud meanwhile: nothing to bring in.
                _ = await onMain { $0.failedImports.remove(recordID.recordName) }
            case .failure:
                break
            }
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
        Task { await retryFailedImports() }
        engine.state.add(pendingRecordZoneChanges: store.pendingDeletes.compactMap(UUID.init(uuidString:))
            .map { .deleteRecord(Self.recordID(MeetingID(uuid: $0))) })
        Log.meeting.info("meeting sync started")
    }

    private func localChanged(_ id: MeetingID, deleted: Bool) {
        guard let engine else { return }
        if deleted {
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(Self.recordID(id))])
        } else if store.needsUpload(id: id) {
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(Self.recordID(id))])
        }
    }

    private func enqueueAll() {
        let pending = store.pendingUploads()
        guard let engine, !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending.map { .saveRecord(Self.recordID($0)) })
    }

    /// Every local edit to a meeting (the engine, the chat, the views) happens
    /// on the main actor, so a change from iCloud is read, compared and
    /// written there too, and no edit lands between its read and its write.
    private func onMain<T: Sendable>(_ body: @MainActor @Sendable (MeetingStore) -> T) async -> T {
        let store = store
        return await MainActor.run { body(store) }
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
        switch event {
        case .stateUpdate(let event):
            if let data = try? JSONEncoder().encode(event.stateSerialization) {
                try? data.write(to: Self.stateURL, options: .atomic)
            }
        case .accountChange(let event):
            generation += 1
            switch event.changeType {
            case .signIn:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                enqueueAll()
            case .switchAccounts:
                await onMain { $0.forgetCloud() }
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                enqueueAll()
            case .signOut:
                await onMain { $0.forgetCloud() }
            @unknown default:
                break
            }
        case .fetchedDatabaseChanges(let event):
            if event.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                Log.meeting.info("meeting sync: zone deleted in iCloud, starting over")
                generation += 1
                await onMain { $0.forgetCloud() }
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                enqueueAll()
            }
        case .fetchedRecordZoneChanges(let event):
            var changedHere: [CKSyncEngine.PendingRecordZoneChange] = []
            for modification in event.modifications {
                let record = modification.record
                guard let meeting = Self.meeting(from: record) else { continue }
                let fields = Self.systemFields(of: record)
                if await onMain({ $0.applyFromCloud(meeting, systemFields: fields) }) {
                    changedHere.append(.saveRecord(record.recordID))
                }
            }
            for deletion in event.deletions {
                // A delete from another device wins over an edit here that has not gone up.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(deletion.recordID)])
                if let id = Self.meetingID(deletion.recordID) { await onMain { $0.deleteFromCloud(id: id) } }
            }
            syncEngine.state.add(pendingRecordZoneChanges: changedHere)
            if !event.modifications.isEmpty || !event.deletions.isEmpty {
                Log.meeting.info("meeting sync: fetched \(event.modifications.count) meeting(s), \(event.deletions.count) deletion(s)")
            }
        case .sentRecordZoneChanges(let event):
            await sentRecordZoneChanges(event, syncEngine: syncEngine)
        case .sentDatabaseChanges(let event):
            for failure in event.failedZoneSaves {
                Log.meeting.error("meeting sync: zone save failed: \(failure.error)")
            }
        case .willFetchChanges:
            fetchStarted = Date()
            zoneFetchFailed = false
        case .didFetchRecordZoneChanges(let event):
            if let error = event.error {
                zoneFetchFailed = true
                Log.meeting.error("meeting sync: zone fetch failed: \(error)")
            }
        case .didFetchChanges:
            // Held meetings that this whole fetch did not delete go up as new records.
            // A fetch that could not read the zone may have missed their deletes.
            if let started = fetchStarted, !zoneFetchFailed {
                fetchStarted = nil
                let released = await onMain { $0.releaseHeld(before: started) }
                syncEngine.state.add(pendingRecordZoneChanges: released.map { .saveRecord(Self.recordID($0)) })
            }
            // After every fetch, pushed or asked for, on the Mac as on the iPhone.
            await retryFailedImports()
        case .willFetchRecordZoneChanges, .willSendChanges, .didSendChanges:
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
            // On the main actor, so no change from iCloud lands between the content and the change tag.
            let outgoing = await MainActor.run { Self.meetingID(recordID).flatMap(store.outgoing(id:)) }
            guard let outgoing, let record = Self.record(for: outgoing.meeting, systemFields: outgoing.systemFields) else {
                // Deleted, being redone, or too large: it goes up once it is done again.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return record
        }
    }

    private func sentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) async {
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
                if let server = failure.error.serverRecord, let meeting = Self.meeting(from: server) {
                    let fields = Self.systemFields(of: server)
                    guard await onMain({ $0.applyFromCloud(meeting, systemFields: fields) }) else { continue }
                    again.append(.saveRecord(recordID))
                    resend = true
                }
            case .unknownItem:
                // The copy this device last saw is gone: deleted on another device, or
                // its zone was made again. Held back until a later fetch says which, so
                // a delete still wins. The meeting stays meanwhile: it may hold the
                // only recording.
                if let id = Self.meetingID(recordID) {
                    await onMain { $0.hold(id: id) }
                    // Released only by a later fetch, which the engine may not run soon.
                    Task.detached {
                        do {
                            try await syncEngine.fetchChanges()
                        } catch {
                            Log.meeting.error("meeting sync: fetch after unknown item failed: \(error)")
                        }
                    }
                }
            case .zoneNotFound:
                // The zone is made again; the old change tag would only meet unknownItem.
                if let id = Self.meetingID(recordID) {
                    await onMain { store in
                        guard var state = store.loadCloudState(id: id) else { return }
                        state.systemFields = nil
                        try? store.saveCloudState(state, id: id)
                    }
                }
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
        if !gone.isEmpty { await onMain { [gone] in $0.pendingDeletes.subtract(gone) } }
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
