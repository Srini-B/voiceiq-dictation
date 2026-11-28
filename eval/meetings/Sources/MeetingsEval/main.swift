import Foundation
import VoiceIQCore
import VoiceIQInference
import VoiceIQSpeech

// Usage: ASSEMBLYAI_API_KEY=… swift run -c release MeetingsEval DATA_DIR OUT_DIR [meeting-id …]
//
// For each meeting prepare.py wrote, does what MeetingEngine does after a
// recording stops: transcribe (AssemblyAI STT-3.7 + the on-device speaker model), match
// the call window's names, write the notes, and name the speakers the way the
// meeting screen shows them. Writes OUT_DIR/<id>.json for the scorer.

struct Input: Decodable {
    var id: String
    var title: String?
    var app: String
    var owner: String
    var calendar: [String]
    /// "gallery": every participant's tile is on screen the whole call.
    var screen: String?
    var people: [String]?
}

struct Output: Encodable {
    struct Segment: Codable { var start: Double; var end: Double; var speaker_name: String; var speaker_id: String; var text: String }
    var id: String
    var segments: [Segment]
    var participants: [String]
    var notes: String
    var seconds: [String: Double]
    /// Every AssemblyAI call the meeting made, as `UsageMeter` recorded it, priced
    /// by `PriceBook` at January 2027 prices. Without transcription calls when EVAL_TRANSCRIPTS was set.
    var usage: [Call]
    var duration_seconds: Double
    /// Nil when a call had no price. Transcription is nil when
    /// EVAL_TRANSCRIPTS skipped it. A short call's per-hour cost is dominated
    /// by its fixed notes prompt; take C1's per-hour figure from long meetings.
    var transcribe_cost_usd: Double?
    var notes_cost_usd: Double?
    var cost_usd: Double?
    var cost_usd_per_hour: Double?

