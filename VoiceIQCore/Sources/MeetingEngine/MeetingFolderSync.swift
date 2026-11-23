import Foundation

/// Keeps the meeting folder list the same on the Mac and iPhone through the
/// iCloud key-value store the dictionary uses, as one value,
/// `meetingFolders.v1`. Always on, like meeting sync. Which meetings are in
/// a folder travels with each meeting through `MeetingSync`.
///
/// Every change merges this device's list with iCloud's
/// (`MeetingFoldersSnapshot.merge`) and writes the result to both sides, so
/// folders made, renamed or deleted on two devices all survive. Key-value
/// storage needs no CloudKit schema, which a new record type would.
@MainActor
public final class MeetingFolderSync {
    public static let shared = MeetingFolderSync()

    static let key = "meetingFolders.v1"
    /// The store holds 1 MB in total and the dictionary may use most of it.
    static let maxBytes = 64_000

    private let store = MeetingStore()
    private var started = false

    private init() {}

    public func start() {
        guard !started else { return }
        started = true
        let cloud = NSUbiquitousKeyValueStore.default
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            guard keys?.contains(MeetingFolderSync.key) ?? true else { return }
            Task { @MainActor in MeetingFolderSync.shared.reconcile(because: "iCloud change") }
        }
        NotificationCenter.default.addObserver(forName: .gtMeetingFoldersDidChange, object: nil, queue: .main) { note in
            guard note.object as? String != "sync" else { return }
            Task { @MainActor in MeetingFolderSync.shared.reconcile(because: "local edit") }
        }
        cloud.synchronize()
        reconcile(because: "start")
    }

    /// Call when the app comes to the front: iOS delivers no change
    /// notifications to a suspended app.
    public func refresh() {
        guard started else { return }
        NSUbiquitousKeyValueStore.default.synchronize()
        reconcile(because: "refresh")
    }

    private func reconcile(because reason: String) {
        let local: MeetingFoldersSnapshot
        do {
            local = try store.readFoldersSnapshot()
        } catch {
            Log.meeting.error("meeting folder sync: folders.json cannot be read, left as it is: \(error)")
            return
        }
        let cloud = NSUbiquitousKeyValueStore.default
        let stored = cloud.data(forKey: Self.key)
        let remote = stored.flatMap { try? JSONDecoder().decode(MeetingFoldersSnapshot.self, from: $0) }
        // Written by a later build in a shape this one cannot read: left for it.
        guard stored == nil || remote != nil else {
            Log.meeting.error("meeting folder sync: the folders in iCloud cannot be read, left as they are")
            return
        }
        let merged = MeetingFoldersSnapshot.merge(local, remote ?? MeetingFoldersSnapshot())
        if merged != local {
            do {
                try store.saveFolders(merged, fromSync: true)
            } catch {
                Log.meeting.error("meeting folder sync: could not save: \(error)")
                return
            }
        }
        guard merged != remote else { return }
        guard let data = try? JSONEncoder().encode(merged), data.count <= Self.maxBytes else {
            Log.meeting.error("meeting folder sync: too large for iCloud key-value storage, kept on this device")
            return
        }
        cloud.set(data, forKey: Self.key)
        Log.meeting.info("meeting folder sync (\(reason, privacy: .public)): \(merged.folders.count) folders, \(merged.tombstones.count) deletions")
    }
}
