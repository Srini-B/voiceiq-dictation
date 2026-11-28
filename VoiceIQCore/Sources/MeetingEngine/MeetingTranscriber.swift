import Foundation
import VoiceIQSpeech

/// Turns a meeting's mic and system tracks into one speaker-labelled transcript.
///
/// Only stretches with speech are sent. On a call whose mic came out of echo
/// cancellation clean, each track goes on its own (`transcribeTracks`): the
/// mic is the note owner, and the far side's voices are told apart in
/// requests that hold only the far side. Otherwise both tracks go as one
/// timeline (`CallAudio`). Either way the meeting is cut into windows of
/// speech; every window after the first starts with reference clips of the
/// speakers already found, which is how a speaker keeps one id across a
/// two-hour call (`SpeakerLinker`). On a call, the on-device speaker model
/// then decides who on the far side said each word (`splitFarSide`).
/// Finished windows are cached beside the audio, so a retry after a rate
/// limit or a crash never pays for the same audio twice.
///
/// Each request goes to AssemblyAI's pre-recorded STT-3.7 (Universal-2 for
/// languages it lacks); far-side and mixed requests ask for speaker labels.
///
/// MEASURED 2026-11-26 on AMI ES2004a as a call (one headset as the mic, the
/// other three summed as the far side), with Gemini as the provider: the
/// mixed request merged one of four people away and put 73.5% of words under
/// the right person; the far side alone, silences cut, found all three remote
/// voices at 83.8%.
public struct MeetingTranscriber: Sendable {
    private let client: AssemblyAIClient
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let diarizeFarSide: FarSideDiarizer?

    /// Who spoke when in a recording of the far side alone (16 kHz mono), from
    /// the on-device speaker model. Nil when that model is not downloaded.
    public typealias FarSideDiarizer = @Sendable (URL) async throws -> [LocalMeetingResult.Segment]?

    public init(client: AssemblyAIClient, diarizeFarSide: FarSideDiarizer? = nil,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.client = client
        self.diarizeFarSide = diarizeFarSide
        self.sleep = sleep
    }

    /// Seconds of speech per request. AssemblyAI takes files of up to 10
    /// hours and tells voices apart better with more of each, so an hour of
    /// speech goes as one request; a longer meeting is linked across windows
    /// by reference clips.
    static let windowSpeech: Double = 3600
    /// How long a meeting may wait out rate limits in all.
    static let rateLimitBudget: TimeInterval = 15 * 60
    static let cacheVersion = "v8"
    /// A turn longer than this ends at its next sentence end: a two-minute
    /// answer reads as paragraphs, each with its own time.
    static let paragraphSeconds: Double = 20

