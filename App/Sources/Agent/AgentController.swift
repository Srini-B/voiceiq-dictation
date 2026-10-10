import AppKit
import Combine
import VoiceIQCore

/// What the agent panel shows besides the transcript.
enum AgentPhase: Equatable {
    /// Open, waiting for the shortcut.
    case idle
    /// The microphone is on.
    case listening
    /// Speech is being transcribed.
    case transcribing
    /// The model is working through a command.
    case thinking
}

/// The panel's view state. One session's transcript and the phase line.
@MainActor
final class AgentPanelModel: ObservableObject {
    @Published var session: AgentSession?
    @Published var phase: AgentPhase = .idle
    /// A transient line under the header: a dictation error, a hint.
    @Published var notice: String?
    /// The question the agent is asking, with its answer slot.
    @Published var pendingConfirmation: (request: String, answer: (AgentConfirmation) -> Void)?

    var isOpen: Bool { session != nil }
}

/// Owns one agent session from the shortcut to Stop. The dictation
/// coordinator still records and transcribes; this receives the transcript
/// and runs the loop.
@MainActor
final class AgentController {
    let panel: AgentPanelModel
    /// The pill panel, hidden while the agent captures the whole screen.
    weak var overlay: AgentOverlay?
    /// Receives each session as it grows and when it ends.
    var onSessionChange: ((AgentSession) -> Void)?
    private var loop: AgentLoop?
    private var executor: NativeExecutor?
    private var turn: Task<Void, Never>?

    init(panel: AgentPanelModel) {
        self.panel = panel
    }

    var isOpen: Bool { panel.isOpen }
    var isBusy: Bool { loop?.isBusy ?? false }
    /// Open with a model to talk to. False when the panel only shows why not.
    var canRun: Bool { loop != nil }

    /// Opens the panel and resolves the endpoint. The session is created
    /// even when no model is set up, so the panel can say so.
    func start() {
        guard loop == nil else { return }
        guard let endpoint = AgentEndpoint.resolve() else {
            panel.session = AgentSession(endpointLabel: "No model", modelID: "", entries: [
                .failure(id: UUID(), text: AgentTransportError.noEndpoint.userMessage),
            ])
            panel.phase = .idle
            return
        }
        let executor = NativeExecutor()
        executor.overlay = overlay
        // The same check Ask Anything makes before offering web context.
        let web = KeychainStore.loadTinyFishKey() != nil ? TinyFishClient(apiKey: { KeychainStore.loadTinyFishKey() }) : nil
        let loop = AgentLoop(endpoint: endpoint, executor: executor, web: web)
        loop.onChange = { [weak self] session in
            self?.panel.session = session
            self?.onSessionChange?(session)
        }
        loop.confirm = { [weak self] request in
            await withCheckedContinuation { continuation in
                guard let self else { return continuation.resume(returning: .notNow) }
                self.panel.pendingConfirmation = (request, { decision in
                    self.panel.pendingConfirmation = nil
                    continuation.resume(returning: decision)
                })
            }
        }
        self.executor = executor
        self.loop = loop
        var session = loop.session
        let missing = NativeExecutor.missingPermissions()
        if !missing.isEmpty {
            session.entries.append(.failure(id: UUID(), text: "\(missing.joined(separator: " and ")) permission is off. Turn it on for VoiceiQ in System Settings → Privacy & Security, then say your command."))
        }
        panel.session = session
        panel.phase = .idle
        panel.notice = nil
        Log.session.info("agent session started on \(endpoint.label, privacy: .public) \(endpoint.modelID, privacy: .public)")
    }

    /// One spoken command. Returns when the turn is over.
    func submit(command: String, originalTranscript: String? = nil) {
        guard let loop else {
            panel.phase = .idle
            return
        }
        panel.phase = .thinking
        turn = Task { @MainActor [weak self] in
            await loop.handle(command: command, originalTranscript: originalTranscript)
            guard let self, self.loop === loop else { return }
            self.panel.phase = .idle
        }
    }

    /// Ends the session. The transcript is gone with it; the spoken
    /// commands stay in History like any dictation.
    func stop() {
        loop?.cancel()
        turn?.cancel()
        panel.pendingConfirmation?.answer(.notNow)
        loop = nil
        executor = nil
        turn = nil
        panel.session = nil
        panel.phase = .idle
        panel.notice = nil
    }

    /// Opens System Settings at the pane for the first missing permission.
    static func openPermissionSettings() {
        let missing = NativeExecutor.missingPermissions()
        let anchor = missing.first == "Accessibility" ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

extension Notification.Name {
    /// The agent panel's Stop, or Esc while it is open.
    static let agentStopRequested = Notification.Name("io.blue.voiceiq.agent.stop")
    /// The agent panel's microphone button: start or end listening.
    static let agentListenTapped = Notification.Name("io.blue.voiceiq.agent.listen")
}
