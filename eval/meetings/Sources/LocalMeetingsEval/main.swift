import AVFoundation
import FluidAudio
import Foundation
@testable import VoiceIQCore
@testable import VoiceIQInference
import VoiceIQSpeech

// Usage: swift run -c release -Xswiftc -enable-testing LocalMeetingsEval DATA_DIR OUT_DIR [meeting-id …]
//
// Transcribes each meeting prepare.py wrote fully on device, two ways, and
// writes OUT_DIR/<pipeline>-<model>/<id>.json for score.py:
//
//   voiceiq                 what the app does with Meetings set to On device
//                           (`LocalMeetingTranscriber`): each track decoded
//                           whole, the far side split by the speaker model.
//   hex                     Hex's offline pass (HexStyle.swift) with the same
//                           speech model: pause-cut chunks, a speech detector
//                           before the model, echoing microphone lines
//                           dropped, two speakers (the owner and "Them").
//   hex-speakers            the same words, the far side split by VoiceiQ's
//                           speaker model and joined into turns as the app does.
//   hex-speakers-noecho     as hex-speakers, with no microphone line dropped.
//
// The hex run also writes OUT_DIR/far-speakers/<id>.json, the speaker model's
// stretches on the far side, which hex_upstream_speakers.py reads.
//
// EVAL_MODEL=pro (default) or mini picks Fluid Speech Pro or Mini. EVAL_MODEL=unified
// runs the model Hex ships, Parakeet Unified English 0.6B, through FluidAudio's
// Core ML build of it. The app has no such model, so `voiceiq-unified` is the
// app's steps written out here with only the speech model swapped.
// EVAL_PIPELINES=voiceiq,hex (default both) limits what runs.
// EVAL_ECHO_REPLAY=REPORT checks the echo port against Hex itself instead of
// transcribing: REPORT is what Hex's `hex meeting echo DIR --transcribe`
// printed for the one meeting named, with each line's end time added after
// its start time. Hex's lines go through the port's echo rules, and the port's
// keep-or-drop and signal for every microphone line are counted against Hex's.
// Built with -enable-testing because it calls the app's internal steps.

struct Input: Decodable {
    var id: String
    var app: String
    var owner: String
}

