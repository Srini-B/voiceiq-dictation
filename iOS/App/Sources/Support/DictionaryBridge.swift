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
    /// Keyboard-learned words already added, lowercased, so a word the user
    /// deletes from the Dictionary is not added again. Writer: app.
    private static let importedLearnedKey = "importedKeyboardLearnedWords"
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
        addLearnedWords()
    }

    /// Words the keyboard learned from typing join the Dictionary once each,
    /// as Auto-learned, and reach the Mac through `DictionarySync`.
    private static func addLearnedWords() {
        var imported = Set(UserDefaults.standard.stringArray(forKey: importedLearnedKey) ?? [])
        let fresh = SharedStore.shared.keyboardLearnedWords.filter { !imported.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return }
        let dictionary = DictionaryStore()
        var added = 0
        for word in fresh {
            if dictionary.add(term: word, source: .auto) { added += 1 }
            imported.insert(word.lowercased())
        }
        UserDefaults.standard.set(Array(imported), forKey: importedLearnedKey)
        SessionDiagnostics.note("keyboard learned words: \(added) added to the Dictionary")
    }

    private static func publishTerms() {
        SharedStore.shared.setDictionaryTerms(DictionaryStore().entries().map(\.term))
    }
}
