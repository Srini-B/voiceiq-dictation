import Foundation

/// One live transcription session over one WebSocket.
///
/// The shape is dictated by two hard constraints:
///
/// 1. **The audio write queue must never wait for this.** `enqueue` is
///    `nonisolated`, takes no lock the socket holds, and cannot await. It appends
///    to a ring and signals; that is all.
///
/// 2. **The end of a turn must never overtake the audio in front of it.** The
///    server finalizes on what it has received, so an end signal that jumps the
///    queue silently truncates the user's last words. Control items therefore
///    travel *in band*, through the same channel as the audio wakeups, and the
///    send loop drains the ring completely before it acts on one.
///
/// A session runs once: `start`, then `finish` or `abort`. Once aborted it never
/// opens a socket or starts its pumps, whatever point the handshake had reached.
public actor LiveTranscriptionSession {

    private enum Command: Sendable {
        case pcmAvailable
        case endActivity
    }

    private enum Phase {
        case idle, starting, streaming, finishing, closed
    }

    private var transport: LiveTransport
    private let transportFactory: (@Sendable () -> LiveTransport)?
    private let renewAfter: TimeInterval
    private let onFailure: @Sendable (LiveFailure) -> Void
    private var renewAt = Date.distantFuture
    private var connectionGeneration = 0
    private var completedConnections: [String] = []
    private let dialect: LiveDialect
    public let ring: PCMRing

    private let commands: AsyncStream<Command>
    private let commandSink: AsyncStream<Command>.Continuation
    public nonisolated let partials: AsyncStream<String>
    private let partialSink: AsyncStream<String>.Continuation
    private var previewTail = ""
    private var previewItemID: String?

    private var sendLoop: Task<Void, Never>?
    private var receiveLoop: Task<Void, Never>?

    private var phase = Phase.idle
    /// Set by the setup watchdog, so `start` reports a timeout, not the
    /// aborted socket the watchdog left behind.
    private var handshakeExpired = false
    private var ledger = LiveTurnLedger()
    /// `ring.acceptedBytes` when the server last said anything about the audio.
    /// The gap between this and the bytes sent since is how far the transcript
    /// lags the recording; past `stallSeconds` the stream is not trustworthy.
    private var acceptedAtLastTranscript: Int64 = 0
    private var bytesSinceActivityStart = 0
    /// Turns the client has closed. `finish` waits until every one of them is
    /// finished, not just until some final exists.
    private var turnsEnded = 0
    /// The largest usage the server reported; a later frame supersedes an
    /// earlier one for the same turn, so the largest total wins.
    private var reportedUsage: TokenUsage?
    private var usageRecorded = false
    private var failure: String?
    private var activityEndFlushed = false

    /// A Gemini Live session.
    public init(transport: LiveTransport, setup: LiveSetup, ring: PCMRing = PCMRing()) {
        self.init(transport: transport, dialect: GeminiLiveDialect(setup: setup), ring: ring)
    }

    public init(transport: LiveTransport, dialect: LiveDialect, ring: PCMRing = PCMRing(),
                transportFactory: (@Sendable () -> LiveTransport)? = nil,
                renewAfter: TimeInterval = .infinity,
                onFailure: @escaping @Sendable (LiveFailure) -> Void = { _ in }) {
        self.transport = transport
        self.transportFactory = transportFactory
        self.renewAfter = renewAfter
        self.onFailure = onFailure
        self.dialect = dialect
        self.ring = ring
        // Control items must never be dropped, so this stream is unbounded — it
        // carries wakeups, not audio. The audio is in the ring, which is the
        // only thing with a drop policy.
        (self.commands, self.commandSink) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        (self.partials, self.partialSink) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Called from the audio write queue. Must not block, must not await.
    public nonisolated func enqueue(_ pcm: Data) {
        ring.append(pcm)
        commandSink.yield(.pcmAvailable)
    }

    /// Bytes the socket accepted, for reconciliation against `framesWritten * 2`.
    public var acceptedBytes: Int64 { ring.acceptedBytes }

    // MARK: - Start

    /// Connects, handshakes, and opens the pumps. Throws if the socket or the
    /// credential is refused, the handshake outlasts `setupTimeout`, or the
    /// session is aborted meanwhile — the caller falls back to the batch path.
    /// Audio enqueued during the handshake waits in the ring.
    ///
    /// The timeout closes the socket rather than racing it. A child task cannot
    /// bound a `receive` that ignores cancellation: the task group waits for it
    /// anyway, and a socket that connected and then said nothing would hold the
    /// fallback for the transport's own 30 s timeout.
    public func start(setupTimeout: TimeInterval = 5.0, startPumps: Bool = true) async throws {
        guard phase == .idle else { throw LiveError.aborted }
        phase = .starting
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, setupTimeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expireHandshake()
        }
        defer { watchdog.cancel() }
        let transport = self.transport
        do {
            try await withTaskCancellationHandler {
                try await self.handshake(startPumps: startPumps)
            } onCancel: {
                transport.close()
            }
        } catch {
            let reported: Error
            if handshakeExpired {
                reported = LiveError.setupTimedOut
            } else if phase == .closed || Task.isCancelled {
                reported = LiveError.aborted
            } else {
                reported = error
            }
            if reported as? LiveError != .aborted { recordFailure(reported) }
            close()
            throw reported
        }
    }

    private func handshake(startPumps: Bool) async throws {
        try ensureStarting()
        try await transport.connect()
        try ensureStarting()
        if let setup = dialect.setupFrame() {
            try await transport.send(setup)
            try ensureStarting()
        }
        var ready = false
        while !ready {
            let frame = try await transport.receive()
            try ensureStarting()
            if let usage = dialect.reportedUsage(in: frame) { noteUsage(usage) }
            for event in dialect.decode(frame) {
                switch event {
                case .setupComplete: ready = true
                case .failed(let why): throw why
                case .goAway: throw LiveError.refused("server sent goAway during setup")
                default: continue
                }
            }
        }
        if let start = dialect.activityStartFrame() {
            try await transport.send(start)
            try ensureStarting()
        }
        // No await between this check and the pumps: an abort cannot slip in.
        phase = .streaming
        renewAt = renewAfter.isFinite ? Date().addingTimeInterval(renewAfter) : .distantFuture
        let generation = connectionGeneration
        receiveLoop = Task { [weak self] in await self?.runReceiveLoop(generation: generation) }
        if startPumps { sendLoop = Task { [weak self] in await self?.runSendLoop() } }
    }

    private func ensureStarting() throws {
        if handshakeExpired { throw LiveError.setupTimedOut }
        if phase != .starting || Task.isCancelled { throw LiveError.aborted }
    }

    private func expireHandshake() {
        guard phase == .starting else { return }
        handshakeExpired = true
        transport.close()
    }

    // MARK: - Pumps

    private func runSendLoop() async {
        for await command in commands {
            if phase == .closed || failure != nil { return }
            let isEnding = (command == .endActivity)
            // Coalesce into >=100 ms frames while streaming, and flush every
            // remaining byte before the end of the turn so it never overtakes
            // the audio in front of it.
            for chunk in ring.drainCoalesced(flushAll: isEnding) {
                do {
                    try await transport.send(dialect.audioFrame(chunk))
                } catch {
                    recordFailure(error)
                    return
                }
                ring.markAccepted(chunk.count)
                bytesSinceActivityStart += chunk.count
                if !isEnding, bytesSinceActivityStart >= dialect.minimumTurnBytes,
                   Date() >= renewAt || Self.shouldRollActivity(bytesSinceStart: bytesSinceActivityStart, chunk: chunk,
                                                      limits: dialect.activityRoll) {
                    // Chunks already drained keep flowing into the new turn.
                    do { try await rollActivity() } catch {
                        recordFailure(error)
                        return
                    }
                }
            }
            if isEnding {
                await endLastTurn()
                return
            }
        }
    }

    /// Ends the open turn, if it holds any audio. An empty turn — a roll just
    /// before the key came up, or a session that heard nothing — has nothing
    /// to end: OpenAI refuses an empty commit and Gemini would never finish it.
    /// A turn shorter than the API's minimum is padded with silence rather
    /// than refused, so its words are not lost.
    private func endLastTurn() async {
        defer { activityEndFlushed = true }
        guard bytesSinceActivityStart > 0 else { return }
        do {
            let shortfall = dialect.minimumTurnBytes - bytesSinceActivityStart
            if shortfall > 0 { try await transport.send(dialect.audioFrame(Data(count: shortfall))) }
            if let tail = dialect.audioTailFrame() { try await transport.send(tail) }
            // Counted before the send, so the server's answer can never arrive
            // for a turn the ledger does not know is closed.
            turnsEnded += 1
            try await transport.send(dialect.activityEndFrame())
        } catch {
            recordFailure(error)
        }
    }

    /// Closes the current turn and opens the next one.
    ///
    /// MEASURED 2026-09-27 (Gemini): sending `activityStart` in the same breath
    /// as `activityEnd` made the server drop the turn it was closing. It needs to
    /// finish the old turn (about a second) before a new one opens. Audio keeps
    /// landing in the ring during the wait, so nothing is lost.
    private func rollActivity() async throws {
        let closing = turnsEnded
        let seconds = bytesSinceActivityStart / PCMRing.bytesPerSecond
        if let tail = dialect.audioTailFrame() { try await transport.send(tail) }
        turnsEnded += 1
        try await transport.send(dialect.activityEndFrame())
        bytesSinceActivityStart = 0
        let renewing = Date() >= renewAt && transportFactory != nil
        if dialect.waitsForTurnCloseOnRoll || renewing {
            let count = turnsEnded
            await wait(seconds: Self.turnCloseWaitSeconds) { $0.isComplete(turns: count) }
            guard ledger.isComplete(turns: count), failure == nil else {
                throw LiveError.refused("previous turn did not finish before rollover")
            }
        }
        if phase == .closed { throw LiveError.aborted }
        Log.transcription.debug("live: rolled turn \(closing) after \(seconds)s, finished=\(self.ledger.isFinished(turn: closing))")
        if renewing, phase == .streaming, let transportFactory {
            completedConnections.append(ledger.transcript)
            ledger = LiveTurnLedger()
            turnsEnded = 0
            reportedUsage = nil
            connectionGeneration += 1
            receiveLoop?.cancel()
            transport.close()
            transport = transportFactory()
            phase = .idle
            handshakeExpired = false
            try await start(startPumps: false)
            Log.transcription.notice("live connection renewed after completed turns")
            return
        }
        if let start = dialect.activityStartFrame() { try await transport.send(start) }
    }

    private func runReceiveLoop(generation: Int) async {
        while phase != .closed, generation == connectionGeneration {
            let frame: Data
            do {
                frame = try await transport.receive()
            } catch {
                if phase != .closed, generation == connectionGeneration { recordFailure(error) }
                return
            }
            if phase == .closed || generation != connectionGeneration { return }
            if let usage = dialect.reportedUsage(in: frame) { noteUsage(usage) }
            let events = dialect.decode(frame)
            Log.transcription.debug("live frame: \(Self.describe(events, frame: frame), privacy: .public)")
            for event in events {
                switch event {
                case .setupComplete:
                    continue
                case .partial(let text):
                    partialSink.yield(String((previewTail + " " + text).suffix(512)))
                    noteTranscriptActivity()
                case .itemDelta(let itemID, let text):
                    if previewItemID != itemID { previewTail = ""; previewItemID = itemID }
                    previewTail = String((previewTail + text).suffix(512))
                    partialSink.yield(previewTail)
                    noteTranscriptActivity()
                case .final(let text):
                    ledger.applyFinal(text)
                    previewTail = String((previewTail + " " + text).suffix(512))
                    partialSink.yield(previewTail)
                    noteTranscriptActivity()
                case .turnComplete:
                    ledger.applyTurnComplete(closedTurns: turnsEnded)
                case .committed(let itemID):
                    ledger.applyCommitted(itemID: itemID)
                case .itemFinal(let itemID, let text):
                    ledger.applyItemFinal(itemID: itemID, text: text)
                    if previewItemID == nil || previewItemID == itemID {
                        previewItemID = itemID
                        previewTail = String(text.suffix(512))
                        partialSink.yield(previewTail)
                    }
                    noteTranscriptActivity()
                case .goAway:
                    renewAt = .distantPast
                case .failed(let why):
                    recordFailure(why)
                    return
                }
            }
        }
    }

    private func noteTranscriptActivity() {
        acceptedAtLastTranscript = ring.acceptedBytes
    }

    private func recordFailure(_ error: Error) {
        guard failure == nil, phase != .closed, !Task.isCancelled else { return }
        failure = String(describing: error)
        onFailure(error as? LiveFailure ?? LiveFailure(message: String(describing: error)))
        partialSink.yield("")
        partialSink.finish()
        transport.close()
        commandSink.finish()
    }

    /// Polls `done` against the ledger until it holds, the session fails or
    /// closes, or `seconds` pass.
    private func wait(seconds: TimeInterval, until done: (LiveTurnLedger) -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(ledger), failure == nil, phase != .closed, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Event kinds and sizes for the debug log; the raw keys when nothing decoded.
    private static func describe(_ events: [LiveEvent], frame: Data) -> String {
        guard !events.isEmpty else {
            let root = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any]
            let type = root?["type"] as? String
            return "undecoded type=\(type ?? "-") keys=\(root?.keys.sorted().joined(separator: ",") ?? "?")"
        }
        return events.map {
            switch $0 {
            case .partial(let t): return "partial(\(t.count))"
            case .itemDelta(_, let t): return "delta(\(t.count))"
            case .final(let t): return "final(\(t.count))"
            case .turnComplete: return "turnComplete"
            case .committed: return "committed"
            case .itemFinal(_, let t): return "itemFinal(\(t.count))"
            case .goAway: return "goAway"
            case .failed(let w): return "failed(\(w))"
            case .setupComplete: return "setupComplete"
            }
        }.joined(separator: "+")
    }

    // MARK: - Activity rollover

    /// One activity is one server-side turn, and the server stops transcribing a
    /// turn that runs long: measured 2026-09-27, a seven-minute dictation held in
    /// a single Gemini activity produced a final covering only the first half of
    /// the words. Closing the turn every minute or so keeps every minute inside
    /// the range the server transcribes. The cut lands on a quiet frame when one
    /// comes along, so a word is rarely split; a talker who never pauses is cut
    /// anyway at the hard limit.
    static let activityRollSeconds = 60
    static let activityHardLimitSeconds = 90
    /// How long a roll waits for the server to finish the closed turn before
    /// opening the next. Measured at about one second.
    static let turnCloseWaitSeconds: TimeInterval = 2.5
    /// How long `finish` waits for the send loop to flush the end of the last
    /// turn. Covers a roll in progress plus a short backlog.
    static let flushWaitSeconds: TimeInterval = 2.0 + turnCloseWaitSeconds
    /// Below this RMS (int16 scale) a 100 ms frame is treated as a pause.
    static let quietFrameRMS = 400.0

    static func shouldRollActivity(bytesSinceStart: Int, chunk: Data, limits: (roll: Int, hardLimit: Int)) -> Bool {
        let seconds = bytesSinceStart / PCMRing.bytesPerSecond
        if seconds >= limits.hardLimit { return true }
        guard seconds >= limits.roll else { return false }
        return rms(chunk) < quietFrameRMS
    }

    static func rms(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        let sum = pcm.withUnsafeBytes { raw -> Double in
            var acc = 0.0
            for i in 0..<count {
                let v = Double(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                acc += v * v
            }
            return acc
        }
        return (sum / Double(count)).squareRoot()
    }

    /// Audio the server accepted after its last word. A stream whose transcript
    /// stopped this far before the recording did is missing speech, whatever
    /// the byte reconciliation says, so the upload path takes over.
    static let stallSeconds = 120

    private var transcriptStalledSeconds: Int? {
        let lag = Int(ring.acceptedBytes - acceptedAtLastTranscript) / PCMRing.bytesPerSecond
        return lag >= Self.stallSeconds ? lag : nil
    }

    // MARK: - Usage

    private func noteUsage(_ usage: TokenUsage) {
        if let current = reportedUsage, current.totalIn + current.totalOut >= usage.totalIn + usage.totalOut { return }
        reportedUsage = usage
    }

    /// Books this session against the caller's `UsageMeter.scope`, from what
    /// the server reported or, without that, the bytes sent and text received.
    private func recordUsage(outputText: String) {
        guard !usageRecorded else { return }
        usageRecorded = true
        guard ring.acceptedBytes > 0 || reportedUsage != nil else { return }
        // Turn reports are not session totals. Estimate multi-turn audio from
        // all accepted frames rather than charging only the largest turn.
        let usage = dialect.usage(reported: turnsEnded > 1 || !completedConnections.isEmpty ? nil : reportedUsage,
                                  audioSeconds: Double(ring.acceptedBytes) / Double(PCMRing.bytesPerSecond),
                                  outputCharacters: outputText.count)
        UsageMeter.record(stage: .liveTranscribe, model: dialect.model, usage: usage)
    }

    // MARK: - Finish and abort

    /// Ends the last turn and waits for the server's last word: up to
    /// `flushWaitSeconds` for the end to go out behind the audio, then up to
    /// `deadline` for every ended turn's final.
    ///
    /// Called only after `AudioCaptureEngine.stop()` has returned, because audio
    /// keeps arriving through the tail drain — key-up is not the end of speech.
    public func finish(deadline: TimeInterval = 6.0) async -> LiveOutcome {
        guard phase == .streaming else {
            let why = phase == .closed ? "session was aborted" : "setup never completed"
            close()
            recordUsage(outputText: transcript)
            return .unusable(why)
        }
        phase = .finishing
        commandSink.yield(.endActivity)
        commandSink.finish()

        if failure == nil {
            let flushDeadline = Date().addingTimeInterval(Self.flushWaitSeconds)
            while !activityEndFlushed, failure == nil, phase != .closed, !Task.isCancelled, Date() < flushDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if activityEndFlushed {
                let turns = turnsEnded
                await wait(seconds: deadline) { $0.isComplete(turns: turns) }
            }
        }
        let aborted = phase == .closed
        let flushed = activityEndFlushed
        let complete = ledger.isComplete(turns: turnsEnded)
        close()
        let transcript = self.transcript
        recordUsage(outputText: transcript)

        if aborted || Task.isCancelled { return .unusable("session was aborted") }
        if let failure { return .unusable(failure) }
        guard flushed else { return .unusable("end of turn never flushed") }
        if ring.didDrop { return .unusable("dropped \(ring.droppedChunks) chunks — stream is truncated") }
        guard complete else { return .unusable("not every turn had a final before the deadline (\(turnsEnded) ended)") }
        if let lag = transcriptStalledSeconds {
            return .unusable("transcript stalled \(lag)s before the recording ended — stream is truncated")
        }
        Log.transcription.info("live finish: \(self.turnsEnded) turns, \(self.ledger.finalCount) finals, \(transcript.count) chars over \(Int(self.ring.acceptedBytes) / PCMRing.bytesPerSecond)s")
        guard !transcript.isEmpty else { return .silent }
        return .completed(transcript)
    }

    /// Tear down without waiting. Idempotent — every path that abandons a session
    /// calls this, including several that run before `start` completed. An
    /// abort during the handshake closes the socket, and `start` then throws
    /// `LiveError.aborted` without starting the pumps.
    public func abort() {
        close()
        recordUsage(outputText: transcript)
    }

    private var transcript: String {
        (completedConnections + [ledger.transcript]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func close() {
        guard phase != .closed else { return }
        phase = .closed
        sendLoop?.cancel()
        receiveLoop?.cancel()
        partialSink.finish()
        commandSink.finish()
        transport.close()
    }
}
