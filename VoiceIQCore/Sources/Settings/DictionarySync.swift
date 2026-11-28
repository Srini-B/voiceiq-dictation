import Foundation

/// Everything sync needs: the entries, and when each deleted entry was
/// deleted, so a deletion on one device is not undone by another's copy.
public struct DictionarySnapshot: Codable, Equatable, Sendable {
    public var entries: [DictionaryEntry]
    /// Entry ID (UUID string) → deletion time.
    public var tombstones: [String: Date]

    public init(entries: [DictionaryEntry] = [], tombstones: [String: Date] = [:]) {
        self.entries = entries
        self.tombstones = tombstones
    }

    /// Deletions are kept this long, longer than a device is likely to stay
    /// offline with an old copy.
    static let tombstoneLifetime: TimeInterval = 180 * 86_400

    /// Combines two copies. The same result on every device, whatever the
    /// order: the newer version of each entry wins, a deletion wins over any
    /// version it postdates, and two entries for the same word (added
    /// separately on two devices) become the older one, starred if either was.
    public static func merge(_ a: DictionarySnapshot, _ b: DictionarySnapshot, now: Date = Date()) -> DictionarySnapshot {
        var tombstones = a.tombstones.merging(b.tombstones) { max($0, $1) }
        tombstones = tombstones.filter { now.timeIntervalSince($0.value) < tombstoneLifetime }

        var byID: [UUID: DictionaryEntry] = [:]
        for entry in a.entries + b.entries {
            if let existing = byID[entry.id], !isNewer(entry, than: existing) { continue }
            byID[entry.id] = entry
        }
        var alive = byID.values.filter { entry in
            guard let deleted = tombstones[entry.id.uuidString] else { return true }
            return entry.updatedAt > deleted
        }

        // One entry per word. The survivor is the older entry (ties: the
        // smaller ID); the other is deleted everywhere.
        alive.sort { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString }
        var byTerm: [String: Int] = [:]
        var result: [DictionaryEntry] = []
        for entry in alive {
            let key = entry.term.lowercased()
            guard let index = byTerm[key] else {
                byTerm[key] = result.count
                result.append(entry)
                continue
            }
            var survivor = result[index]
            if entry.starred, !survivor.starred { survivor.starred = true }
            if survivor.misspelling == nil, let misspelling = entry.misspelling { survivor.misspelling = misspelling }
            if survivor != result[index] {
                survivor.updatedAt = max(survivor.updatedAt, entry.updatedAt)
                result[index] = survivor
            }
            tombstones[entry.id.uuidString] = max(tombstones[entry.id.uuidString] ?? entry.updatedAt, entry.updatedAt)
        }
        return DictionarySnapshot(entries: result, tombstones: tombstones)
    }

    private static func isNewer(_ entry: DictionaryEntry, than other: DictionaryEntry) -> Bool {
        if entry.updatedAt != other.updatedAt { return entry.updatedAt > other.updatedAt }
        // Same timestamp, different content: pick deterministically.
        return (try? JSONEncoder().encode(entry)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            > (try? JSONEncoder().encode(other)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

public extension Notification.Name {
    /// Posted after the dictionary changes, with `object` = "local" (an edit on
    /// this device) or "sync" (a merge from iCloud).
    static let gtDictionaryDidChange = Notification.Name("io.blue.voiceiq.dictionary-changed")
}

/// Keeps the dictionary the same on the Mac and iPhone through iCloud
/// key-value storage. Always on: there is no setting. Without an iCloud account
/// (or without the entitlement, as in Debug builds) the store stays local.
///
/// The whole dictionary is one value, `dictionary.v1`. Both apps share the
/// store through `com.apple.developer.ubiquity-kvstore-identifier`
/// `G8K3545FJ2.io.blue.voiceiq`. Every change merges this device's copy with
/// iCloud's (`DictionarySnapshot.merge`) and writes the result back to both
/// sides, so concurrent edits on two devices both survive.
@MainActor
public final class DictionarySync {
    public static let shared = DictionarySync()

    static let key = "dictionary.v1"
    /// Key-value storage allows 1 MB per value; stay under it.
    static let maxBytes = 900_000

    private(set) var started = false
    private var reconciling = false

    private init() {}

    public func start() {
        guard !started, !CloudSync.isDisabledForTests else { return }
        started = true
        let store = NSUbiquitousKeyValueStore.default
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor in DictionarySync.shared.reconcile(because: "iCloud change \(reason.map(String.init) ?? "?")") }
        }
        NotificationCenter.default.addObserver(forName: .gtDictionaryDidChange, object: nil, queue: .main) { note in
            guard note.object as? String != "sync" else { return }
            Task { @MainActor in DictionarySync.shared.reconcile(because: "local edit") }
        }
        store.synchronize()
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
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        let dictionary = DictionaryStore()
        let local = dictionary.snapshot()
        let store = NSUbiquitousKeyValueStore.default
        let remote = store.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(DictionarySnapshot.self, from: $0) }
        let merged = DictionarySnapshot.merge(local, remote ?? DictionarySnapshot())
        if merged != local {
            dictionary.apply(merged)
        }
        guard merged != remote else { return }
        guard let data = try? JSONEncoder().encode(merged), data.count <= Self.maxBytes else {
            Log.session.error("dictionary sync: too large for iCloud key-value storage, kept on this device")
            return
        }
        store.set(data, forKey: Self.key)
        Log.session.info("dictionary sync (\(reason, privacy: .public)): \(merged.entries.count) entries, \(merged.tombstones.count) deletions")
    }
}
