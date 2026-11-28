import AVFoundation
import XCTest
@testable import VoiceIQCore

/// Rename…, Copy prompt for an AI agent, and the warning for a call whose
/// other side was never heard, in the Meetings window.
final class MeetingRenameTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingRenameTests-\(UUID().uuidString)")
        store = MeetingStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func finishedMeeting() throws -> MeetingID {
        var meta = MeetingMeta(id: MeetingID(), startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        _ = try store.create(meta: meta)
        try store.save(transcript: [TranscriptSegment(speaker: "s1", text: "Pricing ships in May.", chunkIndex: 0, start: 4)], id: meta.id)
        try store.save(notes: MeetingNotes(title: "Pricing sync", summary: "s", decisions: [], actions: [], notes: []), id: meta.id)
        meta.status = .done; meta.title = "Pricing sync"
        try store.save(meta: meta)
        return meta.id
    }

    private func meta(_ id: MeetingID) throws -> MeetingMeta { try XCTUnwrap(store.list().first { $0.id == id }) }

    /// A meeting the app died on while transcribing or writing notes fails as
    /// interrupted at the next launch instead of showing "Making notes" forever;
    /// the one that was writing notes keeps its transcript, so Retry writes the notes.
    @MainActor func testAMeetingInterruptedWhileWritingUpFailsAtLaunch() throws {
        var notes = MeetingMeta(id: MeetingID(), startedAt: Date(), status: .summarizing)
        var transcribing = MeetingMeta(id: MeetingID(), startedAt: Date(), status: .transcribing)
        transcribing.failedStep = .notes  // a notes failure before Redo transcript and notes
        _ = try store.create(meta: notes); _ = try store.create(meta: transcribing)
        _ = MeetingEngine(client: AssemblyAIClient(apiKey: { nil }), store: store, config: { AssemblyAIConfig() }, hasKey: { false })
        notes = try meta(notes.id); transcribing = try meta(transcribing.id)
        XCTAssertEqual(notes.status, .failed("VoiceiQ closed while writing the notes. The transcript is saved. Press Retry to write them."))
        XCTAssertEqual(notes.failedStep, .notes)
        XCTAssertEqual(transcribing.status, .failed("VoiceiQ closed while transcribing. The recording is saved. Press Retry to transcribe it."))
        XCTAssertEqual(transcribing.failedStep, .transcript)
    }

    func testARenameOutlivesRedoNotesAndEmptyPutsTheNotesTitleBack() throws {
        let id = try finishedMeeting()
        try store.renameMeeting(id: id, title: "  Q3 pricing with Priya \n")
        XCTAssertEqual(try MeetingStore(root: root).list().first?.shownTitle(), "Q3 pricing with Priya")

        // Redo notes, as `MeetingEngine` saves them: new notes, their title into meta.title.
        let notes = MeetingNotes(title: "Pricing follow-up", summary: "s", decisions: [], actions: [], notes: [])
        try store.save(notes: notes, id: id)
        var redone = try meta(id)
        redone.title = notes.title
        try store.save(meta: redone)
        XCTAssertEqual(try meta(id).shownTitle(notes: try store.loadNotes(id: id)), "Q3 pricing with Priya")
        XCTAssertTrue(try store.markdown(id: id, parts: .notes).hasPrefix("# Q3 pricing with Priya\n"))

        try store.renameMeeting(id: id, title: " ")
        XCTAssertEqual(try meta(id).shownTitle(notes: try store.loadNotes(id: id)), "Pricing follow-up")
    }

    func testARenameSyncsAndAgentsSeeIt() throws {
        let id = try finishedMeeting()
        store.markSent(try XCTUnwrap(store.synced(id: id)), systemFields: Data("fields".utf8))
        try store.renameMeeting(id: id, title: "Q3 pricing")
        XCTAssertEqual(store.pendingUploads(), [id])

        // Another device that had the meeting unchanged takes the renamed copy.
        let other = MeetingStore(root: root.appendingPathComponent("other"))
        other.applyFromCloud(try XCTUnwrap(store.synced(id: id)), systemFields: Data("fields".utf8))
        XCTAssertEqual(other.list().first?.shownTitle(), "Q3 pricing")

        let library = AgentLibrary(history: nil, meetings: store)
        XCTAssertEqual(try library.meeting(id.uuid.uuidString).meeting.title, "Q3 pricing")
        XCTAssertEqual(library.meetings(query: nil, since: nil, limit: 5).first?.title, "Q3 pricing")
        XCTAssertEqual(library.meetings(query: "q3", since: nil, limit: 5).map(\.id), [id.uuid.uuidString])
    }

    func testTheAgentPromptNamesToolsAgentAccessHasAndTheMeetingsID() throws {
        let id = MeetingID()
        let prompt = AgentAPI.meetingPrompt(id: id, title: "Q3 pricing")
        let tools = AgentAPI.tools.compactMap { $0["name"] as? String }
        for tool in ["get_meeting", "list_meetings"] {
            XCTAssertTrue(tools.contains(tool), tool)
            XCTAssertTrue(prompt.contains(tool), tool)
        }
        XCTAssertTrue(prompt.contains("\"\(id.uuid.uuidString)\""))
    }

    private func writeSystemTrack(seconds: Double, soundAt: Int? = nil, level: Int16 = 1_000) throws -> URL {
        let folder = root.appendingPathComponent("call", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: TrackAudio.sampleRate, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent("system.caf"), settings: format.settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(seconds * TrackAudio.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        samples.update(repeating: 0, count: Int(frames))
        if let soundAt { samples[soundAt] = level }
        try file.write(from: buffer)
        return folder
    }

    func testOnlyALongCallWithAQuietSystemTrackIsUnheard() throws {
        let call = MeetingMeta(id: MeetingID(), startedAt: Date(), source: .app(bundleID: "us.zoom.xos", name: "zoom.us"),
                               durationSeconds: 90, status: .done)
        let silent = try writeSystemTrack(seconds: 90)
        XCTAssertEqual(SilentSystemAudio.check(call, folder: silent), .zeros)

        var byHand = call
        byHand.source = nil
        XCTAssertNil(SilentSystemAudio.check(byHand, folder: silent))
        var short = call
        short.durationSeconds = 45
        XCTAssertNil(SilentSystemAudio.check(short, folder: silent))
        XCTAssertNil(SilentSystemAudio.check(call, folder: root.appendingPathComponent("no-audio")))

        // Noise near −80 dBFS, as m2 and m3 of the live-call probe wrote, heard nobody, with the permission granted.
        let noise = try writeSystemTrack(seconds: 90, soundAt: 80 * 16_000, level: 3)
        XCTAssertEqual(SilentSystemAudio.check(call, folder: noise), .quiet)
        // A Meet call's speech peaked near −60 dBFS (TrackAudio.gain): heard.
        let meet = try writeSystemTrack(seconds: 90, soundAt: 80 * 16_000, level: 32)
        XCTAssertNil(SilentSystemAudio.check(call, folder: meet))
    }
}