    struct Call: Encodable {
        var stage: String; var model: String
        var text_in: Int; var audio_in: Int; var image_in: Int; var cached_in: Int
        var text_out: Int; var audio_out: Int; var thought_out: Int
        var estimated: Bool; var cost_usd: Double?
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Every 3 s, as `ScreenNameSampler` reads a call window that shows everyone.
func gallerySamples(people: [String], owner: String, duration: Double) -> [ScreenNameSample] {
    let tags = people.map { $0 == owner ? "\($0) (You)" : $0 }
    return stride(from: 1.0, to: duration, by: 3).map { time in
        ScreenNameSample(time: time, names: ScreenSpeakerNames.candidates(in: tags), me: ScreenSpeakerNames.owner(in: tags),
                         single: ScreenSpeakerNames.singleNames(in: tags), count: people.count)
    }
}

@MainActor
func diarizerDirectory() async -> URL {
    let store = LocalModelStore.speakerDiarizer
    store.download()
    while true {
        switch store.state {
        case .ready:
            guard let url = store.acquireSession(id: UUID(), cancel: {}) else { fail("speaker model busy") }
            return url
        case .failed(let reason): fail("speaker model download failed: \(reason)")
        case .unsupported: fail("speaker model unsupported on this Mac")
        default: try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: MeetingsEval DATA_DIR OUT_DIR [meeting-id …]") }
guard let key = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"], !key.isEmpty else { fail("ASSEMBLYAI_API_KEY is not set") }
let data = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let only = Set(args.dropFirst(3))
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let config = AssemblyAIConfig()
let client = AssemblyAIClient(apiKey: { key })
// EVAL_NO_SPEAKER_MODEL=1 runs without the on-device speaker model, as an
// install that never downloaded it did before it was fetched automatically.
// EVAL_TRANSCRIPTS=DIR takes each meeting's transcript from an earlier run's
// output in DIR and only writes the notes again, for notes changes when the
// transcription quota is spent.
let earlierTranscripts = ProcessInfo.processInfo.environment["EVAL_TRANSCRIPTS"].map { URL(fileURLWithPath: $0) }
let useSpeakerModel = ProcessInfo.processInfo.environment["EVAL_NO_SPEAKER_MODEL"] == nil && earlierTranscripts == nil
let diarizer = useSpeakerModel ? await diarizerDirectory() : nil
var diarizeFarSide: MeetingTranscriber.FarSideDiarizer?
if let diarizer {
    // Retried as the app retries it (MeetingEngine.farSideDiarizer).
    diarizeFarSide = { audio in
        try await MeetingTranscriber.retryingSpeakerModel { cpuOnly in
            try await LocalSpeechInference.transcribeMeeting(
                LocalMeetingRequest(speechDirectory: nil, diarizerDirectory: diarizer, audio: audio, cpuOnly: cpuOnly)).segments
        }
    }
}
let transcriber = MeetingTranscriber(client: client, diarizeFarSide: diarizeFarSide)
// Priced as of January 2027, the date the C1 cost gate uses.
let pricedAt = ISO8601DateFormatter().date(from: "2027-01-02T00:00:00Z")!
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-eval-usage-\(UUID().uuidString).sqlite")
let usageStore = try UsageStore(databaseURL: scratch)
UsageMeter.store = usageStore
let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("meetings-eval-\(UUID().uuidString)"))

let meetings = try FileManager.default.contentsOfDirectory(atPath: data.path).sorted()
    .filter { !$0.hasPrefix(".") && (only.isEmpty || only.contains($0)) }
var failures = 0
for name in meetings {
    let source = data.appendingPathComponent(name)
    guard let inputData = try? Data(contentsOf: source.appendingPathComponent("input.json")) else { continue }
    let input = try JSONDecoder().decode(Input.self, from: inputData)
    // As MeetingEngine does, every call is metered under the meeting's id.
    do { try await UsageMeter.$scope.withValue(UsageScope(activity: .meeting, sessionID: input.id)) { try await evaluate(input, source: source) } } catch {
        failures += 1
        print("\(input.id): FAILED \(error)")
    }
}
exit(failures == 0 ? 0 : 2)

@MainActor func evaluate(_ input: Input, source: URL) async throws {
    print("\(input.id): transcribing")
    var meta = MeetingMeta(id: MeetingID(), startedAt: Date(), source: .app(bundleID: input.app, name: input.app))
    let folder = try store.create(meta: meta)
    for file in ["mic.caf", "system.caf"] {
        try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: folder.appendingPathComponent(file))
    }
    // The longer track: a silent far side is shorter than the meeting.
    meta.durationSeconds = try max(TrackAudio(url: folder.appendingPathComponent("system.caf")).duration,
                                   TrackAudio(url: folder.appendingPathComponent("mic.caf")).duration)
    let samples = input.screen == "gallery"
        ? gallerySamples(people: input.people ?? [], owner: input.owner, duration: meta.durationSeconds) : []
    try store.save(screenSamples: samples, id: meta.id)
    if !input.calendar.isEmpty || input.title != nil {
        meta.calendarEvent = .init(title: input.title ?? "Meeting", attendees: input.calendar)
    }

    var clock = Date()
    var seconds: [String: Double] = [:]
    let transcript: [TranscriptSegment]
    if let earlierTranscripts {
        transcript = try earlierTranscript(input.id, in: earlierTranscripts)
    } else {
        transcript = try await transcriber.transcribe(folder: folder)
        if MeetingTranscriber.farSideFailed(folder: folder) {
            print("\(input.id): WARNING the speaker model failed after retries; the far side kept AssemblyAI's voices")
        }
    }
    seconds["transcribe"] = Date().timeIntervalSince(clock)
    meta.screenNames = ScreenSpeakerNames.byAddress(ScreenSpeakerNames.match(samples: samples, transcript: transcript),
                                                    transcript: transcript, invited: meta.calendarEvent?.attendees ?? [])
    try store.save(transcript: transcript, id: meta.id)

    print("\(input.id): notes")
    clock = Date()
    let write = { (meta: MeetingMeta) in
        try await client.meetingNotes(prompt: MeetingNotesPrompt.build(transcript: transcript, context: .init(
            startedAt: meta.startedAt, durationSeconds: meta.durationSeconds, app: input.app, names: [:],
            screenNames: meta.screenNames, ownerName: input.owner, calendarEvent: meta.calendarEvent)),
            transcript: transcript, model: config.writingModel, deadline: 900)
    }
    // As MeetingEngine.writeNotes does: a voice named by elimination gets the notes written again.
    // An account without a gateway balance still scores the transcript (M2–M4).
    var notes: MeetingNotes
    do { notes = try await write(meta) } catch TranscriptionError.noBalance {
        print("\(input.id): no gateway balance; transcript only")
        notes = MeetingNotes(title: "Meeting", summary: "", decisions: [], actions: [], notes: [])
    }
    let named = ScreenSpeakerNames.byElimination(meta: meta, transcript: transcript, notes: notes)
    if named != meta.screenNames {
        meta.screenNames = named
        if var again = try? await write(meta) {
            let renamed = Set((again.speakers ?? []).filter { $0.name != nil }.map(\.label))
            again.speakers = (again.speakers ?? []) + (notes.speakers ?? []).filter { $0.name != nil && !renamed.contains($0.label) }
            notes = again
        }
    }
    seconds["notes"] = Date().timeIntervalSince(clock)
    meta.title = notes.title
    // As MeetingEngine.finish does.
    meta.screenNames = ScreenSpeakerNames.byElimination(meta: meta, transcript: transcript, notes: notes)
    try store.save(notes: notes, id: meta.id)
    try store.save(meta: meta)

    // The app shows the note owner as "You"; the scorer wants their name.
    let name = { (id: String) in id == MeetingSpeaker.you ? input.owner : meta.displayName(id, notes: notes) }
    let segments = transcript.map { segment in
        Output.Segment(start: segment.start ?? 0, end: segment.end ?? 0, speaker_name: name(segment.speaker),
                       speaker_id: segment.speaker, text: segment.text)
    }
    var participants: [String] = []
    for segment in segments where !participants.contains(segment.speaker_name) { participants.append(segment.speaker_name) }
    let calls = usageStore.records(forSession: input.id).map { r in
        Output.Call(stage: r.stage, model: r.model, text_in: r.textIn, audio_in: r.audioIn, image_in: r.imageIn,
                    cached_in: r.cachedIn, text_out: r.textOut, audio_out: r.audioOut, thought_out: r.thoughtOut,
                    estimated: r.isEstimated, cost_usd: PriceBook.cost(model: r.model, usage: r.usage, at: pricedAt) ?? r.costUSD)
    }
    let total = { (calls: [Output.Call]) -> Double? in
        calls.allSatisfy { $0.cost_usd != nil } ? calls.compactMap(\.cost_usd).reduce(0, +) : nil
    }
    let notesCost = total(calls.filter { $0.stage == UsageStage.meetingSummary.rawValue })
    let transcribeCost = earlierTranscripts == nil ? total(calls.filter { $0.stage != UsageStage.meetingSummary.rawValue }) : nil
    let cost = transcribeCost.flatMap { t in notesCost.map { t + $0 } }
    let result = Output(id: input.id, segments: segments, participants: participants,
                        notes: try store.markdown(id: meta.id, parts: .notes), seconds: seconds,
                        usage: calls, duration_seconds: meta.durationSeconds,
                        transcribe_cost_usd: transcribeCost, notes_cost_usd: notesCost, cost_usd: cost,
                        cost_usd_per_hour: meta.durationSeconds > 0 ? cost.map { $0 * 3600 / meta.durationSeconds } : nil)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(result).write(to: out.appendingPathComponent("\(input.id).json"))
    print("\(input.id): \(participants.joined(separator: ", "))")
}

func earlierTranscript(_ id: String, in folder: URL) throws -> [TranscriptSegment] {
    struct Earlier: Decodable { var segments: [Output.Segment] }
    let earlier = try JSONDecoder().decode(Earlier.self, from: Data(contentsOf: folder.appendingPathComponent("\(id).json")))
    return earlier.segments.map { TranscriptSegment(speaker: $0.speaker_id, text: $0.text, chunkIndex: 0, start: $0.start, end: $0.end) }
}
