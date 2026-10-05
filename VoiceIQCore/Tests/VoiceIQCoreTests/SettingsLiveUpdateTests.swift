import XCTest
@testable import VoiceIQCore

/// The settings live-audit contract: every write announces itself, so runtime
/// surfaces can re-render the moment a toggle flips (dogfood: "I turned the
/// resting indicator on and off and it didn't work").
final class SettingsLiveUpdateTests: XCTestCase {
    private let settings = SettingsStore()

    override func tearDown() {
        for key in ["showIdleIndicator", "soundsEnabled", "gateTrips",
                    "experimentalNoiseHandling", "smartTranscription", "smartCleanupPass"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func expectChange(forKey key: String, during action: () -> Void) {
        let posted = expectation(description: "gtSettingDidChange(\(key))")
        let observer = NotificationCenter.default.addObserver(
            forName: .gtSettingDidChange, object: nil, queue: nil
        ) { note in
            if note.object as? String == key {
                posted.fulfill()
            }
        }
        action()
        wait(for: [posted], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
    }

    func testEverySetterPostsItsKey() {
        expectChange(forKey: "showIdleIndicator") { settings.setShowIdleIndicator(false) }
        expectChange(forKey: "soundsEnabled") { settings.setSoundsEnabled(false) }
        expectChange(forKey: "smartTranscription") { settings.setSmartTranscription(false) }
        expectChange(forKey: "smartCleanupPass") { settings.setSmartCleanupPass(false) }
        expectChange(forKey: "dictationTrigger") { settings.setDictationTrigger(.modifier(.fn)) }
        expectChange(forKey: "audioRetentionDays") { settings.setAudioRetentionDays(7) }
        expectChange(forKey: "experimentalNoiseHandling") { settings.setExperimentalNoiseHandling(true) }
    }
}

final class DictionaryImportTests: XCTestCase {
    private let store = DictionaryStore()

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
    }

    func testHeaderRowIsDropped() {
        XCTAssertEqual(store.importCSV("term,misspelling\nKubernetes,cooper netties"), 1)
        XCTAssertEqual(store.entries().map(\.term), ["Kubernetes"])
    }

    func testHeaderlessFirstRowStartingWithTermIsKept() {
        // "terminal" hasPrefix("term") — the old sniff ate this real entry.
        XCTAssertEqual(store.importCSV("terminal,termie\nKubernetes,"), 2)
        XCTAssertEqual(store.entries().map(\.term), ["terminal", "Kubernetes"])
    }

    func testImportDedupesAgainstExistingAndItself() {
        _ = store.add(term: "Gemini")
        let count = store.importCSV("gemini,\nGemini,\nVeo,\nveo,")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.entries().map(\.term), ["Gemini", "Veo"])
    }

    func testSpellingsPrioritizeStarred() {
        for i in 0..<12 {
            _ = store.add(term: "term\(i)", misspelling: "wrong\(i)")
        }
        // Star the OLDEST entry — insertion order would leave it last.
        let oldest = store.entries().first!
        store.toggleStar(id: oldest.id)
        let spellings = store.spellings()
        XCTAssertEqual(spellings.count, 10)
        XCTAssertEqual(spellings.first?.right, oldest.term,
                       "starred entries must lead the prompt's spelling hints")
    }
}
