import Foundation
import VoiceIQBridge
import VoiceIQCore

/// The dictionary's links outside the app: iCloud sync with the Mac, words
/// the keyboard queues from a selection or the clipboard, and the word list
/// the keyboard reads to tell whether a selection is already saved.
@MainActor
enum DictionaryBridge {
    /// IDs of keyboard additions already added. Writer: app (own defaults).
    private static let handledKey = "handledDictionaryAdditions"
    private static var observer: UUID?

    static func start() {
        DictionarySync.shared.start()
        NotificationCenter.default.addObserver(forName: .gtDictionaryDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in publishTerms() }
        }
        observer = DarwinNotifier.observe(.dictionary) {
            Task { @MainActor in addQueuedWords() }
        }
        addQueuedWords()
        publishTerms()
    }

    /// Darwin pings and iCloud changes are not delivered while suspended.
    static func appBecameActive() {
        addQueuedWords()
        DictionarySync.shared.refresh()
    }

    private static func addQueuedWords() {
        let shared = SharedStore.shared
        shared.reloadFromDisk()
        let queued = shared.dictionaryAdditions
        var handled = Set(UserDefaults.standard.stringArray(forKey: handledKey) ?? [])
        for addition in queued where !handled.contains(addition.id.uuidString) {
            let added = DictionaryStore().add(term: addition.term)
            SessionDiagnostics.note("keyboard dictionary word \(added ? "added" : "already saved")")
            handled.insert(addition.id.uuidString)
        }
        // Only IDs still in the keyboard's list can come up again.
        let live = Set(queued.map(\.id.uuidString))
        UserDefaults.standard.set(Array(handled.intersection(live)), forKey: handledKey)
    }

    private static func publishTerms() {
        SharedStore.shared.setDictionaryTerms(DictionaryStore().entries().map(\.term))
    }
}