    public func transcribe(folder: URL) async throws -> [TranscriptSegment] {
        let audio = try Self.callAudio(folder: folder)
        let cache = folder.appendingPathComponent(
            "transcribe-\(Self.cacheVersion)-assemblyai-\(Int(Self.windowSpeech))", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var budget = Self.rateLimitBudget
        let remote = ScreenSpeakerNames.expectedRemote(folder: folder)
        var words: [TimedWord]
        if audio.isOnline && audio.micIsEchoFree {
            words = try await transcribeTracks(audio: audio, cache: cache, remote: remote, budget: &budget)
        } else {
            words = try await transcribeMixed(audio: audio, cache: cache, remote: remote, budget: &budget)
        }
        if audio.isOnline { words = try await splitFarSide(words, audio: audio, folder: folder) }
        return SpeakerLinker.overlappingTurns(words, paragraph: Self.paragraphSeconds).map { turn in
            TranscriptSegment(speaker: turn.speaker, text: turn.text, chunkIndex: 0, start: turn.start, end: turn.end)
        }
    }

    /// The mic alone is the note owner and the far side alone is everyone
    /// else, each sent in its own windows. Double-talk survives: each voice is
    /// heard on its own track and merged back by time, as FluidVoice does.
    private func transcribeTracks(audio: CallAudio, cache: URL, remote: Int?,
                                  budget: inout TimeInterval) async throws -> [TimedWord] {
        let micWindows = Self.windows(audio.mic.activeRegions(), speech: Self.windowSpeech)
        let owner = try await cachedWindows(micWindows, cache: cache, prefix: "mic-") { index, regions, _ in
            try await requestWords(regions, known: [], speakerLabels: false, label: "mic \(index + 1)/\(micWindows.count)", budget: &budget) { (part: [ClosedRange<Double>], _: [TimedWord]) throws -> AssembledAudio in
                var request = AssembledAudio()
                try request.appendBody(part, source: audio.mic.samples)
                return request
            } place: { (raw: [DiarizedWord], request: AssembledAudio, _: [TimedWord]) -> [TimedWord] in
                raw.compactMap { word -> TimedWord? in
                    guard let start = word.start, let span = request.trackSpan(start, word.end ?? start) else { return nil }
                    return TimedWord(text: word.text, speaker: MeetingSpeaker.you, start: span.lowerBound, end: span.upperBound)
                }
            }
        }
        let farWindows = Self.windows(audio.system.activeRegions(), speech: Self.windowSpeech)
        let far = try await cachedWindows(farWindows, cache: cache, prefix: "far-") { index, regions, known in
            try await transcribe(window: regions, track: .far, audio: audio, known: known, remote: remote, budget: &budget,
                                 label: "far side \(index + 1)/\(farWindows.count)")
        }
        let farSide = Self.droppingOwnerEcho(far, owner: owner)
        if farSide.count < far.count {
            Log.meeting.info("owner echo: dropped \(far.count - farSide.count, privacy: .public) of \(far.count, privacy: .public) far-side words")
        }
        return (owner + farSide).sorted { $0.start < $1.start }
    }

    /// The far side without the owner's own voice. When the owner's speech
    /// leaks into the far track (a remote speaker's mic picks it up, or a
    /// headset bleeds into the others), the far side repeats the owner's words
    /// as another speaker. In a run of one far-side speaker's words, split at
    /// a pause, the stretch from its first word that matches an owner word
    /// starting within `echoSlack` seconds to its last is that echo when at
    /// least `echoRunWords` of its words, and at least `echoShare` of them,
    /// match; that stretch goes, and the run's words before and after it stay
    /// (a remote reply under the same label right after the leak). A short
    /// overlapping "yeah" or "okay" stays: the far side really says those
    /// over the owner.
    /// MEASURED 2026-11-28 on AMI ES2004a: the leak was a fifth speaker with
    /// 120 s and 362 words, 93% of its time inside the owner's turns.
    static func droppingOwnerEcho(_ far: [TimedWord], owner: [TimedWord]) -> [TimedWord] {
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let ownerWords = owner.map { (key: key($0.text), start: $0.start) }.sorted { $0.start < $1.start }
        let starts = ownerWords.map(\.start)
        func echoes(_ word: TimedWord) -> Bool {
            let k = key(word.text)
            guard !k.isEmpty else { return false }
            // The first owner word that starts no earlier than the slack allows.
            var low = 0, high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] < word.start - echoSlack { low = mid + 1 } else { high = mid }
            }
            var i = low
            while i < ownerWords.count, ownerWords[i].start <= word.start + echoSlack {
                if ownerWords[i].key == k { return true }
                i += 1
            }
            return false
        }
        // Runs are per speaker, so another voice talking over the echo can't cut it into short runs.
        var kept: [TimedWord] = []
        for words in Dictionary(grouping: far, by: \.speaker).values {
            var run: [TimedWord] = []
            func flush() {
                defer { run = [] }
                let matched = run.map(echoes)
                guard let first = matched.firstIndex(of: true), let last = matched.lastIndex(of: true) else { kept += run; return }
                let core = last - first + 1
                let echoed = matched[first...last].filter { $0 }.count
                guard echoed >= echoRunWords, Double(echoed) >= echoShare * Double(core) else { kept += run; return }
                kept += run[..<first] + run[(last + 1)...]
            }
            for word in words.sorted(by: { $0.start < $1.start }) {
                if let last = run.last, word.start - last.end > echoRunGap { flush() }
                run.append(word)
            }
            flush()
        }
        return kept.sorted { $0.start < $1.start }
    }

    static let echoSlack: Double = 0.5
    static let echoShare = 0.6
    static let echoRunWords = 3
    static let echoRunGap: Double = 1.0

    /// Both tracks as one timeline, for a mic that still carries the far
    /// side's echo or a recording with no far side: the owner is whoever is
    /// heard from the mic alone.
    private func transcribeMixed(audio: CallAudio, cache: URL, remote: Int?,
                                 budget: inout TimeInterval) async throws -> [TimedWord] {
        let windows = Self.windows(audio.activeRegions(), speech: Self.windowSpeech)
        var words = try await cachedWindows(windows, cache: cache, prefix: "") { index, regions, known in
            try await transcribe(window: regions, track: .mixed, audio: audio, known: known, remote: remote, budget: &budget,
                                 label: "window \(index + 1)/\(windows.count)")
        }
        if audio.isOnline {
            words = Self.markOwner(words, audio: audio)
            words = Self.byTrack(words, audio: audio)
        }
        return words
    }

    /// Each window's words, read from the cache beside the audio or made by
    /// `body` and cached, in order. `body` gets the words of the windows before.
    private func cachedWindows(_ windows: [[ClosedRange<Double>]], cache: URL, prefix: String,
                               _ body: (Int, [ClosedRange<Double>], [TimedWord]) async throws -> [TimedWord]) async throws -> [TimedWord] {
        var words: [TimedWord] = []
        for (index, regions) in windows.enumerated() {
            let file = cache.appendingPathComponent("\(prefix)\(index).json")
            if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([TimedWord].self, from: data) {
                words += cached; continue
            }
            let placed = try await body(index, regions, words)
            try JSONEncoder().encode(placed).write(to: file, options: .atomic)
            words += placed
        }
        return words
    }

    /// One request for `regions`.
    private func requestWords(_ regions: [ClosedRange<Double>], known: [TimedWord], speakerLabels: Bool = true, label: String,
                              budget: inout TimeInterval,
                              build: ([ClosedRange<Double>], [TimedWord]) throws -> AssembledAudio,
                              place: ([DiarizedWord], AssembledAudio, [TimedWord]) -> [TimedWord]) async throws -> [TimedWord] {
        let request = try build(regions, known)
        let flac = try FLACEncoder.encode(samples: request.samples)
        do {
            let raw = try await withRetries(label: label, budget: &budget) {
                try await client.transcribeSpeakers(audio: flac, speakerLabels: speakerLabels, deadline: 900)
            }
            return place(raw, request, known)
        } catch TranscriptionError.emptyTranscript {
            // A window of coughs or keys only: the service finds no speech in it.
            Log.meeting.info("\(label, privacy: .public): no speech")
            return []
        }
    }

    /// Both tracks, with the mic's echo cancelled when the far side talked.
    /// The cancelled mic is kept only if it came out echo-free; otherwise the
    /// raw mic is ducked under the far side as before.
    static func callAudio(folder: URL) throws -> CallAudio {
        let micURL = folder.appendingPathComponent("mic.caf"), systemURL = folder.appendingPathComponent("system.caf")
        let system = try TrackAudio(url: systemURL)
        let meta = try? JSONDecoder().decode(MeetingMeta.self, from: Data(contentsOf: folder.appendingPathComponent("meta.json")))
        let detectedCall = meta?.source != nil
        let raw = CallAudio(mic: try TrackAudio(url: micURL), system: system, detectedCall: detectedCall)
        guard raw.isOnline else { return raw }
        #if os(macOS)
        let cancelledURL = folder.appendingPathComponent("mic-aec.caf")
        do {
            if !FileManager.default.fileExists(atPath: cancelledURL.path) {
                let erle = try EchoCanceller.cancel(mic: micURL, system: systemURL, output: cancelledURL)
                Log.meeting.info("echo cancelled, ERLE \(String(format: "%.1f", erle), privacy: .public) dB")
            }
            let cancelled = CallAudio(mic: try TrackAudio(url: cancelledURL), system: system, micIsEchoFree: true,
                                      detectedCall: detectedCall)
            Log.meeting.info("echo left in mic: \(String(format: "%.1f", raw.residualEcho), privacy: .public) dB before, \(String(format: "%.1f", cancelled.residualEcho), privacy: .public) dB after")
            return cancelled.residualEcho <= maximumResidualEcho ? cancelled : raw
        } catch {
            Log.meeting.error("echo cancellation failed: \(String(describing: error), privacy: .public)")
            return raw
        }
        #else
        // iOS records the mic alone (`SystemAudioTap` writes silence), so
        // there is no far-side reference to cancel against.
        return raw
        #endif
    }

    /// Echo left above the mic's room tone, in dB, that still counts as
    /// echo-free. Measured residuals after cancellation were 0.5 and 0.7 dB;
    /// before it, 15.5 and 23.5.
    static let maximumResidualEcho = 6.0

    /// The same test as `place`, over the whole meeting: an id heard mostly
    /// from the mic is the note owner even where single windows were too
    /// short to tell. MEASURED 2026-09-27 on the same two-person call: one id
    /// ended at 318 mic-only windows to 119 far-side ones after every window
    /// had been placed.
    static func markOwner(_ words: [TimedWord], audio: CallAudio) -> [TimedWord] {
        var totals: [String: (mic: Int, system: Int)] = [:]
        for word in words {
            let source = audio.sources(word.start...word.end)
            totals[word.speaker, default: (0, 0)].mic += source.mic
            totals[word.speaker, default: (0, 0)].system += source.system
        }
        let owners = Set(totals.filter { $0.value.mic >= 20 && $0.value.mic >= 2 * $0.value.system }.keys)
        return words.map { word in
            guard owners.contains(word.speaker) else { return word }
            var owned = word; owned.speaker = MeetingSpeaker.you; return owned
        }
    }

    /// Each word goes to the track it was heard on, whatever the model said:
    /// a word heard only from the far side is not the owner's, and one heard
    /// only from the mic is. A word with sound on both, or on neither, keeps
    /// its speaker. Mic silence under a far-side word says the owner was
    /// silent only when the mic is echo-free; otherwise far-side speech
    /// hides the mic and only the second rule applies. A far-side word taken
    /// from the owner goes to the far-side speaker talking nearest to it,
    /// within 30 s, else to one new far-side id.
    /// MEASURED 2026-11-23 on a 22-minute three-person Meet call: 114 s of
    /// far-side speech came back as the owner's and 49 s of mic speech as a
    /// far-side speaker's.
    static func byTrack(_ words: [TimedWord], audio: CallAudio) -> [TimedWord] {
        let heard = words.map { audio.sources($0.start...max($0.end, $0.start)) }
        // Far-side speakers heard on the system track; a mic-only word is no evidence of one.
        let micOnly = heard.map { $0.system == 0 && $0.mic >= 2 }
        let far = words.indices.filter { (index: Int) -> Bool in words[index].speaker != MeetingSpeaker.you && !micOnly[index] }
        // One id for all such words: they are most likely one person.
        let fallback = "s\((words.compactMap { Int($0.speaker.dropFirst()) }.max() ?? 0) + 1)"
        var out = words
        for index in words.indices {
            let source = heard[index], word = words[index]
            if word.speaker == MeetingSpeaker.you {
                guard audio.micIsEchoFree, source.mic == 0, source.system >= 2 else { continue }
                let nearest = far.min { abs(words[$0].start - word.start) < abs(words[$1].start - word.start) }
                if let nearest, abs(words[nearest].start - word.start) <= 30 {
                    out[index].speaker = words[nearest].speaker
                } else {
                    out[index].speaker = fallback
                }
            } else if micOnly[index] {
                out[index].speaker = MeetingSpeaker.you
            }
        }
        return out
    }

    /// On a call, who on the far side said each word comes from the on-device
    /// speaker model run over the whole far-side track, whenever it heard
    /// anyone: it got the speaker count right in 31 of 33 runs in ours
    /// (activities/2026-11-06-offline-speaker-diarizer.md). Without the model
    /// the words keep AssemblyAI's speaker labels.
    /// A model that failed even after `FarSideSpeakers.retrying` leaves a
    /// marker, so the meeting says its voices may be merged and offers the
    /// split again (`MeetingMeta.speakersUnsplit`).
    func splitFarSide(_ words: [TimedWord], audio: CallAudio, folder: URL) async throws -> [TimedWord] {
        let ids = Set(words.map(\.speaker)).subtracting([MeetingSpeaker.you])
        let failed = folder.appendingPathComponent(Self.farSpeakersFailedName)
        try? FileManager.default.removeItem(at: failed)
        guard !ids.isEmpty else { return words }
        let cache = folder.appendingPathComponent(Self.farSpeakersCacheName)
        var segments = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode([LocalMeetingResult.Segment].self, from: $0) }
        if segments == nil, let diarizeFarSide {
            let track = folder.appendingPathComponent("far-side-mix.caf")
            defer { try? FileManager.default.removeItem(at: track) }
            do {
                try FarSideSpeakers.writeMix(duration: audio.system.duration, samples: audio.system.samples, to: track)
                segments = try await diarizeFarSide(track)
                if let segments { try? JSONEncoder().encode(segments).write(to: cache, options: .atomic) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.meeting.error("far side not split: \(String(describing: error), privacy: .public)")
                try? Data().write(to: failed)
            }
        }
        guard let segments, !segments.isEmpty else {
            Log.meeting.info("far side: \(ids.count, privacy: .public) speakers from AssemblyAI; the speaker model is not downloaded or heard nobody")
            return words
        }
        let split = Self.split(words, segments: segments)
        let found = Set(split.map(\.speaker)).subtracting([MeetingSpeaker.you]).count
        Log.meeting.info("far side: \(ids.count, privacy: .public) speakers from AssemblyAI, \(found, privacy: .public) voices from the speaker model")
        return split
    }

    /// Cached beside the audio; a fresh redo removes it with the windows.
    static let farSpeakersCacheName = "transcribe-far-speakers-v1.json"
    static let farSpeakersFailedName = "transcribe-far-speakers-failed"

    /// The speaker model, run again when Core ML fails a prediction (`FarSideSpeakers.retrying`).
    public static func retryingSpeakerModel<T: Sendable>(_ attempt: (_ cpuOnly: Bool) async throws -> T) async throws -> T {
        try await FarSideSpeakers.retrying(attempt)
    }

    /// The last transcription kept AssemblyAI's far-side voices because the speaker model failed.
    public static func farSideFailed(folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(farSpeakersFailedName).path)
    }

    /// Far-side words relabelled by the diarizer's stretches on the system
    /// track; the owner's keep theirs. Ids are renumbered from s1.
    static func split(_ words: [TimedWord], segments: [LocalMeetingResult.Segment]) -> [TimedWord] {
        let far = words.indices.filter { words[$0].speaker != MeetingSpeaker.you }
        let farWords = far.map { LocalMeetingResult.Word(text: words[$0].text, start: words[$0].start, end: words[$0].end) }
        let labelled = FarSideSpeakers.settled(FarSideSpeakers.label(farWords, segments: segments), segments: segments)
        var out = words
        for (offset, index) in far.enumerated() { out[index].speaker = "far " + labelled[offset].speaker }
        return FarSideSpeakers.renumber(foldingStrayVoices(out))
    }

    /// A far-side voice heard for less than this share of the meeting is not
    /// a participant. MEASURED 2026-11-26 on AMI ES2004a: the model heard a
    /// fifth voice for 8.7 s of 1049 s, all overlapping "yeah" and "okay"
    /// from the other people, and it cost the participant score 10 points.
    static let strayVoiceShare = 0.01

    /// And for less than this long: someone who speaks 30 s in a one-hour
    /// call is a participant, though under 1% of it.
    static let strayVoiceSeconds = 15.0

    /// A stray voice's words go to the nearest far-side word of a kept voice,
    /// so no words are lost.
    static func foldingStrayVoices(_ words: [TimedWord]) -> [TimedWord] {
        guard let first = words.map(\.start).min(), let last = words.map(\.end).max() else { return words }
        var talk: [String: Double] = [:]
        for word in words where word.speaker != MeetingSpeaker.you { talk[word.speaker, default: 0] += word.end - word.start }
        let stray = Set(talk.filter { $0.value < min((last - first) * strayVoiceShare, strayVoiceSeconds) }.keys)
        let kept = words.filter { $0.speaker != MeetingSpeaker.you && !stray.contains($0.speaker) }
        guard !stray.isEmpty, !kept.isEmpty else { return words }
        return words.map { word in
            guard stray.contains(word.speaker),
                  let nearest = kept.min(by: { abs($0.start - word.start) < abs($1.start - word.start) }) else { return word }
            var word = word
            word.speaker = nearest.speaker
            return word
        }
    }

    /// Consecutive speech regions grouped into requests of about `windowSpeech` seconds each.
    static func windows(_ regions: [ClosedRange<Double>], speech windowSpeech: Double) -> [[ClosedRange<Double>]] {
        var out: [[ClosedRange<Double>]] = [], current: [ClosedRange<Double>] = [], total = 0.0
        for region in regions {
            if total + (region.upperBound - region.lowerBound) > windowSpeech, !current.isEmpty {
                out.append(current); current = []; total = 0
            }
            current.append(region); total += region.upperBound - region.lowerBound
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Request words → meeting-time words under meeting-wide ids.
    ///
    /// On a call the track a label was heard on overrides the model: a label
    /// heard from the mic alone is the note owner, and a label heard from the
    /// far side never is. When the far side has had only one speaker so far,
    /// its one unmatched label is that speaker. MEASURED 2026-09-27 on a
    /// 30-minute two-person call: without this the
    /// two people swapped ids between windows; the owner's words were 422
    /// mic-only windows to 119 far-side ones.
    /// That holds only when the reference clip got no label of its own, so
    /// no voice says otherwise, and never when the call showed two or more
    /// other people (`expected`): then a new voice is a new speaker.
    /// MEASURED 2026-11-23 on a three-person Meet call: the rule put the
    /// second remote person under the first's id in every window.
    /// A request that held only the far side (`farOnly`) has no owner in it.
    static func place(_ raw: [DiarizedWord], audio request: AssembledAudio, call: CallAudio, known: [TimedWord],
                      mapping linked: [String: String], remote expected: Int? = nil, farOnly: Bool = false,
                      idPrefix: String = "s") -> [TimedWord] {
        typealias Placed = (text: String, label: String, start: Double, end: Double)
        // A word the provider left without a speaker belongs to the one before
        // it; an empty label of its own became a speaker who never existed.
        // Reference words dropped below do not pass their label on, and words
        // before the first label take that label.
        var previous = ""
        var placed: [Placed] = raw.compactMap { word in
            let label = word.speaker ?? previous
            guard let start = word.start, let span = request.trackSpan(start, word.end ?? start) else { return nil }
            previous = label
            return (word.text, label, span.lowerBound, span.upperBound)
        }
        if let first = placed.first(where: { !$0.label.isEmpty })?.label {
            for index in placed.indices where placed[index].label.isEmpty { placed[index].label = first }
        }
        var mapping = linked
        if call.isOnline {
            var sources: [String: (mic: Int, system: Int)] = [:]
            for word in placed where !farOnly {
                let source = call.sources(word.start...word.end)
                sources[word.label, default: (0, 0)].mic += source.mic
                sources[word.label, default: (0, 0)].system += source.system
            }
            for (label, source) in sources {
                if source.mic >= 10 && source.mic >= 2 * source.system { mapping[label] = MeetingSpeaker.you }
                else if mapping[label] == MeetingSpeaker.you { mapping[label] = nil }
            }
            let remote = Set(known.map(\.speaker)).subtracting([MeetingSpeaker.you])
            let unmatched = Set(placed.map(\.label)).filter { mapping[$0] == nil }
            if remote.count == 1, unmatched.count == 1, let only = remote.first, !mapping.values.contains(only),
               (expected ?? 1) <= 1 {
                mapping[unmatched.first!] = only
            }
        }
        var next = (known.compactMap { Int($0.speaker.dropFirst(idPrefix.count)) }.max() ?? 0) + 1
        return placed.map { word in
            TimedWord(text: word.text, speaker: resolve(word.label, &mapping, &next, idPrefix), start: word.start, end: word.end)
        }
    }

    private static func resolve(_ label: String, _ mapping: inout [String: String], _ next: inout Int, _ prefix: String) -> String {
        if let id = mapping[label] { return id }
        let id = "\(prefix)\(next)"; next += 1; mapping[label] = id
        return id
    }

    /// What a window request holds: both tracks as one timeline, or the far side alone.
    enum Track { case mixed, far }

    /// One window. Reference clips of the speakers found so far go inside the
    /// audio, and the labels the API gives them name the speakers
    /// (`SpeakerLinker.link`).
    private func transcribe(window regions: [ClosedRange<Double>], track: Track, audio: CallAudio, known: [TimedWord],
                            remote: Int?, budget: inout TimeInterval, label: String) async throws -> [TimedWord] {
        let source: (ClosedRange<Double>) throws -> [Int16]
        switch track {
        case .far: source = { try audio.system.samples($0) }
        case .mixed: source = { try audio.samples($0) }
        }
        return try await requestWords(regions, known: known, label: label, budget: &budget) { (part: [ClosedRange<Double>], known: [TimedWord]) throws -> AssembledAudio in
            var request = AssembledAudio()
            for (id, ranges) in SpeakerLinker.anchorClips(known).sorted(by: { $0.key < $1.key }) {
                try request.appendAnchor(id: id, clips: ranges, source: source)
            }
            try request.appendBody(part, source: source)
            return request
        } place: { (raw: [DiarizedWord], request: AssembledAudio, known: [TimedWord]) -> [TimedWord] in
            Self.place(raw, audio: request, call: audio, known: known, mapping: SpeakerLinker.link(words: raw, anchors: request.anchors),
                       remote: remote, farOnly: track == .far)
        }
    }

    /// Runs `body`, waiting out a rate limit while `budget` lasts.
    private func withRetries<T>(label: String, budget: inout TimeInterval, _ body: () async throws -> T) async throws -> T {
        while true {
            do {
                return try await body()
            } catch TranscriptionError.rateLimitedTransient(let retryAfter) {
                let wait = (retryAfter ?? 60) + 2
                guard wait <= budget else { throw TranscriptionError.rateLimitedTransient(retryAfter: retryAfter) }
                budget -= wait
                Log.meeting.info("\(label, privacy: .public): waiting \(Int(wait), privacy: .public)s for the rate limit")
                try await sleep(wait)
            }
        }
    }
}
