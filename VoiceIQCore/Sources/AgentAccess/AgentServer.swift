#if os(macOS)
import Foundation
import Network
import os
import Security

public extension Notification.Name {
    /// Posted on the main thread when `AgentServer.shared.state` changes.
    static let gtAgentServerStateDidChange = Notification.Name("io.blue.voiceiq.agent-server-state")
}

/// Serves `AgentAPI` on 127.0.0.1 while Settings › Advanced › Coding agents
/// is on, and only then. It follows the setting and the access key as they
/// change, so turning it off closes the port at once.
public final class AgentServer: @unchecked Sendable {
    public static let shared = AgentServer()

    public enum State: Equatable, Sendable {
        case off
        case starting
        case listening
        case failed(String)
    }

    public var state: State { stateLock.withLock { $0 } }

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: .off)
    private let queue = DispatchQueue(label: "io.blue.voiceiq.agent-server")
    private var listener: NWListener?
    private var api: AgentAPI?
    private var history: HistoryStore?
    private var observer: NSObjectProtocol?

    /// Starts serving if the setting is on, then follows it. Call once at launch.
    public func followSettings() {
        observer = NotificationCenter.default.addObserver(forName: .gtSettingDidChange, object: nil, queue: nil) { [weak self] note in
            guard let key = note.object as? String, key == "agentAccessEnabled" || key == KeychainStore.Secret.agentAccess.settingKey else { return }
            self?.queue.async { self?.apply() }
        }
        queue.async { self.apply() }
    }

    /// Read from the Keychain once per launch: a Keychain read can wait on a
    /// password prompt, and the switch and the copy buttons both need the key.
    private static let cachedKey = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The key agents send, made the first time anyone asks for it.
    public static func accessKey() -> String? {
        if let key = cachedKey.withLock({ $0 }) { return key }
        if let key = KeychainStore.loadAgentAccessKey() {
            cachedKey.withLock { $0 = key }
            return key
        }
        return resetAccessKey()
    }

    /// Replaces the key, so agents set up with the old one lose access.
    @discardableResult
    public static func resetAccessKey() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let key = "viq_" + bytes.map { String(format: "%02x", $0) }.joined()
        guard KeychainStore.saveAgentAccessKey(key) else { return nil }
        cachedKey.withLock { $0 = key }
        return key
    }

    /// `attempt` counts retries while the port is still held, as it is for a
    /// moment by the copy of VoiceiQ that an update or a relaunch replaces.
    private func apply(attempt: Int = 0) {
        stop()
        guard SettingsStore().agentAccessEnabled else { return set(.off) }
        set(.starting)
        guard let key = Self.accessKey() else { return set(.failed("The access key could not be saved to the Keychain.")) }
        if history == nil { history = try? HistoryStore.standard() }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        api = AgentAPI(key: key, library: AgentLibrary(history: history, meetings: MeetingStore()), version: version)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: AgentAPI.port)!)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    Log.session.info("agent access listening on 127.0.0.1:\(AgentAPI.port)")
                    self.set(.listening)
                case .failed(let error) where error == .posix(.EADDRINUSE) && attempt < 15:
                    self.stop(keepState: true)
                    self.queue.asyncAfter(deadline: .now() + 2) { if self.listener == nil { self.apply(attempt: attempt + 1) } }
                case .failed(let error):
                    Log.session.error("agent access listener failed: \(String(describing: error), privacy: .public)")
                    self.set(.failed(error == .posix(.EADDRINUSE)
                        ? "Port \(AgentAPI.port) is in use by another app."
                        : "Couldn't listen on port \(AgentAPI.port): \(error.localizedDescription)"))
                    self.stop(keepState: true)
                default: break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            set(.failed("Couldn't listen on port \(AgentAPI.port): \(error.localizedDescription)"))
        }
    }

    private func stop(keepState: Bool = false) {
        listener?.cancel()
        listener = nil
        api = nil
        if !keepState { set(.off) }
    }

    private func set(_ state: State) {
        let changed = stateLock.withLock { current in
            defer { current = state }
            return current != state
        }
        if changed { DispatchQueue.main.async { NotificationCenter.default.post(name: .gtAgentServerStateDidChange, object: nil) } }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A client that never finishes its request is dropped.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch AgentAPI.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            case .invalid(let response):
                self.send(response, on: connection)
            case .complete(let request):
                guard let api = self.api else { return connection.cancel() }
                self.send(api.respond(to: request), on: connection)
            }
        }
    }

    private func send(_ response: AgentAPI.Response, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
