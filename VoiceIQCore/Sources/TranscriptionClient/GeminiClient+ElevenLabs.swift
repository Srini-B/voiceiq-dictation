import Foundation

/// ElevenLabs Scribe v3: speech to text only, used in place of the provider's
/// transcription model when ElevenLabs is the transcription provider
/// (`SettingsStore.transcribesWithElevenLabs`), always on the saved
/// recording after it stops. The provider's writing model still applies the
/// writing rules afterwards.
///
/// From the API reference, the OpenAPI spec and the guides (read 2026-11-12):
///  - Batch: `POST /v1/speech-to-text`, multipart, `xi-api-key` header,
///    `model_id=scribe_v3`. FLAC is accepted. The response is
///    `{text, language_code, words, audio_duration_secs?}`
///    with no usage block, so the call is priced here from the audio length.
///  - `keyterms` repeat once per term. Each is under 50 characters and at
///    most five words, without `< > { } [ ] \`. More than 100 make every
///    request bill at least 20 s, so at most 100 are sent.
///  - `no_verbatim=true` drops fillers and false starts; `numbers_format=digits`
///    (new in v3) writes "42" rather than "forty-two". MEASURED 2026-11-12 on
///    25 s of a real meeting: sent together, `numbers_format` switches
///    `no_verbatim` off ("uh", "um" and repeats come back), while diarization,
///    word timestamps, audio events and keyterms leave it working. So
///    `numbers_format` goes only with word-for-word dictation.
///  - `transcript_edit`, a formatting instruction a model applies to the
///    finished text, is not sent. MEASURED 2026-11-18 on 3–22 s clips, it
///    added 0.3–0.9 s to every request, and the writing model formats anyway.
///  - Errors: `{"detail": {"type", "code", "message"}}` or a list of
///    validation errors; 401 bad key or used-up credit, 402 no credit, 422
///    invalid parameters, 429 rate or concurrency limits.
public enum ElevenLabs {
    public static let batchModel = "scribe_v3"
    static let apiBase = URL(string: "https://api.elevenlabs.io/v1")!

    static let batchKeytermLimit = 100
    static let batchKeytermCharacters = 49
    /// What `SettingsStore.redactsMeetingSecrets` hides in a meeting
    /// transcript (`entity_detection` and `entity_redaction`): card details
    /// (the `pci` category), ID, account and health-card numbers, other
    /// identifiers and numeric personal data (`generic_id`, `numerical_pii`),
    /// and passwords. Names, places, dates and money stay, since the notes need
    /// them. Written as `{CREDIT_CARD}` and the like (`entity_type` mode), in
    /// the text and the words. MEASURED 2026-11-12 on a real meeting with
    /// `name` added: every name came back as `{NAME}`, speakers and word
    /// times intact.
    static let redactedEntities = ["pci", "ssn", "passport_number", "driver_license", "bank_account",
                                   "account_number", "routing_number", "password", "healthcare_number",
                                   "generic_id", "numerical_pii"]

    /// Dictionary terms ElevenLabs will accept, in dictionary order, deduped.
    static func keyterms(_ vocabulary: [String], limit: Int, maxCharacters: Int) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in vocabulary {
            let term = raw.replacingOccurrences(of: #"[<>{}\[\]\\\r\n]"#, with: " ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty, term.count <= maxCharacters,
                  term.split(separator: " ").count <= 5,
                  seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == limit { break }
        }
        return terms
    }

