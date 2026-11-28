import XCTest
@testable import VoiceIQCore

/// The transcript shown in the field as a draft while the writing model
/// runs, then swapped for the written text.
@MainActor
final class DraftInsertTests: XCTestCase {
    /// Hears "raw words", then writes "Written words." a beat later.
    struct HearingTranscription: TranscriptionServicing {
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
            TranscriptionResult(rawTranscript: "raw words", cleanedTranscript: "Written words.", modelID: "test")
        }
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext,
                        live: RealtimeTranscription?,
                        onHeard: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
            onHeard?("raw words")
            try? await Task.sleep(nanoseconds: 30_000_000)
            return try await transcribe(audioURL: audioURL, durationSeconds: durationSeconds, context: context)
        }
    }

    final class FakeDraft: TextDraft {
        var shows: DraftShown
        var replaces: Bool
        private(set) var events: [String] = []
        init(shows: DraftShown, replaces: Bool = true) {
            self.shows = shows
            self.replaces = replaces
        }
        func show(_ text: String) async -> DraftShown { events.append("show \(text)"); return shows }
        func replace(with text: String) async -> Bool { events.append("replace \(text)"); return replaces }
        func end() { events.append("end") }
    }

    final class DraftingInserter: TextInserting {
        let draft: FakeDraft?
        private(set) var inserted: [String] = []
        init(draft: FakeDraft?) { self.draft = draft }
        func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
            inserted.append(text)
            return .inserted
        }
        func draft(context: DictationContext) async -> TextDraft? { draft }
    }

    private var sandbox: URL!

    override func setUp() async throws {
        try await super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-tests-\(UUID().uuidString)", isDirectory: true)
        FileLayout.overrideRoot = sandbox
    }

    override func tearDown() async throws {
        FileLayout.overrideRoot = nil
        try? FileManager.default.removeItem(at: sandbox)
        try await super.tearDown()
    }

    private func dictate(into inserter: DraftingInserter) async -> DictationCoordinator {
        let capture = DictationCoordinatorTests.FakeCapture()
        let coordinator = DictationCoordinator(
            audioFactory: { capture },
            transcription: HearingTranscription(),
            insertion: inserter,
            secureInputActive: { false }
        )
        coordinator.handle(.begin)
        for _ in 0..<8 { await Task.yield() }
        coordinator.handle(.finalize)
        for _ in 0..<300 where !coordinator.state.isTerminal {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return coordinator
    }

    func testTheDraftIsSwappedForTheWrittenTextAndNothingIsInsertedTwice() async {
        let draft = FakeDraft(shows: .shown)
        let inserter = DraftingInserter(draft: draft)
        let c = await dictate(into: inserter)
        XCTAssertEqual(c.state, .done(.inserted))
        XCTAssertEqual(draft.events, ["show raw words", "replace Written words.", "end"])
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertNil(c.insertedNotice)
        XCTAssertFalse(c.writingDraft)
    }

    /// A field that took nothing gets the written text by the usual insert.
    func testADraftThatNeverWentInLeavesTheInsertToTheLadder() async {
        let draft = FakeDraft(shows: .notInserted)
        let inserter = DraftingInserter(draft: draft)
        _ = await dictate(into: inserter)
        XCTAssertEqual(inserter.inserted, ["Written words."])
        XCTAssertFalse(draft.events.contains { $0.hasPrefix("replace") })
    }

    /// A draft that may have gone in but can't be found stays, and the
    /// written text does not go in beside it.
    func testALostDraftIsNeitherReplacedNorInsertedAgain() async {
        let draft = FakeDraft(shows: .lost)
        let inserter = DraftingInserter(draft: draft)
        let c = await dictate(into: inserter)
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(c.insertedNotice, DictationCoordinator.keptDraftNotice)
        XCTAssertEqual(c.lastResult, "Written words.")
    }

    /// The user edited the draft: it stays, with a note, and Paste last
    /// holds the written text.
    func testAnEditedDraftStaysWithANote() async {
        let draft = FakeDraft(shows: .shown, replaces: false)
        let inserter = DraftingInserter(draft: draft)
        let c = await dictate(into: inserter)
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(c.insertedNotice, DictationCoordinator.keptDraftNotice)
        XCTAssertEqual(c.lastResult, "Written words.")
    }
}
