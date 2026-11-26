import Foundation
import VoiceIQCore
import VoiceIQInference
import VoiceIQSpeech

// Usage: GEMINI_API_KEY=… swift run -c release MeetingsEval DATA_DIR OUT_DIR [meeting-id …]
//
// For each meeting prepare.py wrote, does what MeetingEngine does after a
// recording stops: transcribe (Gemini + the on-device speaker model), match
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

struct Output: Codable {
    struct Segment: Codable { var start: Double; var end: Double; var speaker_name: String; var speaker_id: String; var text: String }
    var id: String
    var segments: [Segment]
    var participants: [String]
    var notes: String
    var seconds: [String: Double]
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
guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else { fail("GEMINI_API_KEY is not set") }
let data = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let only = Set(args.dropFirst(3))
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let config = GeminiConfig()
let client = GeminiClient(apiKey: { key })
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
    diarizeFarSide = { audio in
        try await LocalSpeechInference.transcribeMeeting(
            LocalMeetingRequest(speechDirectory: nil, diarizerDirectory: diarizer, audio: audio)).segments
    }
}
let transcriber = MeetingTranscriber(client: client, models: .init(transcribe: config.transcribeModel),
                                     endpoint: config.endpoint, diarizeFarSide: diarizeFarSide)
let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("meetings-eval-\(UUID().uuidString)"))

let meetings = try FileManager.default.contentsOfDirectory(atPath: data.path).sorted()
    .filter { !$0.hasPrefix(".") && (only.isEmpty || only.contains($0)) }
var failures = 0
for name in meetings {
    let source = data.appendingPathComponent(name)
    guard let inputData = try? Data(contentsOf: source.appendingPathComponent("input.json")) else { continue }
    let input = try JSONDecoder().decode(Input.self, from: inputData)
    do { try await evaluate(input, source: source) } catch {
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
    meta.durationSeconds = try TrackAudio(url: folder.appendingPathComponent("system.caf")).duration
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
    }
    seconds["transcribe"] = Date().timeIntervalSince(clock)
    meta.screenNames = ScreenSpeakerNames.match(samples: samples, transcript: transcript)
    try store.save(transcript: transcript, id: meta.id)

    print("\(input.id): notes")
    clock = Date()
    let write = { (meta: MeetingMeta) in
        try await client.meetingNotes(prompt: MeetingNotesPrompt.build(transcript: transcript, context: .init(
            startedAt: meta.startedAt, durationSeconds: meta.durationSeconds, app: input.app, names: [:],
            screenNames: meta.screenNames, ownerName: input.owner, calendarEvent: meta.calendarEvent)),
            model: config.writingModel, endpoint: config.endpoint, deadline: 300)
    }
    // As MeetingEngine.writeNotes does: a voice named by elimination gets the notes written again.
    var notes = try await write(meta)
    var named = meta
    named.screenNames = ScreenSpeakerNames.byElimination(meta: meta, transcript: transcript, notes: notes)
    if named.screenNames != meta.screenNames { notes = (try? await write(named)) ?? notes }
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
    let result = Output(id: input.id, segments: segments, participants: participants,
                        notes: try store.markdown(id: meta.id, parts: .notes), seconds: seconds)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(result).write(to: out.appendingPathComponent("\(input.id).json"))
    print("\(input.id): \(participants.joined(separator: ", "))")
}

func earlierTranscript(_ id: String, in folder: URL) throws -> [TranscriptSegment] {
    let earlier = try JSONDecoder().decode(Output.self, from: Data(contentsOf: folder.appendingPathComponent("\(id).json")))
    return earlier.segments.map { TranscriptSegment(speaker: $0.speaker_id, text: $0.text, chunkIndex: 0, start: $0.start, end: $0.end) }
}
