import Foundation

/// What the user chose when the agent asked before a risky step.
public enum AgentConfirmation: Sendable {
    case once
    case alwaysThisSession
    case notNow
}

/// One session's observe → think → act loop. Owns the transcript and the
/// model's context, which are the same append-only list seen two ways.
/// The UI reads `session` after every `onChange`; the executor touches
/// the Mac; the transport talks to the host.
@MainActor
public final class AgentLoop {
    public private(set) var session: AgentSession
    public private(set) var isBusy = false
    /// Fires after every transcript change, on the main actor.
    public var onChange: ((AgentSession) -> Void)?
    /// Asked before a risky step. Nil declines.
    public var confirm: ((String) async -> AgentConfirmation)?

    /// Steps per spoken command. A long form takes a dozen; past this the
    /// model is usually looping.
    public static let maxSteps = 25

    private let transport: AgentTransport
    private let executor: ActionExecutor
    /// Web search and page reading, when the user has a TinyFish key.
    private let web: TinyFishClient?
    private var conversation: AgentConversation
    private var riskyApprovedForSession = false
    private var turn: Task<Void, Never>?

    /// Longest `wait`, in seconds. A page that takes longer gets another wait.
    static let maxWaitSeconds = 5.0
    /// Characters of a fetched page the model reads; the same cap as Ask Anything.
    static let pageCharacterLimit = WebContext.perPageLimit

    public init(endpoint: AgentEndpoint, executor: ActionExecutor, web: TinyFishClient? = nil, transport: AgentTransport? = nil) {
        self.transport = transport ?? AgentTransport(endpoint: endpoint)
        self.executor = executor
        self.web = web
        self.session = AgentSession(endpointLabel: endpoint.label, modelID: endpoint.modelID)
        self.conversation = AgentConversation(system: AgentPrompt.system, tools: AgentTool.available(web: web != nil))
    }

