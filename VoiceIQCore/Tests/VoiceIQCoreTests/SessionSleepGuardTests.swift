#if os(macOS)
import IOKit.pwr_mgt
import XCTest
@testable import VoiceIQCore

/// The power assertions the Mac itself reports for this process, so each test
/// checks what keeps the Mac awake rather than the guard's own bookkeeping.
@MainActor
final class SessionSleepGuardTests: XCTestCase {
    private typealias Fakes = DictationCoordinatorTests
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionSleepGuardTests-\(UUID().uuidString)")
        FileLayout.overrideRoot = root.appendingPathComponent("dictation")
    }

    override func tearDown() async throws {
        FileLayout.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func heldAssertionTypes() -> Set<String> {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let own = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return Set(own.filter { $0[kIOPMAssertionNameKey] as? String == SessionSleepGuard.reason }
            .compactMap { $0[kIOPMAssertionTypeKey] as? String })
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private let awake: Set<String> = ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"]

    private func makeGuard(meetings: MeetingEngine) -> (SessionSleepGuard, DictationCoordinator, Fakes.FakeCapture) {
        let capture = Fakes.FakeCapture()
        let dictation = DictationCoordinator(audioFactory: { capture }, transcription: Fakes.FakeTranscription(),
                                             insertion: Fakes.FakeInserter(), secureInputActive: { false })
        return (SessionSleepGuard(dictation: dictation, meetings: meetings), dictation, capture)
    }

    private func makeMeetings() -> (MeetingEngine, MeetingStore) {
        let store = MeetingStore(root: root.appendingPathComponent("meetings"))
        return (MeetingEngine(client: AssemblyAIClient(apiKey: { nil }), store: store, config: { AssemblyAIConfig() },
                              hasKey: { true }), store)
    }

    /// A stopped meeting keeps the Mac and its display awake while it is
    /// transcribed, and lets go when that fails (here: its audio is missing).
    func testAMeetingBeingWrittenUpHoldsTheLockUntilItFails() async throws {
        let (meetings, store) = makeMeetings()
        var meta = MeetingMeta(id: MeetingID(), startedAt: Date())
        _ = try store.create(meta: meta)
        meta.status = .failed("earlier"); meta.failedStep = .transcript
        try store.save(meta: meta)
        let (sleepGuard, _, _) = makeGuard(meetings: meetings)
        XCTAssertTrue(heldAssertionTypes().isEmpty)

        meetings.retry(id: meta.id)
        XCTAssertEqual(heldAssertionTypes(), awake)

        await waitUntil { meetings.processing.isEmpty }
        XCTAssertTrue(meetings.processing.isEmpty)
        guard case .failed = try XCTUnwrap(store.list().first).status else { return XCTFail("meeting should fail") }
        XCTAssertTrue(heldAssertionTypes().isEmpty)
        sleepGuard.stop()
    }

    /// Dictation holds the lock from the start; cancelling it lets go, and so
    /// does shutting the app down in the middle of one.
    func testCancelAndShutdownReleaseADictationsLock() async {
        let (meetings, _) = makeMeetings()
        let (sleepGuard, dictation, _) = makeGuard(meetings: meetings)

        dictation.handle(.begin)
        XCTAssertEqual(heldAssertionTypes(), awake)
        dictation.handle(.cancel)
        await waitUntil { dictation.state.isTerminal }
        XCTAssertTrue(heldAssertionTypes().isEmpty)

        dictation.handle(.begin)
        XCTAssertEqual(heldAssertionTypes(), awake)
        sleepGuard.stop()
        XCTAssertTrue(heldAssertionTypes().isEmpty)
        dictation.handle(.cancel)
    }
}
#endif
