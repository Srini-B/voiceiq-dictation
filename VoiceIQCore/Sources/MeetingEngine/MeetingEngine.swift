import Combine
import Foundation
import VoiceIQSpeech

@MainActor public final class MeetingEngine: ObservableObject {
    /// The recorder: offering, recording, or free. Notes are made apart from
    /// it, so a stopped meeting never holds the recorder while it is written up.
    @Published public private(set) var phase: MeetingPhase = .idle
    /// Meetings whose transcript and notes are being made in the background,
    /// with the step each is on (`.transcribing` or `.summarizing`).
    @Published public private(set) var processing: [MeetingID: MeetingStatus] = [:]
    public var onNotice: ((String) -> Void)?
    /// The notes for a stopped recording are saved. The caller shows the same
    /// success mark a finished dictation gets.
    public var onNotesReady: (() -> Void)?
    /// A call was noticed while idle. The caller decides whether to record; nothing starts on its own.
    public var onCallDetected: ((CallSource) -> Void)?
    /// The noticed call went away before anyone accepted it.
    public var onCallEnded: (() -> Void)?
    public var autoDetect: Bool = false { didSet { autoDetect ? detector.start() : detector.stop() } }

    public let store: MeetingStore
    private let client: GeminiClient
    private let config: () -> GeminiConfig
    /// Whether a Gemini key is stored; read when a meeting is processed.
    private let hasKey: @Sendable () -> Bool
    /// On-device transcription, used when `LocalMeetingTranscriber` is ready.
    private let localMeeting: LocalMeetingRunner?
    /// The on-device writer, for notes of a meeting kept on device.
    private let localWriter: LocalWriteRunner?
    private lazy var detector = CallDetector()
    private var mic: MicTap?, system: SystemAudioTap?
    private var currentFolder: URL?, currentMeta: MeetingMeta?
    /// Whether to read speaker name tags off the screen while recording.
    #if os(macOS)
    private var screenNames: ScreenNameSampler?
    private var following: Task<Void, Never>?