    /// Run one spoken command to its end. Returns when the turn ends, is
    /// cancelled, or fails. A command spoken while a turn runs waits.
    public func handle(command: String, originalTranscript: String? = nil) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = await turn?.value
        let scope = UsageScope(activity: .agent, sessionID: session.id.uuidString)
        let task = Task { @MainActor in
            await UsageMeter.$scope.withValue(scope) { await self.runTurn(command: trimmed, originalTranscript: originalTranscript) }
        }
        turn = task
        await task.value
        if turn == task { turn = nil }
    }

    /// Stop the running turn. The transcript keeps what happened so far.
    public func cancel() {
        turn?.cancel()
    }

    // MARK: - Turn

    private func runTurn(command: String, originalTranscript: String?) async {
        isBusy = true
        defer { isBusy = false; notify() }
        append(.command(id: UUID(), text: command, at: Date()))

        let observation = await executor.observe()
        append(.observation(id: UUID(), summary: observation.summary))
        conversation.append(.user(Self.content(command: command, originalTranscript: originalTranscript, observation: observation)))

        var steps = 0
        while steps < Self.maxSteps, !Task.isCancelled {
            steps += 1
            let reply: AgentReply
            do {
                reply = try await transport.send(conversation)
            } catch let error as AgentTransportError {
                append(.failure(id: UUID(), text: error.userMessage))
                return
            } catch is CancellationError {
                return
            } catch {
                append(.failure(id: UUID(), text: "Couldn't reach the model host (\(error.localizedDescription))."))
                return
            }
            if Task.isCancelled { return }
            conversation.append(reply.asMessage)

            if reply.toolCalls.isEmpty {
                guard let text = reply.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    append(.failure(id: UUID(), text: "The model returned nothing."))
                    return
                }
                append(.answer(id: UUID(), text: text))
                return
            }
            // Prose next to an answer/done call is the same answer said twice
            // (Claude writes it out, then calls the tool); only the call is shown.
            let delivers = reply.toolCalls.contains { $0.name == AgentTool.answer.rawValue || $0.name == AgentTool.done.rawValue }
            if !delivers, let text = reply.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                append(.thought(id: UUID(), text: text))
            }
            for call in reply.toolCalls {
                if await execute(call) { return }
                if Task.isCancelled { return }
            }
        }
        if !Task.isCancelled {
            append(.failure(id: UUID(), text: "Stopped after \(Self.maxSteps) steps without finishing. Say the command again or break it into smaller steps."))
        }
    }

    /// Runs one call and records its result. True when the turn is over.
    private func execute(_ call: AgentToolCall) async -> Bool {
        guard let tool = AgentTool(rawValue: call.name), conversation.tools.contains(tool) else {
            conversation.append(.toolResult(callID: call.id, name: call.name, content: [.text("Unknown tool \(call.name). Use one of: \(conversation.tools.map(\.rawValue).joined(separator: ", ")).")]))
            return false
        }
        switch tool {
        case .answer:
            let text = call.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            append(.answer(id: UUID(), text: text.isEmpty ? "(no answer)" : text))
            conversation.append(.toolResult(callID: call.id, name: call.name, content: [.text("Delivered to the user.")]))
            return true
        case .done:
            let text = call.string("summary")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            append(.answer(id: UUID(), text: text.isEmpty ? "Done." : text))
            conversation.append(.toolResult(callID: call.id, name: call.name, content: [.text("Delivered to the user.")]))
            return true
        case .observe:
            let observation = await executor.observe()
            append(.observation(id: UUID(), summary: observation.summary))
            conversation.append(.toolResult(callID: call.id, name: call.name, content: Self.content(observation: observation)))
            return false
        case .wait:
            let seconds = min(Self.maxWaitSeconds, max(1, call.arguments["seconds"]?.doubleValue ?? 2))
            let entryID = UUID()
            append(.action(id: entryID, call: call, summary: "Wait \(Int(seconds.rounded())) s", status: .running))
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return true }
            replace(id: entryID, with: .action(id: entryID, call: call, summary: "Wait \(Int(seconds.rounded())) s", status: .done))
            let observation = await executor.observe()
            append(.observation(id: UUID(), summary: observation.summary))
            conversation.append(.toolResult(callID: call.id, name: call.name, content: [.text("Waited \(Int(seconds.rounded())) s.")] + Self.content(observation: observation)))
            return false
        case .webSearch, .fetchPage:
            await performWeb(call, tool: tool)
            return false
        case .click, .clickAt, .type, .press, .scroll, .invokeMenu, .openApp:
            await performAction(call, tool: tool)
            return false
        }
    }

    /// Search or read a page through TinyFish. The result is text only; the
    /// screen has not changed, so no observation follows.
    private func performWeb(_ call: AgentToolCall, tool: AgentTool) async {
        let summary = tool == .webSearch
            ? "Search the web for \"\(call.string("query") ?? "")\""
            : "Read \(call.string("url") ?? "a page")"
        let entryID = UUID()
        append(.action(id: entryID, call: call, summary: summary, status: .running))
        guard let web else {
            replace(id: entryID, with: .action(id: entryID, call: call, summary: summary, status: .failed("No web key.")))
            conversation.append(.toolResult(callID: call.id, name: call.name, content: [.text("Failed: web access is not set up.")]))
            return
        }
        do {
            let text: String
            if tool == .webSearch {
                guard let query = call.string("query"), !query.isEmpty else { throw AgentWebError.missingArgument("query") }
                let recent = call.bool("recent") == true
                let results = try await web.search(query, recencyMinutes: recent ? WebContext.recentWindowMinutes : nil)
                text = results.isEmpty ? "No results." : results.prefix(8).map { "\($0.title)\n\($0.url)\n\($0.snippet)" }.joined(separator: "\n\n")
            } else {
                guard let url = call.string("url"), !url.isEmpty else { throw AgentWebError.missingArgument("url") }
                guard let page = try await web.fetch([url]).first else { throw AgentWebError.emptyPage }
                text = "\(page.title)\n\(String(page.text.prefix(Self.pageCharacterLimit)))"
            }
            replace(id: entryID, with: .action(id: entryID, call: call, summary: summary, status: .done))
            conversation.append(.toolResult(callID: call.id, name: call.name, content: [.text(text)]))
        } catch is CancellationError {
            replace(id: entryID, with: .action(id: entryID, call: call, summary: summary, status: .failed("Stopped.")))
        } catch {
            let reason = AgentWebError.describe(error)
            replace(id: entryID, with: .action(id: entryID, call: call, summary: summary, status: .failed(reason)))
            conversation.append(.toolResult(callID: call.id, name: call.name, content: [.text("Failed: \(reason)")]))
        }
    }

    private func performAction(_ call: AgentToolCall, tool: AgentTool) async {
        let summary = executor.describe(call)
        let entryID = UUID()
        append(.action(id: entryID, call: call, summary: summary, status: .running))

        var outcome = await executor.perform(call, approved: riskyApprovedForSession)
        if case .needsConfirmation(let request) = outcome {
            let confirmationID = UUID()
            append(.confirmation(id: confirmationID, request: request, allowed: nil))
            let decision = await confirm?(request) ?? .notNow
            if decision == .alwaysThisSession { riskyApprovedForSession = true }
            let allowed = decision != .notNow
            replace(id: confirmationID, with: .confirmation(id: confirmationID, request: request, allowed: allowed))
            outcome = allowed ? await executor.perform(call, approved: true) : .failed("The user did not allow this step.")
            if !allowed {
                replace(id: entryID, with: .action(id: entryID, call: call, summary: summary, status: .declined))
                conversation.append(.toolResult(callID: call.id, name: call.name, content: [.text("The user declined this step. Do not retry it; explain with answer if the task cannot continue.")]))
                return
            }
        }

        switch outcome {
        case .done(let result):
            replace(id: entryID, with: .action(id: entryID, call: call, summary: summary, status: .done))
            var content: [AgentContent] = [.text(result)]
            if tool.changesState {
                let observation = await executor.observe()
                append(.observation(id: UUID(), summary: observation.summary))
                content += Self.content(observation: observation)
            }
            conversation.append(.toolResult(callID: call.id, name: call.name, content: content))
        case .failed(let reason):
            replace(id: entryID, with: .action(id: entryID, call: call, summary: summary, status: .failed(reason)))
            conversation.append(.toolResult(callID: call.id, name: call.name, content: [.text("Failed: \(reason)")]))
        case .needsConfirmation(let request):
            // Approved and still asking: treat as a refusal rather than loop.
            replace(id: entryID, with: .action(id: entryID, call: call, summary: summary, status: .failed(request)))
            conversation.append(.toolResult(callID: call.id, name: call.name, content: [.text("Failed: \(request)")]))
        }
    }

    // MARK: - Content

    private static func content(command: String, originalTranscript: String?, observation: AgentObservation) -> [AgentContent] {
        let original = originalTranscript.flatMap { $0 == command ? nil : "\nOriginal speech recognition: \($0)\nThe command above includes local normalization and dictionary corrections. Compare both using sentence context; neither is guaranteed correct." } ?? ""
        return [.text("User command: \(command)\(original)")] + content(observation: observation)
    }

    private static func content(observation: AgentObservation) -> [AgentContent] {
        var parts: [AgentContent] = [.text("Observation:\n\(observation.modelText)")]
        if let image = observation.image {
            parts.append(.image(data: image, mimeType: observation.imageMIMEType))
        }
        return parts
    }

    // MARK: - Transcript

    private func append(_ entry: AgentEntry) {
        session.entries.append(entry)
        notify()
    }

    private func replace(id: UUID, with entry: AgentEntry) {
        guard let index = session.entries.firstIndex(where: { $0.id == id }) else { return }
        session.entries[index] = entry
        notify()
    }

    private func notify() {
        onChange?(session)
    }
}

/// Why a web tool failed, in the model's and the transcript's words.
enum AgentWebError: Error {
    case missingArgument(String)
    case emptyPage

    static func describe(_ error: Error) -> String {
        switch error {
        case AgentWebError.missingArgument(let name): return "\(name) is required."
        case AgentWebError.emptyPage: return "The page had no readable text."
        case TinyFishClient.Failure.missingKey: return "No TinyFish key."
        case TinyFishClient.Failure.unauthorized: return "The TinyFish key was refused."
        case TinyFishClient.Failure.noSearchAccess: return "The TinyFish account has no Search access."
        case TinyFishClient.Failure.rateLimited: return "TinyFish rate limit reached; try again in a moment."
        case TinyFishClient.Failure.http(let code): return "TinyFish returned HTTP \(code)."
        case TinyFishClient.Failure.unparseable: return "TinyFish returned an unreadable response."
        default: return error.localizedDescription
        }
    }
}
