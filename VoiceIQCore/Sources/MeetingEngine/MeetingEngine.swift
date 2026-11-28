import Combine
import Foundation
import Network
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
    /// The on-device speaker model, which splits the far side's voices
    /// (`farSideDiarizer`). Gemini always transcribes.
    private let localMeeting: LocalMeetingRunner?
    private lazy var detector = CallDetector()
    private var mic: MicTap?, system: SystemAudioTap?
    private var currentFolder: URL?, currentMeta: MeetingMeta?
    /// Set while a recorded call has ended and the recording counts down to
    /// stopping; nil otherwise. The pill shows Stop now and Keep recording.
    @Published public private(set) var endingAt: Date?
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

    /// The mic track records silence while set; the far side keeps
    /// recording. Hex has the same switch (anomalyco/hex `6118eb82`).
    @Published public private(set) var micMuted = false

    public func setMicMuted(_ muted: Bool) {
        guard isRecording, let mic else { return }
        mic.muted = muted; micMuted = muted
        Log.meeting.info("meeting mic \(muted ? "muted" : "unmuted", privacy: .public)")
    }

    private var endWatch: Task<Void, Never>?
    /// Keep recording was chosen; asked again only after the call comes back and ends again.
    private var keepAfterCallEnd = false

    /// The call's app let go of all its sound this long ago,
    static let callGoneGrace: TimeInterval = 20
    /// and neither track has heard anyone for this long, so a quiet stretch
    /// in a call that is still going never asks.
    static let quietBeforeAsking: TimeInterval = 45
    static let endCountdown: TimeInterval = 30

    /// A recording started from a detected call stops on its own once the call
    /// is over, after a countdown the user can stop or cancel. The rules follow
    /// FluidVoice's (altic-dev/FluidVoice, `MeetingEndCountdown`); the code is ours.
    private func watchForCallEnd(_ source: CallSource, mic: MicTap, system: SystemAudioTap) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            var goneSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.endingAt == nil ? 5 : 1))
                guard let self, !Task.isCancelled else { return }
                let browser: Bool
                if case .browser = source { browser = true } else { browser = false }
                let live = await Task.detached {
                    CallDetector.processes(for: source)?.isLive(locked: CallDetector.screenLocked(), browser: browser) == true
                }.value
                // A stop during the query cancelled this watcher and cleared
                // the countdown; don't set it again.
                guard !Task.isCancelled else { return }
                let now = Date()
                if live {
                    goneSince = nil; keepAfterCallEnd = false
                    if endingAt != nil { endingAt = nil; Log.meeting.info("call came back — recording continues") }
                    continue
                }
                let gone = goneSince ?? now
                goneSince = gone
                let heard = max(mic.sound.lastSound, system.sound.lastSound)
                if endingAt == nil, !keepAfterCallEnd,
                   now.timeIntervalSince(gone) >= Self.callGoneGrace,
                   now.timeIntervalSince(heard) >= Self.quietBeforeAsking {
                    Log.meeting.info("call ended — stopping in \(Int(Self.endCountdown), privacy: .public)s unless kept")
                    endingAt = now.addingTimeInterval(Self.endCountdown)
                }
                if let end = endingAt, now >= end {
                    stopRecording()
                    return
                }
            }
        }
    }
    #endif

    /// The countdown's Keep recording.
    public func keepRecordingAfterCallEnd() {
        guard endingAt != nil else { return }
        endingAt = nil
        #if os(macOS)
        keepAfterCallEnd = true
        #endif
    }

    /// The call the detector currently sees, whether or not it was accepted.
    public private(set) var detectedSource: CallSource?

    public init(client: GeminiClient, store: MeetingStore = MeetingStore(), config: @escaping () -> GeminiConfig,
                hasKey: @escaping @Sendable () -> Bool = { KeychainStore.loadAPIKey() != nil },
                localMeeting: LocalMeetingRunner? = nil) {
        self.client = client; self.store = store; self.config = config
        self.hasKey = hasKey; self.localMeeting = localMeeting
        detector.onChange = { [weak self] source in self?.detected(source) }
        failInterruptedRecordings()
        watchForGemini()
    }

    private let network = NWPathMonitor()
    private var online = false

    /// Meetings that waited for Gemini go again at launch, when the network
    /// comes back, and when a key is saved. No on-device transcript stands
    /// in: on six AMI meetings it scored under the 90 the scorecard asks of
    /// on-device work (activities/2026-11-27-meetings-gemini-only.md).
    private func watchForGemini() {
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameOnline = path.status == .satisfied && !self.online
                self.online = path.status == .satisfied
                if cameOnline {
                    self.waitingDelay = .seconds(300)
                    self.transcribeWaiting()
                }
            }
        }
        network.start(queue: .main)
        NotificationCenter.default.addObserver(forName: .apiKeySaved, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.transcribeWaiting() }
        }
    }

    /// Sends again every meeting that failed only for want of Gemini, from
    /// the step that failed: the notes alone keep transcript edits and work
    /// for a synced meeting without audio; a transcript step (also Redo
    /// transcript and notes) transcribes the recording again.
    public func transcribeWaiting() {
        guard hasKey() else { return }
        for meta in store.list() where !isBusy(meta.id) {
            guard let step = meta.waitsForGemini else { continue }
            guard case .failed = meta.status else { continue }
            Log.meeting.info("meeting \(meta.id.uuid.uuidString, privacy: .public) waited for Gemini; sending it again")
            switch step {
            case .notes: regenerateNotes(id: meta.id)
            case .transcript: retry(id: meta.id)
            }
        }
    }

    /// Gemini can come back, or a quota reset, while the network stays up,
    /// which no path change reports. So a meeting waiting with a key and a
    /// network goes again after 5 minutes, then 10, 20, up to an hour apart.
    private var waitingRetry: Task<Void, Never>?
    private var waitingDelay: Duration = .seconds(300)

    private func scheduleWaitingRetry() {
        // Offline, the path change brings the meeting back; a timer would
        // only re-encode the audio and repeat the notice.
        guard waitingRetry == nil, online else { return }
        let delay = waitingDelay
        waitingDelay = min(waitingDelay * 2, .seconds(3600))
        waitingRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.waitingRetry = nil
            self.transcribeWaiting()
        }
    }

    /// A meeting still marked `.recording` at launch belonged to a process that
    /// died; nothing will ever stop it, so the list would show "Recording"
    /// forever.
    private func failInterruptedRecordings() {
        for var meta in store.list() {
            // A waiting meeting the app quit on while it went again waits on.
            let resumable = meta.waitsForGemini != nil && (meta.status == .transcribing || meta.status == .summarizing)
            guard meta.status == .recording || resumable else { continue }
            meta.status = .failed("interrupted")
            meta.endedAt = meta.endedAt ?? meta.startedAt.addingTimeInterval(meta.durationSeconds)
            try? store.save(meta: meta)
        }
    }

    public var isRecording: Bool { if case .recording = phase { return true }; return false }

    #if os(macOS)
    /// How loud the mic and the call are right now, 0 to 1; nil when not recording.
    public var liveLevels: (mic: Float, call: Float)? {
        guard let mic, let system else { return nil }
        return (mic.sound.level, system.sound.level)
    }
    #endif

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

    /// The pill's dismiss. The same call is not offered again. With `quiet`
    /// (the × button, not the offer timing out), neither is the next call from
    /// that app or site for 30 minutes, so a dropped and rejoined huddle stays
    /// quiet. FluidVoice holds back a dismissed app for 30 minutes too
    /// (altic-dev/FluidVoice, `MeetingAutoDetector`).
    public func dismissDetectedCall(quiet: Bool = true) {
        guard case let .callDetected(source) = phase else { return }
        if quiet { quietUntil[Self.offerKey(source)] = Date().addingTimeInterval(Self.dismissedQuiet) }
        phase = .idle
    }

    static let dismissedQuiet: TimeInterval = 30 * 60
    private var quietUntil: [String: Date] = [:]
    private static func offerKey(_ source: CallSource) -> String {
        switch source { case let .app(bundleID, _): return bundleID; case let .browser(_, host): return host }
    }

    /// `event`: the calendar meeting the user chose to record (Join and
    /// Record); otherwise the one under way now, when the calendar is on.
    /// `joining`: the call that meeting links to, whose window speaker names
    /// are read from once it opens.
    public func startRecording(source: CallSource? = nil, event: CalendarMeetings.Event? = nil,
                               joining: CalendarMeetings.Upcoming.Join? = nil) {
        if case .recording = phase { return }
        if SettingsStore().takeRetiredOnDeviceMeetingChoice() {
            onNotice?("\(MeetingFailure.listName) now go to Gemini: On device was removed. Discard this recording to keep it off Gemini.")
        }
        let id = MeetingID(), now = Date()
        var meta = MeetingMeta(id: id, startedAt: now, source: source)
        if SettingsStore().calendarForMeetings { meta.calendarEvent = event ?? CalendarMeetings.event(at: now, source: source) }
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
            screenNames = ScreenNameSampler(source: source, joining: joining?.bundleIDs); screenNames?.start()
            if let source {
                // A call that already ended before the offer was accepted has
                // no processes to follow, but its recording still stops.
                if call != nil { following = Self.follow(source, mic: mic, system: system) }
                keepAfterCallEnd = false
                endWatch = watchForCallEnd(source, mic: mic, system: system)
            }
            #endif
            phase = .recording(id, since: now)
        } catch { fail(id, error) }
    }

    public func stopRecording() {
        guard case let .recording(id, _) = phase, let folder = currentFolder, var meta = currentMeta else { return }
        #if os(macOS)
        following?.cancel(); following = nil
        endWatch?.cancel(); endWatch = nil
        micMuted = false
        #endif
        endingAt = nil
        let micDuration = mic?.stop() ?? 0, systemDuration = system?.stop() ?? 0
        mic = nil; system = nil; currentFolder = nil; currentMeta = nil
        #if os(macOS)
        if let samples = screenNames?.stop() { try? store.save(screenSamples: samples, id: id) }
        screenNames = nil
        #endif
        meta.endedAt = Date(); meta.durationSeconds = max(micDuration, systemDuration)
        try? mark(&meta, .transcribing)
        phase = .idle
        Task { await UsageMeter.$scope.withValue(UsageScope(activity: .meeting, sessionID: id.uuid.uuidString)) {
            await process(id: id, folder: folder, meta: meta)
        } }
    }

    /// Ends the recording and deletes it: no transcript, no notes, no audio
    /// kept. Only for an explicit, confirmed Discard. A meeting still
    /// recording never goes to iCloud, so nothing half-made was sent; the
    /// delete is sent like any other. From Hex (anomalyco/hex `01e5209b`).
    public func discardRecording() {
        guard case let .recording(id, _) = phase, var meta = currentMeta else { return }
        #if os(macOS)
        following?.cancel(); following = nil
        endWatch?.cancel(); endWatch = nil
        micMuted = false
        _ = screenNames?.stop(); screenNames = nil
        #endif
        endingAt = nil
        let micDuration = mic?.stop() ?? 0, systemDuration = system?.stop() ?? 0
        mic = nil; system = nil; currentFolder = nil; currentMeta = nil
        phase = .idle
        do {
            try store.delete(id: id)
            Log.meeting.info("meeting \(id.uuid.uuidString, privacy: .public) discarded")
            onNotice?("Recording discarded")
        } catch {
            // The audio stays and the meeting is listed, so nothing goes without the user knowing.
            Log.meeting.error("discarded meeting could not be deleted: \(String(describing: error), privacy: .public)")
            meta.endedAt = Date(); meta.durationSeconds = max(micDuration, systemDuration)
            meta.status = .failed("This recording was discarded, but its files could not be deleted. Delete it from the list.")
            try? store.save(meta: meta)
            onNotice?("Couldn't delete the recording — see \(MeetingFailure.listName)")
        }
    }

    /// Transcribes again from the audio and writes new notes. A retry after a
    /// failure reuses the finished windows; `fresh` (Redo transcript) hears
    /// the whole meeting again.
    public func retry(id: MeetingID, fresh: Bool = false) {
        guard !isBusy(id), let folder = store.folder(for: id), let meta = store.list().first(where: { $0.id == id }) else { return }
        // Only the notes failed: the saved transcript, and any edits to it, stay.
        if !fresh, meta.waitsForGemini == .notes { return regenerateNotes(id: id) }
        if fresh { Self.dropTranscriptCaches(folder) }
        processing[id] = .transcribing
        Task { await UsageMeter.$scope.withValue(UsageScope(activity: .meeting, sessionID: id.uuid.uuidString)) {
            await process(id: id, folder: folder, meta: meta)
        } }
    }

    /// New notes from the saved transcript, using the speaker names typed since.
    public func regenerateNotes(id: MeetingID) {
        guard !isBusy(id), var meta = store.list().first(where: { $0.id == id }),
              let transcript = try? store.loadTranscript(id: id), !transcript.isEmpty else { return }
        processing[id] = .summarizing
        Task { await UsageMeter.$scope.withValue(UsageScope(activity: .meeting, sessionID: id.uuid.uuidString)) {
            do {
                try mark(&meta, .summarizing)
                guard hasKey() else { throw MeetingFailure.noKey }
                let notes = try await writeNotes(transcript: transcript, meta: &meta)
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
    /// `transcribe-*` windows), and the on-device transcriber builds before
    /// 0.7.18 had (`local-words-*`, and `speakers-*` from builds before 0.6).
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
            guard hasKey() else { throw MeetingFailure.noKey }
            let heard = try await MeetingTranscriber(client: client, models: .init(transcribe: cfg.transcribeModel), endpoint: cfg.endpoint,
                                                     diarizeFarSide: localMeeting.map(Self.farSideDiarizer)).transcribe(folder: folder)
            let transcript = Self.corrected(heard, rules: DictionaryStore().replacementRules())
            let words = transcript.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            guard words >= Self.minimumSummarizableWords else {
                Log.meeting.info("transcript too short to summarize (\(words, privacy: .public) words)")
                try finish(id: id, meta: &meta, transcript: transcript, notes: Self.emptyNotes(reason: "Not enough speech to summarize."))
                return
            }
            try store.save(transcript: transcript, id: id)
            meta.screenNames = ScreenSpeakerNames.match(samples: store.loadScreenSamples(id: id) ?? [], transcript: transcript)
            if let screen = meta.screenNames {
                Log.meeting.info("screen names: \(screen.speakers.count, privacy: .public) speakers named, \(screen.seen.count, privacy: .public) names seen")
                if screen.probablyMerged == true {
                    let heard = Set(transcript.map(\.speaker)).subtracting([MeetingSpeaker.you]).count
                    Log.meeting.notice("speakers probably merged: the call showed \(screen.remote ?? 0, privacy: .public) other people, the transcript has \(heard, privacy: .public) far-side speakers")
                }
            }
            try mark(&meta, .summarizing)
            try Task.checkCancellation()
            let notes = try await writeNotes(transcript: transcript, meta: &meta)
            try finish(id: id, meta: &meta, transcript: transcript, notes: notes)
        } catch { saveFailure(id: id, meta: &meta, error: error) }
    }

    /// The on-device speaker model alone, for telling the far side's voices
    /// apart after Gemini transcribed them. A missing model is downloaded
    /// without asking: it is 21.6 MB, takes about a second, and nothing it
    /// hears leaves the Mac (activities/2026-11-26-meeting-speakers-hybrid.md).
    /// Nil when the model cannot be had, or stays busy, within two minutes.
    nonisolated static func farSideDiarizer(_ runner: @escaping LocalMeetingRunner) -> MeetingTranscriber.FarSideDiarizer {
        { audio in
            let id = UUID(), job = FarSideJob()
            var directory: URL?
            for _ in 0..<60 {
                let (session, waiting) = await MainActor.run { () -> (URL?, Bool) in
                    let store = LocalModelStore.speakerDiarizer
                    switch store.state {
                    // Deleting the model stops the pass and waits for it before the files go.
                    case .ready: return (store.acquireSession(id: id, cancel: { await job.cancel() }), true)
                    case .notDownloaded: store.download(); return (nil, true)
                    case .downloading: return (nil, true)
                    case .unsupported, .deleting, .failed: return (nil, false)
                    }
                }
                directory = session
                if directory != nil || !waiting { break }
                try await Task.sleep(for: .seconds(2))
            }
            guard let directory else { return nil }
            defer { Task { @MainActor in LocalModelStore.speakerDiarizer.releaseSession(id: id) } }
            return try await job.run {
                try await runner(LocalMeetingRequest(speechDirectory: nil, diarizerDirectory: directory, audio: audio)).segments
            }
        }
    }

    /// The recording stays; the meeting is marked failed with a reason the
    /// Meetings list shows, and Retry runs it again with the keys stored then.
    private func saveFailure(id: MeetingID, meta: inout MeetingMeta, error: Error) {
        let reason = MeetingFailure.reason(for: error)
        Log.meeting.error("meeting \(id.uuid.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        // `mark` saved the step that was running when it failed.
        let step: GeminiStep = meta.status == .summarizing ? .notes : .transcript
        meta.status = .failed(reason)
        meta.waitsForGemini = MeetingFailure.waitsForGemini(error) ? step : nil
        try? store.save(meta: meta)
        processing[id] = nil
        if meta.waitsForGemini != nil, hasKey() { scheduleWaitingRetry() }
        switch error as? MeetingFailure {
        case .noKey: onNotice?("\(MeetingFailure.noun) saved — it is transcribed once you add a Gemini key")
        case nil where meta.waitsForGemini != nil: onNotice?("\(MeetingFailure.noun) saved — it is transcribed when Gemini can be reached")
        case nil: onNotice?("\(MeetingFailure.noun) transcript failed — see \(MeetingFailure.listName)")
        }
    }

    /// When the notes name every far-side voice but one and the invite names
    /// the last, that voice is named by elimination and the notes are written
    /// once more, so its tasks carry its name. MEASURED 2026-11-26: the first
    /// notes of a vendor call left "pull the usage numbers" without an owner.
    /// The name goes into `meta.screenNames`, so the transcript shows the
    /// name the notes were written with, and `finish` has nothing left to eliminate.
    private func writeNotes(transcript: [TranscriptSegment], meta: inout MeetingMeta) async throws -> MeetingNotes {
        let cfg = config(), settings = SettingsStore(), dictionary = DictionaryStore()
        let write = { (meta: MeetingMeta) in
            try await self.client.meetingNotes(prompt: MeetingNotesPrompt.build(transcript: transcript, context: .init(
                startedAt: meta.startedAt, durationSeconds: meta.durationSeconds,
                app: meta.source.map(Self.name), names: meta.speakerNames, screenNames: meta.screenNames,
                ownerName: settings.meetingOwnerName, vocabulary: dictionary.sanitizedVocabulary(),
                spellings: dictionary.spellings(), writingRules: settings.customWritingRules,
                calendarEvent: meta.calendarEvent)), transcript: transcript, model: cfg.writingModel, endpoint: cfg.endpoint, deadline: 300)
        }
        let notes = try await write(meta)
        let named = ScreenSpeakerNames.byElimination(meta: meta, transcript: transcript, notes: notes)
        guard named != meta.screenNames else { return notes }
        meta.screenNames = named
        guard var again = try? await write(meta) else { return notes }
        // A name the first notes found (a self-introduction) stays when the rewrite leaves that speaker out.
        let renamed = Set((again.speakers ?? []).filter { $0.name != nil }.map(\.label))
        again.speakers = (again.speakers ?? []) + (notes.speakers ?? []).filter { $0.name != nil && !renamed.contains($0.label) }
        return again
    }

    /// The dictionary's wrong → right spellings, applied to what was heard.
    /// Google takes no custom vocabulary with diarization, so a meeting is
    /// transcribed verbatim and fixed here, as dictation is. FluidVoice applies
    /// its replacements to meetings the same way (altic-dev/FluidVoice).
    nonisolated static func corrected(_ transcript: [TranscriptSegment], rules: [ReplacementEngine.Rule]) -> [TranscriptSegment] {
        transcript.map { segment in
            var segment = segment
            segment.text = ReplacementEngine.apply(rules, to: segment.text)
            return segment
        }
    }

    /// Fewer words than this and the notes model has nothing to work with; it
    /// would write a summary saying so, in whatever language the fragment is.
    static let minimumSummarizableWords = 8

    static func emptyNotes(reason: String) -> MeetingNotes {
        MeetingNotes(title: "No speech recorded", summary: reason, decisions: [], actions: [], notes: [])
    }

    private func finish(id: MeetingID, meta: inout MeetingMeta, transcript: [TranscriptSegment], notes: MeetingNotes) throws {
        try store.save(transcript: transcript, id: id)
        try store.save(notes: notes, id: id)
        meta.screenNames = ScreenSpeakerNames.byElimination(meta: meta, transcript: transcript, notes: notes)
        meta.title = notes.title; meta.status = .done; meta.notesSpeakerNames = meta.speakerNames
        if meta.waitsForGemini != nil { waitingDelay = .seconds(300) }
        meta.waitsForGemini = nil
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
            if let until = quietUntil[Self.offerKey(source)], until > Date() {
                // A quiet app's call can replace another offer directly; that
                // offer's call is gone, so it must not stay up.
                if case .callDetected = phase { phase = .idle; onCallEnded?() }
                return
            }
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
    /// No Gemini key is stored.
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

    /// Gemini was out of reach, not wrong: no key, offline, a timeout, a
    /// transport error, a 5xx or a per-minute rate limit. A rejected key, a
    /// 4xx, an unreadable answer or the daily quota fails the same way on
    /// every retry, so it needs the user instead.
    static func waitsForGemini(_ error: Error) -> Bool {
        switch error {
        case MeetingFailure.noKey: return true
        case let error as TranscriptionError:
            switch error {
            case .offline, .timeout, .rateLimitedTransient: return true
            // GeminiClient sends a URLError code as its number, a 5xx as "http_5xx".
            case .network(let code): return Int(code) != nil || code.hasPrefix("http_5")
            default: return false
            }
        default: return false
        }
    }

    static func reason(for error: Error) -> String {
        switch error {
        case MeetingFailure.noKey:
            return "Add your Gemini API key in \(keysPlace) to transcribe meetings. The recording is saved and is transcribed once a key is added."
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
                return "You were offline when the meeting was transcribed. The recording is saved and is transcribed when you're back online."
            case .timeout, .network where waitsForGemini(error):
                return "Couldn't reach Gemini. The recording is saved and is transcribed when Gemini can be reached."
            case .network:
                return "Transcription failed. \(fixHint)"
            case .safetyBlocked:
                return "Gemini declined to transcribe this meeting. \(fixHint)"
            case .badRequest, .emptyTranscript:
                return "Transcription failed. \(fixHint)"
            }
        default:
            return "Transcription failed: \(error.localizedDescription). \(fixHint)"
        }
    }
}

/// The far-side speaker pass, so deleting the speaker model can stop it and
/// wait for it: on the Mac cancelling kills its helper.
private actor FarSideJob {
    private var task: Task<[LocalMeetingResult.Segment], Error>?
    private var cancelled = false

    func run(_ body: @escaping @Sendable () async throws -> [LocalMeetingResult.Segment]) async throws -> [LocalMeetingResult.Segment] {
        guard !cancelled else { throw CancellationError() }
        let task = Task { try await body() }
        self.task = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func cancel() async {
        cancelled = true
        task?.cancel()
        _ = await task?.result
    }
}