    /// A call app can start a helper mid-call (Chrome's audio service after a
    /// crash) or move to another mic; every few seconds the recording follows.
    private static func follow(_ source: CallSource, mic: MicTap, system: SystemAudioTap) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let call = CallDetector.processes(for: source) else { continue }
                system.follow(processes: call.objects)
                if let device = call.inputDevice { mic.use(device: device) }
            }
        }
    }
    #endif
    /// The call the detector currently sees, whether or not it was accepted.
    public private(set) var detectedSource: CallSource?

    public init(client: GeminiClient, store: MeetingStore = MeetingStore(), config: @escaping () -> GeminiConfig,
                hasKey: @escaping @Sendable () -> Bool = { KeychainStore.loadAPIKey() != nil },
                localMeeting: LocalMeetingRunner? = nil, localWriter: LocalWriteRunner? = nil) {
        self.client = client; self.store = store; self.config = config
        self.hasKey = hasKey; self.localMeeting = localMeeting; self.localWriter = localWriter
        detector.onChange = { [weak self] source in self?.detected(source) }
        failInterruptedRecordings()
    }

    /// A meeting still marked `.recording` at launch belonged to a process that
    /// died; nothing will ever stop it, so the list would show "Recording"
    /// forever.
    private func failInterruptedRecordings() {
        for var meta in store.list() where meta.status == .recording {
            meta.status = .failed("interrupted")
            meta.endedAt = meta.endedAt ?? meta.startedAt.addingTimeInterval(meta.durationSeconds)
            try? store.save(meta: meta)
            #if os(macOS)
            // The tracks were written until the process died; a Retry needs the browser's speakers too.
            if let folder = store.folder(for: meta.id) {
                var written = meta
                written.endedAt = ["mic.caf", "system.caf"].compactMap {
                    try? folder.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                }.max() ?? meta.endedAt
                BrowserSpeakers.save(meta: written, folder: folder)
            }
            #endif
        }
    }

    public var isRecording: Bool { if case .recording = phase { return true }; return false }

    /// Option-M: start when nothing is recording, stop when something is.
    public func toggleRecording() {
        switch phase {
        case .recording: stopRecording()
        case .idle, .callDetected, .failed: startRecording(source: detectedSource)
        }
    }

    /// The pill's Accept button.
    public func acceptDetectedCall() {
        guard case let .callDetected(source) = phase else { return }
        startRecording(source: source)
    }

    /// The pill's dismiss. The same call is not offered again; the next one is.
    public func dismissDetectedCall() {
        guard case .callDetected = phase else { return }
        phase = .idle
    }

    public func startRecording(source: CallSource? = nil) {
        if case .recording = phase { return }
        let id = MeetingID(), now = Date(), meta = MeetingMeta(id: id, startedAt: now, source: source)
        do {
            let folder = try store.create(meta: meta)
            #if os(macOS)
            let call = source.flatMap(CallDetector.processes(for:))
            let mic = MicTap(url: folder.appendingPathComponent("mic.caf"), device: call?.inputDevice)
            let system = SystemAudioTap(url: folder.appendingPathComponent("system.caf"), processes: call?.objects ?? [])
            #else
            let mic = MicTap(url: folder.appendingPathComponent("mic.caf"))
            let system = SystemAudioTap(url: folder.appendingPathComponent("system.caf"))
            #endif
            // Mic first. MEASURED 2026-09-26 (macOS 26.5, built-in mic): with the
            // tap's aggregate device already running, `AudioDeviceStart` on the
            // mic blocked the main thread for 9 s to forever while coreaudiod
            // retried "StartIOThread ... Error: 0x3C" every 14 s (4 of 7 runs).
            // Mic-then-tap started in 40 ms in every run and the tap still
            // delivered system audio.
            try mic.start()
            do { try system.start() } catch { _ = mic.stop(); throw error }
            self.mic = mic; self.system = system
            currentFolder = folder; currentMeta = meta
            #if os(macOS)
            screenNames = ScreenNameSampler(source: source); screenNames?.start()
            if let source, call != nil { following = Self.follow(source, mic: mic, system: system) }
            #endif
            phase = .recording(id, since: now)
        } catch { fail(id, error) }
    }

    public func stopRecording() {
        guard case let .recording(id, _) = phase, let folder = currentFolder, var meta = currentMeta else { return }
        #if os(macOS)
        following?.cancel(); following = nil
        #endif
        let micDuration = mic?.stop() ?? 0, systemDuration = system?.stop() ?? 0
        mic = nil; system = nil; currentFolder = nil; currentMeta = nil
        #if os(macOS)
        if let samples = screenNames?.stop() { try? store.save(screenSamples: samples, id: id) }
        screenNames = nil
        #endif
        meta.endedAt = Date(); meta.durationSeconds = max(micDuration, systemDuration)
        #if os(macOS)
        BrowserSpeakers.save(meta: meta, folder: folder)
        #endif
        try? mark(&meta, .transcribing)
        phase = .idle
        Task { await UsageMeter.$scope.withValue(UsageScope(activity: .meeting, sessionID: id.uuid.uuidString)) {
            await process(id: id, folder: folder, meta: meta)
        } }
    }

    /// Transcribes again from the audio and writes new notes. A retry after a
    /// failure reuses the finished windows; `fresh` (Redo transcript) hears
    /// the whole meeting again.
    public func retry(id: MeetingID, fresh: Bool = false) {
        guard !isBusy(id), let folder = store.folder(for: id), let meta = store.list().first(where: { $0.id == id }) else { return }
        if fresh { Self.dropTranscriptCaches(folder) }
        processing[id] = .transcribing
        Task { await UsageMeter.$scope.withValue(UsageScope(activity: .meeting, sessionID: id.uuid.uuidString)) {
            await process(id: id, folder: folder, meta: meta)
        } }
    }

    /// New notes from the saved transcript, using the speaker names typed since.
    /// With meetings on device and writing Off, nothing happens and the
    /// transcript stays on the device. With On device and its model missing,
    /// Gemini writes them, as it would after a failed on-device pass.
    public func regenerateNotes(id: MeetingID) {
        guard !isBusy(id), var meta = store.list().first(where: { $0.id == id }),
              let transcript = try? store.loadTranscript(id: id), !transcript.isEmpty else { return }
        let settings = SettingsStore()
        if settings.meetingSource == .onDevice, settings.cleanupSource == .none {
            Log.meeting.notice("notes not regenerated: writing is off for on-device meetings")
            return
        }
        let writesLocally = settings.meetingSource == .onDevice && settings.cleanupSource == .onDevice
            && localWriter != nil && LocalWriter.isReady
        processing[id] = .summarizing
        Task { await UsageMeter.$scope.withValue(UsageScope(activity: .meeting, sessionID: id.uuid.uuidString)) {
            do {
                try mark(&meta, .summarizing)
                let notes: MeetingNotes
                if writesLocally, let localWriter {
                    notes = try await localNotes(transcript: transcript, meta: meta, runner: localWriter)
                } else {
                    guard hasKey() else { throw MeetingFailure.noKey }
                    notes = try await writeNotes(transcript: transcript, meta: meta)
                }
                try finish(id: id, meta: &meta, transcript: transcript, notes: notes)
            } catch { saveFailure(id: id, meta: &meta, error: error) }
        } }
    }

    /// Recording, or already being written up.
    public func isBusy(_ id: MeetingID) -> Bool {
        if case .recording(id, _) = phase { return true }
        return processing[id] != nil
    }

    /// Saves the step and publishes it, so the meeting shows what it is doing.
    private func mark(_ meta: inout MeetingMeta, _ status: MeetingStatus) throws {
        meta.status = status
        processing[meta.id] = status
        try store.save(meta: meta)
    }

    /// The words cached beside the audio by `MeetingTranscriber` (the
    /// `transcribe-*` windows) and `LocalMeetingTranscriber` (`local-words-*`,
    /// and `speakers-*` from builds before 0.6).
    static func dropTranscriptCaches(_ folder: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("transcribe-") || name.hasPrefix("local-words-") || name.hasPrefix("speakers-") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func process(id: MeetingID, folder: URL, meta original: MeetingMeta) async {
        var meta = original
        do {
            let cfg = config()
            let mic = try AudioMixer.speechStats(url: folder.appendingPathComponent("mic.caf"))
            let system = try AudioMixer.speechStats(url: folder.appendingPathComponent("system.caf"))
            guard mic.hasSpeech || system.hasSpeech else {
                Log.meeting.info("no speech in recording (mic \(String(format: "%.1f", mic.activeSeconds), privacy: .public)s, system \(String(format: "%.1f", system.activeSeconds), privacy: .public)s active) — skipping transcription")
                try finish(id: id, meta: &meta, transcript: [], notes: Self.emptyNotes(reason: "No speech was recorded."))
                return
            }
            try mark(&meta, .transcribing)
            let (transcript, onDevice) = try await transcribe(folder: folder, config: cfg)
            let words = transcript.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            guard words >= Self.minimumSummarizableWords else {
                Log.meeting.info("transcript too short to summarize (\(words, privacy: .public) words)")
                try finish(id: id, meta: &meta, transcript: transcript, notes: Self.emptyNotes(reason: "Not enough speech to summarize."))
                return
            }
            try store.save(transcript: transcript, id: id)
            if let samples = store.loadScreenSamples(id: id) {
                meta.screenNames = ScreenSpeakerNames.match(samples: samples, transcript: transcript)
                Log.meeting.info("screen names: \(meta.screenNames?.speakers.count ?? 0, privacy: .public) speakers named, \(meta.screenNames?.seen.count ?? 0, privacy: .public) names seen")
            }
            meta.screenNames = BrowserSpeakers.name(meta.screenNames, transcript: transcript, folder: folder)
            let fromPage = meta.screenNames?.speakers.values.filter { $0.talkSeconds != nil }.count ?? 0
            Log.meeting.info("browser names: \(fromPage, privacy: .public) speakers named")
            try mark(&meta, .summarizing)
            if onDevice, let notes = await notesKeptOnDevice(transcript: transcript, meta: meta) {
                // Nothing leaves the device.
                try finish(id: id, meta: &meta, transcript: transcript, notes: notes)
                return
            }
            try Task.checkCancellation()
            let notes = try await writeNotes(transcript: transcript, meta: meta)
            try finish(id: id, meta: &meta, transcript: transcript, notes: notes)
        } catch { saveFailure(id: id, meta: &meta, error: error) }
    }

    /// On device when the user asked for it and the models are downloaded;
    /// otherwise, or if the on-device pass fails and a key is stored, Gemini.
    /// This mirrors dictation. The flag says whether the words never left the device.
    private func transcribe(folder: URL, config cfg: GeminiConfig) async throws -> ([TranscriptSegment], Bool) {
        let cloud = MeetingTranscriber(client: client, models: .init(transcribe: cfg.transcribeModel), endpoint: cfg.endpoint)
        guard let local = try await acquireLocal() else {
            let settings = SettingsStore()
            guard !settings.localMeetingTranscriptionEnabled || settings.onDeviceFallsBackToGemini else {
                throw TranscriptionError.onDeviceFailed
            }
            guard hasKey() else { throw MeetingFailure.noKey }
            return (try await cloud.transcribe(folder: folder), false)
        }
        do {
            let transcript = try await local.transcribe(folder: folder)
            Log.meeting.info("transcribed on device: \(transcript.count, privacy: .public) turns")
            return (transcript, true)
        } catch {
            guard hasKey(), SettingsStore().onDeviceFallsBackToGemini, !(error is CancellationError) else { throw error }
            Log.meeting.error("on-device transcription failed, using Gemini: \(String(describing: error), privacy: .public)")
            return (try await cloud.transcribe(folder: folder), false)
        }
    }

    /// Nil when the meeting should go to Gemini: on device is off or not
    /// downloaded, or the models stayed busy, a key is stored and Writing
    /// rules and notes is Gemini. Otherwise the busy error is the failure.
    private func acquireLocal() async throws -> LocalMeetingTranscriber? {
        guard let runner = localMeeting else { return nil }
        do {
            return try await LocalMeetingTranscriber.acquire(runner: runner)
        } catch {
            guard hasKey(), SettingsStore().onDeviceFallsBackToGemini, !(error is CancellationError) else { throw error }
            Log.meeting.error("on-device models unavailable, using Gemini: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The recording stays; the meeting is marked failed with a reason the
    /// Meetings list shows, and Retry runs it again with the keys stored then.
    private func saveFailure(id: MeetingID, meta: inout MeetingMeta, error: Error) {
        let reason = MeetingFailure.reason(for: error)
        Log.meeting.error("meeting \(id.uuid.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        meta.status = .failed(reason); try? store.save(meta: meta)
        processing[id] = nil
        switch error as? MeetingFailure {
        case .noKey: onNotice?("\(MeetingFailure.noun) saved — add a Gemini key, then Retry in \(MeetingFailure.listName)")
        case nil: onNotice?("\(MeetingFailure.noun) transcript failed — see \(MeetingFailure.listName)")
        }
    }

    private func writeNotes(transcript: [TranscriptSegment], meta: MeetingMeta) async throws -> MeetingNotes {
        let cfg = config(), settings = SettingsStore(), dictionary = DictionaryStore()
        let prompt = MeetingNotesPrompt.build(transcript: transcript, context: .init(
            startedAt: meta.startedAt, durationSeconds: meta.durationSeconds,
            app: meta.source.map(Self.name), names: meta.speakerNames, screenNames: meta.screenNames,
            ownerName: settings.meetingOwnerName, vocabulary: dictionary.sanitizedVocabulary(),
            spellings: dictionary.spellings(), writingRules: settings.customWritingRules))
        let text = try await client.meetingNotesJSON(prompt: prompt, model: cfg.writingModel, endpoint: cfg.endpoint,
                                                     deadline: 300)
        return try MeetingNotesPrompt.parse(text)
    }

    /// The notes of a meeting transcribed on device, when they stay on it:
    /// written by the on-device writer when the user picked it, or the
    /// transcript-only stub when writing is off, or when no key is stored and
    /// Gemini would have to write them. Nil when Gemini writes them, which
    /// includes an on-device writer that is missing or fails.
    private func notesKeptOnDevice(transcript: [TranscriptSegment], meta: MeetingMeta) async -> MeetingNotes? {
        switch SettingsStore().cleanupSource {
        case .gemini:
            return hasKey() ? nil : Self.onDeviceNotes(meta: meta)
        case .none:
            return Self.onDeviceNotes(meta: meta)
        case .onDevice:
            if let localWriter, LocalWriter.isReady {
                do {
                    return try await localNotes(transcript: transcript, meta: meta, runner: localWriter)
                } catch {
                    Log.meeting.error("on-device notes failed: \(String(describing: error), privacy: .public)")
                }
            }
            return hasKey() ? nil : Self.onDeviceNotes(meta: meta)
        }
    }

    private func localNotes(transcript: [TranscriptSegment], meta: MeetingMeta, runner: @escaping LocalWriteRunner) async throws -> MeetingNotes {
        let settings = SettingsStore(), dictionary = DictionaryStore()
        let context = MeetingNotesPrompt.Context(
            startedAt: meta.startedAt, durationSeconds: meta.durationSeconds, app: meta.source.map(Self.name),
            names: meta.speakerNames, screenNames: meta.screenNames, ownerName: settings.meetingOwnerName,
            vocabulary: dictionary.sanitizedVocabulary(), spellings: dictionary.spellings(),
            writingRules: settings.customWritingRules)
        return try await LocalWriter.notes(system: MeetingNotesPrompt.onDeviceSystem,
                                           user: MeetingNotesPrompt.onDeviceUser(transcript: transcript, context: context),
                                           runner: runner)
    }

    /// Fewer words than this and the notes model has nothing to work with; it
    /// would write a summary saying so, in whatever language the fragment is.
    static let minimumSummarizableWords = 8

    /// The notes of a meeting transcribed on device when nothing wrote them:
    /// writing off, no Gemini key, or the on-device writer missing or
    /// failing. The transcript is the record; Regenerate notes writes real
    /// ones once a writer may.
    static func onDeviceNotes(meta: MeetingMeta) -> MeetingNotes {
        let title = meta.source.map { "\(name($0)) call" } ?? "Meeting"
        return MeetingNotes(title: title, summary: "Transcribed on device. No notes were written: choose Gemini with a key, or On device with its model downloaded, under Writing rules and notes, then Regenerate notes.",
                            decisions: [], actions: [], notes: [])
    }

    static func emptyNotes(reason: String) -> MeetingNotes {
        MeetingNotes(title: "No speech recorded", summary: reason, decisions: [], actions: [], notes: [])
    }

    private func finish(id: MeetingID, meta: inout MeetingMeta, transcript: [TranscriptSegment], notes: MeetingNotes) throws {
        try store.save(transcript: transcript, id: id)
        try store.save(notes: notes, id: id)
        meta.title = notes.title; meta.status = .done; meta.notesSpeakerNames = meta.speakerNames
        // Names typed while the notes were written stay, and show the notes as out of date.
        if let current = store.list().first(where: { $0.id == id }) { meta.speakerNames = current.speakerNames }
        try store.save(meta: meta)
        processing[id] = nil; onNotesReady?()
    }

    /// Detection only ever offers. A recording in progress is never stopped by
    /// the detector losing sight of the call (muting in Meet drops the mic
    /// capture it watches), and nothing starts until someone accepts. A
    /// different call seen while one is offered replaces the offer.
    private func detected(_ source: CallSource?) {
        detectedSource = source
        if let source {
            switch phase {
            case .idle, .callDetected: phase = .callDetected(source); onCallDetected?(source)
            case .recording, .failed: return
            }
        } else if case .callDetected = phase {
            phase = .idle
            onCallEnded?()
        }
    }
    private func fail(_ id: MeetingID, _ error: Error) {
        Log.meeting.error("meeting \(id.uuid.uuidString, privacy: .public) could not start: \(String(describing: error), privacy: .public)")
        try? store.delete(id: id)
        phase = .failed(id, String(describing: error)); onNotice?("Meeting recording failed")
    }
    public static func name(_ source: CallSource) -> String { switch source { case let .app(_, name): return name; case let .browser(_, host): return host } }
}

/// Why a meeting has no transcript or notes, in words the Meetings list can
/// show. The raw error goes to the log.
public enum MeetingFailure: Error, Equatable {
    /// No Gemini key is stored, and the on-device models are off or missing.
    case noKey

    static let fixHint = "The recording is saved. Press Retry after fixing this."
    /// Where keys live and what the list is called on each platform.
    #if os(macOS)
    static let keysPlace = "Settings → API Key"
    static let listName = "Meetings", noun = "Meeting"
    #else
    static let keysPlace = "API Key"
    static let listName = "Notes", noun = "Note"
    #endif

    static func reason(for error: Error) -> String {
        switch error {
        case MeetingFailure.noKey:
            return "Add your Gemini API key in \(keysPlace), or transcribe meetings on device and download its models, to transcribe meetings. The recording is saved; press Retry once one is ready."
        case let error as TranscriptionError:
            switch error {
            case .auth:
                return "Gemini rejected the API key. Check it in \(keysPlace). \(fixHint)"
            case .rateLimitedDaily:
                return "The daily Gemini quota is used up. \(fixHint)"
            case .rateLimitedTransient:
                return "Rate limited for too long. Try again in a few minutes. \(fixHint)"
            case .modelUnavailable(let model, _):
                return "Your key can't use \(model). \(fixHint)"
            case .offline:
                return "You were offline when the meeting was transcribed. \(fixHint)"
            case .timeout, .network:
                return "Couldn't reach Gemini. \(fixHint)"
            case .safetyBlocked:
                return "Gemini declined to transcribe this meeting. \(fixHint)"
            case .badRequest, .emptyTranscript, .onDeviceFailed:
                return "Transcription failed. \(fixHint)"
            }
        default:
            return "Transcription failed: \(error.localizedDescription). \(fixHint)"
        }
    }
}
