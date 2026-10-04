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
        public var flash: String
        public init(transcribe: String, flash: String) { self.transcribe = transcribe; self.flash = flash }
    }

    /// Who hears the audio: ElevenLabs Scribe, MAI Transcribe 2 or Sarvam
    /// Saaras V4 when Settings picks it as the transcription source, the
    /// same as dictation; otherwise the provider's meeting routes in order.
    public enum SpeechRoute: Equatable, Sendable {
        case elevenLabs
        /// MAI Transcribe 2 through this gateway.
        case mai(ModelEndpoint)
        /// Saaras V4's batch job with diarization on.
        case sarvam
        case model(ModelRoute)

        public var label: String {
            switch self {
            case .elevenLabs: return "ElevenLabs"
            case .mai(let via): return "mai/\(via.rawValue)"
            case .sarvam: return "sarvam"
            case .model(let route): return route.label
            }
        }

        public var displayName: String {
            switch self {
            case .elevenLabs: return "ElevenLabs"
            case .mai(let via): return "MAI Transcribe 2 via \(via.hostName)"
            case .sarvam: return "Sarvam Saaras V4"
            case .model(let route): return route.displayName
            }
        }

        /// Names the window cache, so a redo after switching the source
        /// transcribes again instead of reusing the other model's windows.
        /// Sarvam's key carries the language the windows were sent with
        /// (`diarize` reads the same setting), so a redo after changing it
        /// does not keep windows heard in the old one.
        var cacheKey: String {
            switch self {
            case .elevenLabs: return "elevenlabs"
            case .mai(let via): return "mai-\(via.rawValue)"
            case .sarvam: return "sarvam-\(SettingsStore().sarvamLanguage.rawValue)"
            case .model(let route): return "\(route.provider.rawValue)-\(route.gateway.rawValue)"
            }
        }

        /// Speech-to-text models that label speakers themselves: the
        /// reference clips go inside the audio and `SpeakerLinker.link`
        /// reads the ids off the labels they get.
        var anchorsInAudio: Bool {
            switch self {
            case .elevenLabs, .mai, .sarvam: return true
            case .model(let route): return route == ModelRoute(provider: .gemini, gateway: .direct)
            }
        }

        /// The picked source alone when there is one, otherwise the provider's routes.
        public static func order(picked: SpeechRoute?, providers: [ModelRoute]) -> [SpeechRoute] {
            picked.map { [$0] } ?? providers.map(SpeechRoute.model)
        }
    }

    private let client: GeminiClient
    private let models: Models
    private let endpoint: URL
    private let routes: @Sendable () -> [SpeechRoute]
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(client: GeminiClient, models: Models, endpoint: URL,
                routes: @escaping @Sendable () -> [SpeechRoute],
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.client = client; self.models = models; self.endpoint = endpoint; self.routes = routes; self.sleep = sleep
    }

    /// Seconds of speech per request. Diarized requests are capped at 30
    /// minutes of audio; ten keeps a Tier 1 key (10,000 audio tokens a minute,
    /// 25 tokens a second) to about one minute of waiting per window. The
    /// flash model on the gateway path drops speech from long audio, so it
    /// gets shorter windows. MEASURED 2026-09-27 on a 30-minute call: native
    /// at 600 s gave 907 words, the gateway at 150 s gave 807, and the gateway
    /// at 600 s on one track gave 29 segments for ten minutes of speech.
    /// OpenAI's diarizing model, ElevenLabs Scribe and MAI Transcribe 2 are
    /// transcription models, not the flash model, so they get the native
    /// window. None is measured on a long call yet. MAI's diarization fails
    /// on recordings of about 15 minutes (Azure Speech docs, 2026-09), so
    /// its window must stay well under that.
    static func windowSpeech(_ via: SpeechRoute?) -> Double {
        switch via {
        case .elevenLabs, .mai, .sarvam: return 600
        case .model(let route): return route.gateway == .direct ? 600 : 150
        case nil: return 150
        }
    }
    /// A Tier 1 key needs about one minute of waiting per window; a two-hour
    /// call has twenty windows.
    static let rateLimitBudget: TimeInterval = 45 * 60
    static let cacheVersion = "v6"

    public func transcribe(folder: URL) async throws -> [TranscriptSegment] {
        let audio = try Self.callAudio(folder: folder)
        let first = routes().first
        let window = Self.windowSpeech(first)
        let cache = folder.appendingPathComponent(
            "transcribe-\(Self.cacheVersion)-\(first?.cacheKey ?? "none")-\(Int(window))", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var budget = Self.rateLimitBudget
        let windows = Self.windows(audio.activeRegions(), speech: window)
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
    private func transcribeOwner(_ regions: [ClosedRange<Double>], audio: CallAudio,
                                 budget: inout TimeInterval) async throws -> [TimedWord] {
        var request = AssembledAudio()
        try request.appendBody(regions, source: audio.mic.samples)
        let flac = try FLACEncoder.encode(samples: request.samples)
        let raw = try await withProviders(label: "overlap", budget: &budget) { via in
            try await transcribeSpeakers(flac, seconds: request.duration, references: [], via: via)
        }
        return raw.compactMap { word in
            guard let start = word.start, let span = request.trackSpan(start, word.end ?? start) else { return nil }
            return TimedWord(text: word.text, speaker: MeetingSpeaker.you, start: span.lowerBound, end: span.upperBound)
        }
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
        let raw = CallAudio(mic: try TrackAudio(url: micURL), system: system)
        guard raw.isOnline else { return raw }
        #if os(macOS)
        let cancelledURL = folder.appendingPathComponent("mic-aec.caf")
        do {
            if !FileManager.default.fileExists(atPath: cancelledURL.path) {
                let erle = try EchoCanceller.cancel(mic: micURL, system: systemURL, output: cancelledURL)
                Log.meeting.info("echo cancelled, ERLE \(String(format: "%.1f", erle), privacy: .public) dB")
            }
            let cancelled = CallAudio(mic: try TrackAudio(url: cancelledURL), system: system, micIsEchoFree: true)
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
    /// 30-minute two-person call through the gateway path: without this the
    /// two people swapped ids between windows; the owner's words were 422
    /// mic-only windows to 119 far-side ones.
    static func place(_ raw: [DiarizedWord], audio request: AssembledAudio, call: CallAudio, known: [TimedWord],
                      mapping linked: [String: String], idPrefix: String = "s") -> [TimedWord] {
        typealias Placed = (text: String, label: String, start: Double, end: Double)
        let placed: [Placed] = raw.compactMap { word in
            let label = word.speaker ?? ""
            guard let start = word.start else {
                // Untimed text (the API's no-annotation fallback) is kept as one turn.
                return (word.text, label, request.trackTime(request.bodyStart) ?? 0, request.trackTime(request.duration) ?? 0)
            }
            guard let span = request.trackSpan(start, word.end ?? start) else { return nil }
            return (word.text, label, span.lowerBound, span.upperBound)
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

    /// One window through the first provider that answers.
    private func transcribe(window regions: [ClosedRange<Double>], audio: CallAudio, known: [TimedWord],
                            budget: inout TimeInterval, label: String) async throws -> [TimedWord] {
        let clips = SpeakerLinker.anchorClips(known).sorted { $0.key < $1.key }
        return try await withProviders(label: label, budget: &budget) { via in
            try await transcribe(window: regions, audio: audio, clips: clips, known: known, via: via)
        }
    }

    /// Runs `body` with each provider in turn. A throttled provider is waited
    /// out only when no other provider has a key.
    private func withProviders<T>(label: String, budget: inout TimeInterval,
                                  _ body: (SpeechRoute) async throws -> T) async throws -> T {
        var lastError: Error = TranscriptionError.network("no_provider")
        while true {
            var waits: [TimeInterval] = []
            for via in routes() {
                do {
                    do { return try await body(via) } catch TranscriptionError.safetyBlocked {
                        // MEASURED 2026-09-27: the flash model blocked one window of a
                        // call as `content_filter` and passed the same window on the
                        // next run. One more try before moving on.
                        Log.meeting.info("\(label, privacy: .public): \(via.label, privacy: .public) safety block, retrying")
                        return try await body(via)
                    }
                } catch TranscriptionError.rateLimitedTransient(let retryAfter) {
                    Log.meeting.info("\(label, privacy: .public): \(via.label, privacy: .public) rate limited")
                    waits.append(retryAfter ?? 60); lastError = TranscriptionError.rateLimitedTransient(retryAfter: retryAfter)
                } catch let error as TranscriptionError where Self.tryNextProvider(error) {
                    Log.meeting.error("\(label, privacy: .public): \(via.label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    lastError = error
                } catch is DecodingError {
                    Log.meeting.error("\(label, privacy: .public): \(via.label, privacy: .public) returned unreadable segments")
                    lastError = TranscriptionError.network("unreadable_segments")
                }
            }
            guard let wait = waits.min(), wait + 2 <= budget else { throw lastError }
            budget -= wait + 2
            Log.meeting.info("\(label, privacy: .public): waiting \(Int(wait + 2), privacy: .public)s for the rate limit")
            try await sleep(wait + 2)
        }
    }

    /// Speaker-labelled words for audio with no reference clips inside it,
    /// on whichever model the route has for it.
    private func transcribeSpeakers(_ flac: Data, seconds: Double, references: [(id: String, audio: Data)],
                                    via speech: SpeechRoute) async throws -> [DiarizedWord] {
        let via: ModelRoute
        switch speech {
        case .elevenLabs: return try await client.elevenLabsDiarize(audio: flac, audioSeconds: seconds, deadline: 600)
        case .mai(let endpoint):
            return try await UsageMeter.$audioSeconds.withValue(seconds) {
                try await client.maiDiarize(audio: flac, deadline: 600, via: endpoint, style: SettingsStore().maiTranscribeStyle)
            }
        case .sarvam:
            return try await client.sarvamDiarize(audio: flac, audioSeconds: seconds,
                                                  language: SettingsStore().sarvamLanguage, deadline: 600)
        case .model(let route): via = route
        }
        switch (via.provider, via.gateway) {
        case (.gemini, .direct):
            return try await client.transcribeSpeakers(audio: flac, model: models.transcribe, endpoint: endpoint, deadline: 600)
        case (.openAI, .direct):
            return try await client.openAIDiarize(audio: flac, references: references, deadline: 600)
        case (.gemini, _):
            return try await client.transcribeSpeakers(audio: flac, references: references, model: models.flash,
                                                      deadline: 600, via: via.endpoint)
        case (.openAI, _):
            // `ModelRoute.meetingOrder` never picks this route.
            throw TranscriptionError.modelUnavailable(model: "gpt-4o-transcribe-diarize", detail: "not served by \(via.gateway.rawValue)")
        }
    }

    /// Native Gemini, ElevenLabs and MAI: reference clips go inside the audio
    /// and the labels the API gives them name the speakers. Elsewhere:
    /// reference clips go as separate parts and the model answers with the ids.
    private func transcribe(window regions: [ClosedRange<Double>], audio: CallAudio, clips: [(key: String, value: [ClosedRange<Double>])],
                            known: [TimedWord], via speech: SpeechRoute) async throws -> [TimedWord] {
        var request = AssembledAudio()
        if speech.anchorsInAudio {
            for (id, ranges) in clips { try request.appendAnchor(id: id, clips: ranges, from: audio) }
            try request.appendBody(regions, from: audio)
            let raw = try await transcribeSpeakers(try FLACEncoder.encode(samples: request.samples), seconds: request.duration,
                                                   references: [], via: speech)
            return Self.place(raw, audio: request, call: audio, known: known, mapping: SpeakerLinker.link(words: raw, anchors: request.anchors))
        }
        try request.appendBody(regions, from: audio)
        if case .model(let via) = speech, via.provider == .openAI {
            // The diarizing model takes up to four named voice references and
            // labels their segments with those names, so the ids carry over.
            var references: [(id: String, audio: Data)] = []
            for (id, ranges) in Self.openAIReferenceClips(clips) {
                var clip = AssembledAudio()
                try clip.appendBody(ranges, from: audio)
                let limit = Int(GeminiClient.openAIReferenceSeconds.upperBound * TrackAudio.sampleRate)
                guard clip.duration >= GeminiClient.openAIReferenceSeconds.lowerBound else { continue }
                references.append((id, try FLACEncoder.encode(samples: Array(clip.samples.prefix(limit)))))
            }
            let raw = try await transcribeSpeakers(try FLACEncoder.encode(samples: request.samples), seconds: request.duration,
                                                   references: references, via: speech)
            let mapping = Dictionary(uniqueKeysWithValues: references.map { ($0.id, $0.id) })
            return Self.place(raw, audio: request, call: audio, known: known, mapping: mapping)
        }
        var references: [(id: String, audio: Data)] = []
        for (id, ranges) in clips {
            var clip = AssembledAudio()
            try clip.appendBody(ranges, from: audio)
            references.append((id, try FLACEncoder.encode(samples: clip.samples)))
        }
        let raw = try await transcribeSpeakers(try FLACEncoder.encode(samples: request.samples), seconds: request.duration,
                                               references: references, via: speech)
        let ids = Set(clips.map(\.key))
        let mapping = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        return Self.place(raw, audio: request, call: audio, known: known, mapping: mapping)
    }

    /// The owner first, then the speakers with the most reference audio, up
    /// to OpenAI's limit of four.
    static func openAIReferenceClips(_ clips: [(key: String, value: [ClosedRange<Double>])]) -> [(key: String, value: [ClosedRange<Double>])] {
        func seconds(_ ranges: [ClosedRange<Double>]) -> Double { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
        let ranked = clips.sorted { lhs, rhs in
            if (lhs.key == MeetingSpeaker.you) != (rhs.key == MeetingSpeaker.you) { return lhs.key == MeetingSpeaker.you }
            return seconds(lhs.value) > seconds(rhs.value)
        }
        return Array(ranked.prefix(GeminiClient.openAIMaxReferences))
    }

    static func tryNextProvider(_ error: TranscriptionError) -> Bool {
        switch error {
        case .rateLimitedDaily, .modelUnavailable, .safetyBlocked, .badRequest, .network, .timeout, .auth: return true
        case .offline, .emptyTranscript, .rateLimitedTransient: return false
        }
    }
}