struct Output: Encodable {
    struct Segment: Encodable { var start: Double; var end: Double; var speaker_name: String; var speaker_id: String; var text: String }
    var id: String
    var segments: [Segment]
    var participants: [String]
    var notes = ""
    var seconds: [String: Double]
    var duration_seconds: Double
    /// Counts that explain the result: chunks, chunks the speech detector skipped, lines dropped as echo.
    var details: [String: Double]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@MainActor
func download(_ store: LocalModelStore) async {
    store.download()
    while true {
        switch store.state {
        case .ready: return
        case .failed(let reason): fail("\(store.displayName) download failed: \(reason)")
        case .unsupported: fail("\(store.displayName) is unsupported on this Mac")
        default: try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// The model's folder, held until `release`. The app's own run lets go of its
/// session a moment after it returns, so this waits for it.
@MainActor
func session(_ store: LocalModelStore, id: UUID) async -> URL {
    for _ in 0..<120 {
        if let url = store.acquireSession(id: id, cancel: {}) { return url }
        try? await Task.sleep(for: .milliseconds(500))
    }
    fail("\(store.displayName) stayed busy")
}

func samples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.sampleRate == Double(Hex.rate), file.processingFormat.channelCount == 1 else {
        fail("\(url.lastPathComponent) is not 16 kHz mono")
    }
    guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// 16 kHz mono samples to words, with times in seconds from the first sample.
typealias Decode = @Sendable ([Float]) async throws -> [LocalMeetingResult.Word]

/// The models take a second of audio or more.
func padded(_ samples: [Float]) -> [Float] {
    samples.count < Hex.rate ? samples + [Float](repeating: 0, count: Hex.rate - samples.count) : samples
}

/// Fluid Speech Pro or Mini, loaded as `LocalMeetingJob` loads it, with a new decoder state for each call.
func fluidDecode(_ folder: URL) async throws -> (Decode, AsrManager) {
    let asr = AsrManager(config: .default, models: try AsrModels.loadLocal(from: folder, version: .v3))
    let layers = await asr.decoderLayerCount
    return ({ samples in
        var decoder = TdtDecoderState.make(decoderLayers: layers)
        return LocalMeetingJob.words(try await asr.transcribe(padded(samples), decoderState: &decoder).tokenTimings ?? [])
    }, asr)
}

/// One track through Hex's chunker, its speech detector gate and the speech model.
func hexTrack(_ audio: [Float], microphone: Bool, decode: Decode, vad: VadManager,
              details: inout [String: Double]) async throws -> HexTrackTranscript {
    var chunker = HexChunker(microphone: microphone)
    var transcript = HexTrackTranscript(microphone: microphone)
    // Hex's detector settings: speech at a probability of 0.4, 160 ms or longer.
    let detector = VadSegmentationConfig(minSpeechDuration: 0.16)
    let name = microphone ? "mic" : "system"
    func take(_ chunk: HexChunk) async throws {
        details["\(name)_chunks", default: 0] += 1
        if chunk.overlap > 0 { details["\(name)_hard_cuts", default: 0] += 1 }
        guard !TrackLevel.silent(chunk.samples), try await !vad.segmentSpeech(chunk.samples, config: detector).isEmpty else {
            details["\(name)_chunks_without_speech", default: 0] += 1
            return transcript.accept(chunk, words: [])
        }
        let words = try await decode(chunk.samples).map {
            HexWord(startMs: Int(($0.start * 1_000).rounded()), endMs: Int(($0.end * 1_000).rounded()), text: $0.text)
        }
        transcript.accept(chunk, words: words)
    }
    // A second at a time, as Hex reads a recorded track.
    for start in stride(from: 0, to: audio.count, by: Hex.rate) {
        for chunk in chunker.push(audio[start..<min(audio.count, start + Hex.rate)]) { try await take(chunk) }
    }
    if let chunk = chunker.finish() { try await take(chunk) }
    transcript.finish()
    return transcript
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: LocalMeetingsEval DATA_DIR OUT_DIR [meeting-id …]") }
let data = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let only = Set(args.dropFirst(3))
let environment = ProcessInfo.processInfo.environment
let label = environment["EVAL_MODEL"] ?? "pro"
guard ["pro", "mini", "unified"].contains(label) else { fail("EVAL_MODEL is pro, mini or unified") }
/// The app's model for the speaker-model session and settings; unused for words when `unified` is set.
let model: LocalSpeechModel = label == "mini" ? .parakeet : .fluidSpeechPro
let unified: UnifiedAsrManager? = label == "unified" ? UnifiedAsrManager() : nil
try await unified?.loadModels()
let pipelines = Set((environment["EVAL_PIPELINES"] ?? "voiceiq,hex").split(separator: ",").map(String.init))

SettingsStore().setMeetingSource(.onDevice)
SettingsStore().setLocalSpeechModel(model)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("local-meetings-eval-\(UUID().uuidString)")
UsageMeter.store = try UsageStore(databaseURL: scratch.appendingPathExtension("sqlite"))
let store = MeetingStore(root: scratch)
await download(LocalModelStore.store(for: model))
await download(LocalModelStore.speakerDiarizer)

func write(_ pipeline: String, _ input: Input, _ segments: [Output.Segment], seconds: [String: Double],
           duration: Double, details: [String: Double]) throws {
    let folder = out.appendingPathComponent("\(pipeline)-\(label)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var participants: [String] = []
    for segment in segments where !participants.contains(segment.speaker_name) { participants.append(segment.speaker_name) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Output(id: input.id, segments: segments, participants: participants, seconds: seconds,
                              duration_seconds: duration, details: details))
        .write(to: folder.appendingPathComponent("\(input.id).json"))
    print("\(input.id): \(pipeline)-\(label) \(participants.count) speakers, \(segments.count) turns, \(seconds)")
}

/// As the meeting screen names them: the owner by name, everyone else "Speaker N".
func named(_ turns: [TranscriptSegment], owner: String) -> [Output.Segment] {
    turns.map { turn in
        Output.Segment(start: turn.start ?? 0, end: turn.end ?? 0,
                       speaker_name: turn.speaker == MeetingSpeaker.you ? owner : MeetingSpeaker.defaultName(turn.speaker),
                       speaker_id: turn.speaker, text: turn.text)
    }
}

@MainActor
func evaluate(_ input: Input, source: URL) async throws {
    let meta = MeetingMeta(id: MeetingID(), startedAt: Date(), source: .app(bundleID: input.app, name: input.app))
    let folder = try store.create(meta: meta)
    for file in ["mic.caf", "system.caf"] {
        try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: folder.appendingPathComponent(file))
    }
    let call = try MeetingTranscriber.callAudio(folder: folder)
    var facts: [String: Double] = ["is_online": call.isOnline ? 1 : 0, "mic_is_echo_free": call.micIsEchoFree ? 1 : 0,
                                   "residual_echo_db": call.residualEcho]

    if pipelines.contains("voiceiq"), unified != nil, !(call.isOnline && call.micIsEchoFree) {
        print("\(input.id): voiceiq-unified skipped, the app would mix the tracks and only its per-track path is written here")
    } else if pipelines.contains("voiceiq"), let unified {
        // `LocalMeetingTranscriber.transcribe` for a call with an echo-free mic, with the speech model swapped.
        let clock = Date()
        let id = UUID()
        let diarizerFolder = await session(LocalModelStore.speakerDiarizer, id: id)
        defer { LocalModelStore.speakerDiarizer.releaseSession(id: id) }
        let micURL = folder.appendingPathComponent("eval-mic.caf"), farURL = folder.appendingPathComponent("eval-far.caf")
        try LocalMeetingTranscriber.writeMix(duration: call.mic.duration, samples: call.mic.samples, to: micURL)
        try LocalMeetingTranscriber.writeMix(duration: call.system.duration, samples: call.system.samples, to: farURL)
        let owner = LocalMeetingJob.words(try await unified.transcribeWithTimings(try samples(micURL)).tokenTimings)
        let farWords = LocalMeetingJob.words(try await unified.transcribeWithTimings(try samples(farURL)).tokenTimings)
        let stretches = try await LocalSpeechInference.transcribeMeeting(
            LocalMeetingRequest(speechDirectory: nil, diarizerDirectory: diarizerFolder, audio: farURL)).segments
        let words = LocalMeetingTranscriber.renumber(
            LocalMeetingTranscriber.byTrack(owner: owner, far: LocalMeetingResult(words: farWords, segments: stretches)))
        let turns = SpeakerLinker.overlappingTurns(words).map {
            TranscriptSegment(speaker: $0.speaker, text: $0.text, chunkIndex: 0, start: $0.start, end: $0.end)
        }
        try write("voiceiq", input, named(turns, owner: input.owner), seconds: ["transcribe": Date().timeIntervalSince(clock)],
                  duration: call.duration, details: facts)
    } else if pipelines.contains("voiceiq") {
        let clock = Date()
        guard let transcriber = try await LocalMeetingTranscriber.acquire(runner: { try await LocalSpeechInference.transcribeMeeting($0) }) else {
            fail("on-device meetings are not ready")
        }
        let turns = try await transcriber.transcribe(folder: folder)
        try write("voiceiq", input, named(turns, owner: input.owner), seconds: ["transcribe": Date().timeIntervalSince(clock)],
                  duration: call.duration, details: facts)
    }
    guard pipelines.contains("hex") else { return }

    let id = UUID()
    let speechFolder = await session(LocalModelStore.store(for: model), id: id)
    let diarizerFolder = await session(LocalModelStore.speakerDiarizer, id: id)
    defer {
        LocalModelStore.store(for: model).releaseSession(id: id)
        LocalModelStore.speakerDiarizer.releaseSession(id: id)
    }
    var seconds: [String: Double] = [:]
    var clock = Date()
    // Hex reads the tracks as recorded: the mic is not echo-cancelled first.
    let system = try samples(folder.appendingPathComponent("system.caf")), microphone = try samples(folder.appendingPathComponent("mic.caf"))
    var fluid: AsrManager?
    let decode: Decode
    if let unified {
        decode = { LocalMeetingJob.words(try await unified.transcribeWithTimings(padded($0)).tokenTimings) }
    } else {
        (decode, fluid) = try await fluidDecode(speechFolder)
    }
    let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.4))
    let far = try await hexTrack(system, microphone: false, decode: decode, vad: vad, details: &facts)
    let near = try await hexTrack(microphone, microphone: true, decode: decode, vad: vad, details: &facts)
    await fluid?.cleanup()
    seconds["words"] = Date().timeIntervalSince(clock)

    clock = Date()
    let envelope = EchoEnvelope(system: system, microphone: microphone)
    let entries = (far.entries + near.entries).sorted { $0.startMs < $1.startMs }
    let (kept, dropped) = HexEcho.suppress(entries) { envelope.assess($0, $1) }
    seconds["echo"] = Date().timeIntervalSince(clock)
    facts["echo_utterances_dropped"] = Double(dropped)
    facts["mic_lines"] = Double(entries.filter(\.microphone).count)
    facts["mic_lines_kept"] = Double(kept.filter(\.microphone).count)
    seconds["transcribe"] = seconds["words"]! + seconds["echo"]!
    try write("hex", input, kept.map { entry in
        Output.Segment(start: Double(entry.startMs) / 1_000, end: Double(entry.endMs) / 1_000,
                       speaker_name: entry.microphone ? input.owner : "Them", speaker_id: entry.microphone ? "you" : "them", text: entry.text)
    }, seconds: seconds, duration: call.duration, details: facts)

    clock = Date()
    let stretches = try await LocalSpeechInference.transcribeMeeting(
        LocalMeetingRequest(speechDirectory: nil, diarizerDirectory: diarizerFolder, audio: folder.appendingPathComponent("system.caf"))).segments
    seconds["speakers"] = Date().timeIntervalSince(clock)
    seconds["transcribe"] = seconds["transcribe"]! + seconds["speakers"]!
    // Who spoke when on the far side, for hex_upstream_speakers.py.
    let stretchFolder = out.appendingPathComponent("far-speakers")
    try FileManager.default.createDirectory(at: stretchFolder, withIntermediateDirectories: true)
    try JSONEncoder().encode(stretches).write(to: stretchFolder.appendingPathComponent("\(input.id).json"))
    let farWords = far.entries.flatMap(\.words).map {
        LocalMeetingResult.Word(text: $0.text, start: Double($0.startMs) / 1_000, end: Double($0.endMs) / 1_000)
    }
    for (pipeline, lines) in [("hex-speakers", kept), ("hex-speakers-noecho", entries)] {
        let ownerWords = lines.filter(\.microphone).flatMap(\.words).map {
            LocalMeetingResult.Word(text: $0.text, start: Double($0.startMs) / 1_000, end: Double($0.endMs) / 1_000)
        }
        // The app's own join of a call decoded one track at a time.
        let words = LocalMeetingTranscriber.renumber(
            LocalMeetingTranscriber.byTrack(owner: ownerWords, far: LocalMeetingResult(words: farWords, segments: stretches)))
        let turns = SpeakerLinker.overlappingTurns(words).map {
            TranscriptSegment(speaker: $0.speaker, text: $0.text, chunkIndex: 0, start: $0.start, end: $0.end)
        }
        try write(pipeline, input, named(turns, owner: input.owner), seconds: seconds, duration: call.duration, details: facts)
    }
}

/// Hex's own lines and verdicts for one meeting, through the port's echo rules.
func replayEcho(_ report: URL, source: URL) throws {
    struct Line { var entry: HexEntry; var kept: Bool; var signal: String }
    var lines: [Line] = []
    for text in try String(contentsOf: report, encoding: .utf8).split(separator: "\n") {
        let fields = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 4, fields[0] == "KEEP" || fields[0] == "drop", let start = Int(fields[1]), let end = Int(fields[2]) else { continue }
        let microphone = fields[3] == "You"
        let words = fields.dropFirst(microphone ? 5 : 4).map { HexWord(startMs: start, endMs: end, text: $0) }
        lines.append(Line(entry: HexEntry(microphone: microphone, startMs: start, endMs: end, words: words),
                          kept: fields[0] == "KEEP", signal: microphone && fields.count > 4 ? fields[4] : ""))
    }
    let envelope = EchoEnvelope(system: try samples(source.appendingPathComponent("system.caf")),
                                microphone: try samples(source.appendingPathComponent("mic.caf")))
    let entries = lines.map(\.entry)
    let (kept, _) = HexEcho.suppress(entries) { envelope.assess($0, $1) }
    var sameSignal = 0, sameVerdict = 0, microphoneLines = 0
    var differences: [String] = []
    for line in lines where line.entry.microphone {
        microphoneLines += 1
        let signal: String
        switch envelope.assess(line.entry.startMs, line.entry.endMs) {
        case .bleed?: signal = "bleed"
        case .local?: signal = "local"
        case nil: signal = "?"
        }
        let verdict = kept.contains(line.entry)
        if signal == line.signal { sameSignal += 1 }
        if verdict == line.kept { sameVerdict += 1 } else if differences.count < 10 {
            differences.append("  Hex \(line.kept ? "KEEP" : "drop") \(line.signal), port \(verdict ? "KEEP" : "drop") \(signal): \(line.entry.startMs) \(line.entry.text.prefix(60))")
        }
    }
    print("echo replay: \(microphoneLines) microphone lines, same signal on \(sameSignal), same keep-or-drop on \(sameVerdict)")
    differences.forEach { print($0) }
}

let meetings = try FileManager.default.contentsOfDirectory(atPath: data.path).sorted()
    .filter { !$0.hasPrefix(".") && (only.isEmpty || only.contains($0)) }
var failures = 0
for name in meetings {
    let source = data.appendingPathComponent(name)
    guard let inputData = try? Data(contentsOf: source.appendingPathComponent("input.json")) else { continue }
    let input = try JSONDecoder().decode(Input.self, from: inputData)
    if let report = environment["EVAL_ECHO_REPLAY"] {
        try replayEcho(URL(fileURLWithPath: report), source: source)
        continue
    }
    do { try await evaluate(input, source: source) } catch {
        failures += 1
        print("\(input.id): FAILED \(error)")
    }
}
exit(failures == 0 ? 0 : 2)