    /// The spoken words of a diarized response, and its audio events
    /// ("(laughter)") with `events`; spacing is dropped.
    static func diarizedWords(_ json: [String: Any], events: Bool = false) -> [DiarizedWord] {
        let words = json["words"] as? [[String: Any]] ?? []
        let kept: Set<String> = events ? ["word", "audio_event"] : ["word"]
        return words.compactMap { word in
            guard kept.contains(word["type"] as? String ?? "word"),
                  let text = (word["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return DiarizedWord(text: text, speaker: word["speaker_id"] as? String,
                                start: (word["start"] as? NSNumber)?.doubleValue,
                                end: (word["end"] as? NSNumber)?.doubleValue)
        }
    }

    /// A segment's redacted text as words, each with the speaker and times of
    /// the heard words it stands for. Only the redacted text is kept, so a
    /// heard word never shows; a placeholder such as {CREDIT_CARD} stands for
    /// the heard words up to the next word both share. The text is matched
    /// word by word from the front, not split on spaces, so Japanese and
    /// other scripts without spaces keep each speaker's words apart.
    static func redacting(_ words: [DiarizedWord], as text: String) -> [DiarizedWord] {
        var out: [DiarizedWord] = [], rest = Substring(text), next = 0
        func trim() { rest = rest.drop(while: \.isWhitespace) }
        func unspaced(_ character: Character) -> Bool {
            character.unicodeScalars.contains(where: ValidationGate.isUnspacedScript)
        }
        /// The heard word at or after `start` (within `limit`) that the text
        /// goes on with, ending where a word can end.
        func resumes(from start: Int, within limit: Int) -> Int? {
            guard start < words.count else { return nil }
            return words[start...].prefix(limit).firstIndex { word in
                guard !word.text.isEmpty, rest.hasPrefix(word.text) else { return false }
                guard let after = rest.dropFirst(word.text.count).first, let last = word.text.last else { return true }
                return after.isWhitespace || after == "{" || unspaced(after) || unspaced(last)
            }
        }
        func append(_ token: String, _ taken: ArraySlice<DiarizedWord>) {
            let base = taken.first ?? out.last ?? words.first
            out.append(DiarizedWord(text: token, speaker: base?.speaker,
                                    start: taken.first?.start ?? base?.end, end: taken.last?.end ?? base?.end))
        }
        trim()
        while !rest.isEmpty {
            if rest.first == "{", rest.contains("}") {
                // Placeholders in a row stand for the heard words up to the
                // one the text resumes with, one word each and the rest to the last.
                var placeholders: [String] = []
                while rest.first == "{", let close = rest.firstIndex(of: "}") {
                    // Punctuation after it ("{CREDIT_CARD}.") is part of the placeholder.
                    let after = rest[rest.index(after: close)...]
                    let end = after.firstIndex { !$0.isPunctuation || $0 == "{" } ?? after.endIndex
                    placeholders.append(String(rest[..<end])); rest = rest[end...]; trim()
                }
                let start = min(next, words.count)
                let end = rest.isEmpty ? words.count
                    : resumes(from: min(start + 1, words.count), within: words.count) ?? min(start + placeholders.count, words.count)
                for (k, placeholder) in placeholders.enumerated() {
                    let lo = min(start + k, end)
                    append(placeholder, words[lo..<(k == placeholders.count - 1 ? end : min(lo + 1, end))])
                }
                next = end
            } else if let found = resumes(from: min(next, words.count), within: 4) {
                append(words[found].text, words[found...found])
                rest = rest.dropFirst(words[found].text.count); next = found + 1; trim()
            } else {
                // A word the heard words do not have: up to the next space or placeholder.
                let token = rest.prefix { !$0.isWhitespace && $0 != "{" }
                let taken = token.isEmpty ? rest.prefix(1) : token
                append(String(taken), []); rest = rest.dropFirst(taken.count); trim()
            }
        }
        return out
    }

    /// What a call costs: the list price for its audio plus each add-on it
    /// used.
    static func usage(model: String, seconds: Double, keyterms: Bool, redacted: Bool = false) -> TokenUsage? {
        guard var usage = TokenUsage.fromAudioMinutes(seconds: seconds, model: model) else { return nil }
        var addOns = 0.0
        if keyterms {
            let addOn: PriceBook.ElevenLabsAddOn = model == LiveMeetingSession.model ? .liveKeyterms : .keyterms
            addOns += seconds * addOn.perHour
        }
        if redacted {
            let addOn: PriceBook.ElevenLabsAddOn = model == LiveMeetingSession.model ? .liveEntityDetection : .entityDetection
            addOns += seconds * addOn.perHour
        }
        usage.reportedCostUSD = (usage.reportedCostUSD ?? 0) + addOns / 3600
        return usage
    }
}

extension GeminiClient {
    /// One dictation to Scribe v3. With `smart`, fillers and false starts are
    /// dropped; the writing model formats the text. `audioSeconds` prices the call when the
    /// response leaves out `audio_duration_secs`. One request whatever the
    /// spoken languages (`MultipartForm.languages` says how they are sent).
    func elevenLabsTranscribe(audio: Data, keyterms vocabulary: [String], languages: [String], smart: Bool,
                              audioSeconds: Double, deadline: TimeInterval) async throws -> String {
        let keyterms = ElevenLabs.keyterms(vocabulary, limit: ElevenLabs.batchKeytermLimit,
                                           maxCharacters: ElevenLabs.batchKeytermCharacters)
        var form = MultipartForm()
        form.field("model_id", ElevenLabs.batchModel)
        form.file("file", filename: "audio.flac", mimeType: "audio/flac", data: audio)
        form.field("tag_audio_events", "false")
        form.field("timestamps_granularity", "none")
        form.field("diarize", "false")
        form.languages(languages)
        // `numbers_format` switches `no_verbatim` off (see the
        // notes on `ElevenLabs`), so digits are asked for only word for word.
        if smart {
            form.field("no_verbatim", "true")
        } else {
            form.field("numbers_format", "digits")
        }
        for term in keyterms { form.field("keyterms", term) }
        let json = try await elevenLabsPost(form, stage: .transcribe, deadline: deadline)
        let seconds = (json["audio_duration_secs"] as? NSNumber)?.doubleValue ?? audioSeconds
        if let usage = ElevenLabs.usage(model: ElevenLabs.batchModel, seconds: seconds,
                                        keyterms: !keyterms.isEmpty) {
            UsageMeter.record(stage: .transcribe, model: ElevenLabs.batchModel, usage: usage)
        }
        return (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Speaker-labelled, word-timed transcript of one meeting window from
    /// Scribe v3. Labels (`speaker_0`, …) are per request, like Gemini's
    /// diarizer, so the caller links them through anchor clips. Without
    /// fillers and false starts (`no_verbatim`), and with sounds such as
    /// "(laughter)" kept as words of whoever made them, for the notes. With
    /// `redact`, the `ElevenLabs.redactedEntities` are hidden.
    func elevenLabsDiarize(audio: Data, keyterms vocabulary: [String], languages: [String], redact: Bool,
                           audioSeconds: Double, deadline: TimeInterval) async throws -> [DiarizedWord] {
        let keyterms = ElevenLabs.keyterms(vocabulary, limit: ElevenLabs.batchKeytermLimit,
                                           maxCharacters: ElevenLabs.batchKeytermCharacters)
        var form = MultipartForm()
        form.field("model_id", ElevenLabs.batchModel)
        form.file("file", filename: "audio.flac", mimeType: "audio/flac", data: audio)
        form.field("tag_audio_events", "true")
        form.field("timestamps_granularity", "word")
        form.field("diarize", "true")
        // Without `numbers_format`, which switches `no_verbatim` off.
        form.field("no_verbatim", "true")
        form.languages(languages)
        for term in keyterms { form.field("keyterms", term) }
        if redact {
            for entity in ElevenLabs.redactedEntities {
                form.field("entity_detection", entity); form.field("entity_redaction", entity)
            }
            form.field("entity_redaction_mode", "entity_type")
        }
        let json: [String: Any]
        do {
            json = try await elevenLabsPost(form, stage: .meetingTranscribe, deadline: deadline)
        } catch TranscriptionError.badRequest(let message) where !keyterms.isEmpty {
            // Fail open, as dictation does: one strange dictionary entry must
            // not cost a meeting its transcript.
            Log.transcription.error("meeting window rejected with keyterms (\(message, privacy: .private)), retrying without them")
            return try await elevenLabsDiarize(audio: audio, keyterms: [], languages: languages, redact: redact,
                                               audioSeconds: audioSeconds, deadline: deadline)
        }
        let seconds = (json["audio_duration_secs"] as? NSNumber)?.doubleValue ?? audioSeconds
        if let usage = ElevenLabs.usage(model: ElevenLabs.batchModel, seconds: seconds,
                                        keyterms: !keyterms.isEmpty, redacted: redact) {
            UsageMeter.record(stage: .meetingTranscribe, model: ElevenLabs.batchModel, usage: usage)
        }
        return ElevenLabs.diarizedWords(json, events: true)
    }

    private func elevenLabsPost(_ form: MultipartForm, stage: UsageStage, deadline: TimeInterval) async throws -> [String: Any] {
        let data = try await post(path: "speech-to-text", body: form.body, endpoint: ElevenLabs.apiBase,
                                  deadline: deadline, modelLabel: ElevenLabs.batchModel, stage: stage,
                                  via: .elevenLabs, extraHeaders: ["Content-Type": form.contentType])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        return json
    }

    /// `GET /v1/user`: 200 for a usable key. A key scoped to speech to text
    /// only is refused this read for a missing permission, which still proves
    /// the key exists, so that answer counts as valid. A bad key answers 401
    /// with `code: unauthorized, status: invalid_api_key` (checked 2026-09-28).
    public func validateElevenLabsKey() async -> KeyCheck {
        var request = URLRequest(url: ElevenLabs.apiBase.appendingPathComponent("user"))
        request.timeoutInterval = 10
        applyAuth(&request, via: .elevenLabs)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200: return .valid
        case 429, 500...599: return .unreachable
        case 401, 403:
            let detail = Self.elevenLabsErrorDetail(from: data)
            if (detail.kinds + [detail.message ?? ""]).contains(where: { $0.lowercased().contains("permission") }) { return .valid }
            return .rejected(detail.message)
        default: return .rejected(Self.elevenLabsErrorDetail(from: data).message)
        }
    }

    /// `detail` is an object (`type`, `code`, the legacy `status`, and
    /// `message`), a string, or FastAPI's list of validation errors.
    static func elevenLabsErrorDetail(from data: Data) -> (kinds: [String], message: String?) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch root?["detail"] {
        case let detail as [String: Any]:
            return (["type", "code", "status"].compactMap { detail[$0] as? String }, detail["message"] as? String)
        case let detail as String:
            return ([], detail)
        case let list as [[String: Any]]:
            return (["invalid_parameters"], list.first?["msg"] as? String)
        default:
            return ([], nil)
        }
    }

