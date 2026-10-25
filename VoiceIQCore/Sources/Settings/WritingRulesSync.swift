import Foundation

/// The user's custom writing rules and when they were last edited. `text` is
/// nil when there are none.
public struct WritingRulesSnapshot: Codable, Equatable, Sendable {
    public var text: String?
    public var updatedAt: Date

    public init(text: String?, updatedAt: Date) {
        self.text = text
        self.updatedAt = updatedAt
    }

    /// The newer edit wins, the same on every device whatever the order. On a
    /// tie (two copies edited before sync existed) custom rules win over none,
    /// so turning sync on never wipes someone's rules.
    public static func merge(_ a: WritingRulesSnapshot, _ b: WritingRulesSnapshot) -> WritingRulesSnapshot {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
        switch (a.text, b.text) {
        case (nil, _): return b
        case (_, nil): return a
        case let (x?, y?): return x >= y ? a : b
        }
    }
}

/// Keeps the custom writing rules the same on the Mac and iPhone through the
/// iCloud key-value store `DictionarySync` uses, as one value, `writingRules.v2`.
/// `writingRules.v1` held the full rules text of older builds; it is left for
/// them and never read.
/// Always on: there is no setting. Without an iCloud account (or without the
/// entitlement, as in Debug builds) the rules stay local.
@MainActor
public final class WritingRulesSync {
    public static let shared = WritingRulesSync()

    static let key = "writingRules.v2"
    /// The store holds 1 MB in total and the dictionary may use most of it.
    static let maxBytes = 64_000

    private var started = false

    private init() {}

    public func start() {
        guard !started else { return }
        started = true
        let store = NSUbiquitousKeyValueStore.default
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            guard keys?.contains(WritingRulesSync.key) ?? true else { return }
            Task { @MainActor in WritingRulesSync.shared.reconcile(because: "iCloud change") }
        }
        NotificationCenter.default.addObserver(forName: .gtSettingDidChange, object: nil, queue: .main) { note in
            guard note.object as? String == SettingsStore.customWritingRulesKey else { return }
            Task { @MainActor in WritingRulesSync.shared.reconcile(because: "local edit", localEdit: true) }
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

    private func reconcile(because reason: String, localEdit: Bool = false) {
        let settings = SettingsStore()
        let local = settings.writingRulesSnapshot
        let store = NSUbiquitousKeyValueStore.default
        let remote = store.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(WritingRulesSnapshot.self, from: $0) }
        let merged = remote.map { WritingRulesSnapshot.merge(local, $0) } ?? local
        if merged != local {
            settings.applySyncedWritingRules(merged)
        }
        guard merged != remote else { return }
        // Until the first download finishes, iCloud shows no value even when
        // it holds a newer one. Only an edit made just now is certain to be
        // newest; anything older waits until the stored value can be compared.
        guard remote != nil || localEdit else { return }
        guard let data = try? JSONEncoder().encode(merged), data.count <= Self.maxBytes else {
            Log.session.error("writing rules sync: too large for iCloud key-value storage, kept on this device")
            return
        }
        store.set(data, forKey: Self.key)
        Log.session.info("writing rules sync (\(reason, privacy: .public)): \(merged.text == nil ? "none" : "custom", privacy: .public)")
    }
}
