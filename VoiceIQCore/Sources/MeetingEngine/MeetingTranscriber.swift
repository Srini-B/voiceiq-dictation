import Foundation

/// Turns a meeting's mic and system tracks into one speaker-labelled transcript.
///
/// Only stretches with speech are sent, as one timeline of both tracks
/// (`CallAudio`). The meeting is cut into windows of speech; every window
/// after the first starts with reference clips of the speakers already found,
/// which is how a speaker keeps one id across a two-hour call
/// (`SpeakerLinker`). The note owner is whoever speaks from the mic alone.
/// Finished windows are cached beside the audio, so a retry after a rate
/// limit or a crash never pays for the same audio twice.
///
/// MEASURED 2026-09-27. Transcribing the two tracks separately was tried
/// first and dropped: a request holding only the far side, with its long
/// silences cut out, made both models return a fraction of the speech (29
/// segments for ten minutes of a call through the flash model).
public struct MeetingTranscriber: Sendable {
    public struct Models: Sendable {
        public var transcribe: String
        public init(transcribe: String) { self.transcribe = transcribe }
    }

    private let client: GeminiClient
    private let models: Models
    private let endpoint: URL
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(client: GeminiClient, models: Models, endpoint: URL,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.client = client; self.models = models; self.endpoint = endpoint
        self.sleep = sleep
    }

    /// Seconds of speech per request. Diarized requests are capped at 30
    /// minutes of audio; ten keeps a Tier 1 Gemini key (10,000 audio tokens a
    /// minute, 25 tokens a second) to about one minute of waiting per window.
    /// MEASURED 2026-09-27 on a 30-minute call: Gemini at 600 s gave 907 words.
    static let windowSpeech: Double = 600
    /// A Tier 1 key needs about one minute of waiting per window; a two-hour
    /// call has twenty windows.
    static let rateLimitBudget: TimeInterval = 45 * 60
    static let cacheVersion = "v7"