    /// `quota_exceeded` (legacy `status`, now `code`) or the `payment_required`
    /// type: the key works, the credit balance does not.
    static func isElevenLabsQuota(_ detail: (kinds: [String], message: String?)) -> Bool {
        detail.kinds.contains { kind in
            let lower = kind.lowercased()
            return lower.contains("quota") || lower.contains("payment") || lower.contains("credit")
        }
    }
}

extension MultipartForm {
    /// The first spoken language is `language_code`; the others go as v3's
    /// `secondary_language_codes`, one field each. MEASURED 2026-11-12:
    /// secondary codes without a `language_code` answer 500
    /// `service_unavailable` every time (en+hi and eng+hin); with one, 200.
    ///
    /// MEASURED 2026-11-13, one request each, English main with Tamil and
    /// Japanese secondary: whole Tamil and Japanese sentences and an
    /// English-Tamil code-switched sentence came back in their own scripts,
    /// but a 2.6 s Japanese phrase by a non-native speaker came back as
    /// English-looking words ("No, Miss, I'm not hasta."). Only
    /// `language_code=jpn` returned the Japanese, and automatic detection
    /// returned romanized words or a run of zeros. With Tamil main, English
    /// speech was written in Tamil script. So the main language decides
    /// ambiguous speech, and no single request covers both; the menu bar's
    /// Spoken Language submenu switches it.
    mutating func languages(_ codes: [String]) {
        guard let first = codes.first else { return }
        field("language_code", first)
        for code in codes.dropFirst() { field("secondary_language_codes", code) }
    }
}