    public func transcribe(folder: URL) async throws -> [TranscriptSegment] {
        let audio = try Self.callAudio(folder: folder)
        // The name matches the Gemini windows earlier versions cached, so a
        // redo of an older meeting reuses them.
        let cache = folder.appendingPathComponent(
            "transcribe-\(Self.cacheVersion)-gemini-\(Int(Self.windowSpeech))", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var budget = Self.rateLimitBudget
        let windows = Self.windows(audio.activeRegions(), speech: Self.windowSpeech)
        var words: [TimedWord] = []
        for (index, regions) in windows.enumerated() {
            let file = cache.appendingPathComponent("\(index).json")
            if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([TimedWord].self, from: data) {
                words += cached; continue
            }
            let placed = try await transcribe(window: regions, audio: audio, known: words, budget: &budget,
                                              label: "window \(index + 1)/\(windows.count)")
            try JSONEncoder().encode(placed).write(to: file, options: .atomic)
            words += placed
        }
        if audio.isOnline { words = Self.markOwner(words, audio: audio) }
        let overlaps = audio.overlapRegions()
        if !overlaps.isEmpty {
            let file = cache.appendingPathComponent("overlap.json")
            let owner: [TimedWord]
            if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([TimedWord].self, from: data) {
                owner = cached
            } else {
                owner = try await transcribeOwner(overlaps, audio: audio, budget: &budget)
                try JSONEncoder().encode(owner).write(to: file, options: .atomic)
            }
            words = Self.mergeOwner(owner, into: words, overlaps: overlaps)
        }
        words = BrowserSpeakers.apply(words, folder: folder)
        return SpeakerLinker.overlappingTurns(words).map { turn in
            TranscriptSegment(speaker: turn.speaker, text: turn.text, chunkIndex: 0, start: turn.start, end: turn.end)
        }
    }

    /// Where the owner talked over the far side, a request holding both voices
    /// comes back with one of them. MEASURED 2026-09-27 on a synthetic call
    /// where the owner cut in four times, echo cancelled: 2 to 6 of each
    /// interjection's 8 to 10 words came back, half under the far speaker.
    /// So those stretches are sent again from the echo-cancelled mic alone,
    /// and every word in that answer is the owner's. This is how FluidVoice
    /// keeps double-talk: separate tracks, merged by time.
    /// Overlaps go in windows of the same size as the main pass.
    private func transcribeOwner(_ regions: [ClosedRange<Double>], audio: CallAudio,
                                 budget: inout TimeInterval) async throws -> [TimedWord] {
        let window = Self.windowSpeech
        // `windows` keeps a long region whole, and one overlap can outlast a window.
        let pieces = regions.flatMap { region in
            stride(from: region.lowerBound, to: region.upperBound, by: window).map {
                $0...min($0 + window, region.upperBound)
            }
        }
        var words: [TimedWord] = []
        for part in Self.windows(pieces, speech: window) {
            var request = AssembledAudio()
            try request.appendBody(part, source: audio.mic.samples)
            let flac = try FLACEncoder.encode(samples: request.samples)
            let raw = try await withRetries(label: "overlap", budget: &budget) {
                try await transcribeSpeakers(flac)
            }
            words += raw.compactMap { word in
                guard let start = word.start, let span = request.trackSpan(start, word.end ?? start) else { return nil }
                return TimedWord(text: word.text, speaker: MeetingSpeaker.you, start: span.lowerBound, end: span.upperBound)
            }
        }
        return words
    }

    /// The owner's words replace whatever the mixed pass made of the overlap:
    /// its "You" words there, and far-side words that repeat the owner's.
    static func mergeOwner(_ owner: [TimedWord], into words: [TimedWord], overlaps: [ClosedRange<Double>]) -> [TimedWord] {
        func inside(_ word: TimedWord) -> Bool {
            let middle = (word.start + word.end) / 2
            return overlaps.contains { $0.contains(middle) }
        }
        let kept = words.filter { word in
            guard inside(word) else { return true }
            if word.speaker == MeetingSpeaker.you { return false }
            let key = TranscriptText.normalized(word.text)
            let nearby = owner.filter { abs($0.start - word.start) <= 2 }.map { TranscriptText.normalized($0.text) }.joined()
            return key.isEmpty || TranscriptText.containment(key, in: nearby) < 0.5
        }
        return kept + owner
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
    static func place(_ raw: [DiarizedWord], audio request: AssembledAudio, call: CallAudio, known: [TimedWord],
                      mapping linked: [String: String], idPrefix: String = "s") -> [TimedWord] {
        typealias Placed = (text: String, label: String, start: Double, end: Double)
        // A word the provider left without a speaker belongs to the one before
        // it; an empty label of its own became a speaker who never existed.
        // Reference words dropped below do not pass their label on, and words
        // before the first label take that label.
        var previous = ""
        var placed: [Placed] = raw.compactMap { word in
            let label = word.speaker ?? previous
            guard let start = word.start else {
                // Untimed text (the API's no-annotation fallback) is kept as one turn.
                previous = label
                return (word.text, label, request.trackTime(request.bodyStart) ?? 0, request.trackTime(request.duration) ?? 0)
            }
            guard let span = request.trackSpan(start, word.end ?? start) else { return nil }
            previous = label
            return (word.text, label, span.lowerBound, span.upperBound)
        }
        if let first = placed.first(where: { !$0.label.isEmpty })?.label {
            for index in placed.indices where placed[index].label.isEmpty { placed[index].label = first }
        }
        var mapping = linked
        if call.isOnline {
            var sources: [String: (mic: Int, system: Int)] = [:]
            for word in placed {
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
            if remote.count == 1, unmatched.count == 1, let only = remote.first, !mapping.values.contains(only) {
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

    /// One window. Reference clips of the speakers found so far go inside the
    /// audio, and the labels the API gives them name the speakers
    /// (`SpeakerLinker.link`).
    private func transcribe(window regions: [ClosedRange<Double>], audio: CallAudio, known: [TimedWord],
                            budget: inout TimeInterval, label: String) async throws -> [TimedWord] {
        let clips = SpeakerLinker.anchorClips(known).sorted { $0.key < $1.key }
        var request = AssembledAudio()
        for (id, ranges) in clips { try request.appendAnchor(id: id, clips: ranges, from: audio) }
        try request.appendBody(regions, from: audio)
        let flac = try FLACEncoder.encode(samples: request.samples)
        let raw = try await withRetries(label: label, budget: &budget) { try await transcribeSpeakers(flac) }
        return Self.place(raw, audio: request, call: audio, known: known, mapping: SpeakerLinker.link(words: raw, anchors: request.anchors))
    }

    /// Runs `body`, trying a safety block once more and waiting out a
    /// per-minute rate limit while `budget` lasts.
    private func withRetries<T>(label: String, budget: inout TimeInterval, _ body: () async throws -> T) async throws -> T {
        while true {
            do {
                do { return try await body() } catch TranscriptionError.safetyBlocked {
                    // MEASURED 2026-09-27: the flash model blocked one window of a
                    // call as `content_filter` and passed the same window on the
                    // next run. One more try before giving up.
                    Log.meeting.info("\(label, privacy: .public): safety block, retrying")
                    return try await body()
                }
            } catch TranscriptionError.rateLimitedTransient(let retryAfter) {
                let wait = (retryAfter ?? 60) + 2
                guard wait <= budget else { throw TranscriptionError.rateLimitedTransient(retryAfter: retryAfter) }
                budget -= wait
                Log.meeting.info("\(label, privacy: .public): waiting \(Int(wait), privacy: .public)s for the rate limit")
                try await sleep(wait)
            } catch is DecodingError {
                Log.meeting.error("\(label, privacy: .public): returned unreadable segments")
                throw TranscriptionError.network("unreadable_segments")
            }
        }
    }

    /// Speaker-labelled, word-timed words from gemini-3.5-transcribe.
    private func transcribeSpeakers(_ flac: Data) async throws -> [DiarizedWord] {
        try await client.transcribeSpeakers(audio: flac, model: models.transcribe, endpoint: endpoint, deadline: 600)
    }
}
