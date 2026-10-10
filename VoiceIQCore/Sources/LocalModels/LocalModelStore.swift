import Foundation
import VoiceIQSpeech

public enum LocalModelSupport {
    /// The package's deployment targets already guarantee macOS 14 and iOS 17.
    public static var isAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static var requirement: String {
        #if os(macOS)
        return "Requires a Mac with Apple silicon and macOS 14 or later."
        #else
        return "Requires iOS 17 or later."
        #endif
    }
}

public enum LocalModelState: Equatable, Sendable {
    case unsupported
    case notDownloaded
    /// Fraction of all model bytes received and verified so far, 0...1.
    case downloading(progress: Double)
    case ready
    case deleting
    case failed(String)
}

/// Owns one downloaded model. Nothing here downloads or loads the model on its
/// own: downloads start only from `download()`, and inference code loads the
/// model from the folder `acquireSession` returns. Each model has its own
/// store, folder, and state, so one model's download or delete never affects
/// the other.
@MainActor
public final class LocalModelStore: ObservableObject {
    private static let parakeet = LocalModelStore(model: .parakeet)
    private static let nemotron = LocalModelStore(model: .nemotron)

    public static func store(for model: LocalSpeechModel) -> LocalModelStore {
        switch model {
        case .parakeet: return parakeet
        case .nemotron: return nemotron
        }
    }

    public let model: LocalSpeechModel
    @Published public private(set) var state: LocalModelState
    private let manifest: LocalModelManifest

    private var downloadTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var sessions: [UUID: @Sendable () async -> Void] = [:]

    private init(model: LocalSpeechModel) {
        self.model = model
        let manifest = model.manifest
        self.manifest = manifest
        guard LocalModelSupport.isAvailable else {
            state = .unsupported
            return
        }
        state = LocalModelInstaller.isInstalled(manifest) ? .ready : .notDownloaded
        cleanupTask = Task.detached(priority: .utility) { LocalModelInstaller.removeStaleItems(manifest) }
    }

    /// The verified model folder, or nil when the model is absent, damaged, or
    /// being deleted. `cancel` is called if the model is deleted mid-session;
    /// it must stop all use of the folder before returning.
    public func acquireSession(id: UUID, cancel: @escaping @Sendable () async -> Void) -> URL? {
        guard state == .ready, deleteTask == nil, sessions.isEmpty else { return nil }
        guard LocalModelInstaller.isInstalled(manifest) else {
            state = .notDownloaded
            return nil
        }
        sessions[id] = cancel
        return manifest.installDirectory
    }

    public func releaseSession(id: UUID) {
        sessions[id] = nil
    }

    public func download() {
        guard downloadTask == nil, deleteTask == nil else { return }
        switch state {
        case .notDownloaded, .failed: break
        case .unsupported, .downloading, .ready, .deleting: return
        }
        state = .downloading(progress: 0)
        let manifest = manifest
        downloadTask = Task { [weak self] in
            await self?.cleanupTask?.value
            let outcome: LocalModelState
            do {
                try await LocalModelInstaller.install(manifest) { bytes in
                    Task { @MainActor in self?.report(bytes: bytes) }
                }
                outcome = .ready
            } catch is CancellationError {
                outcome = .notDownloaded
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard let self else { return }
            self.downloadTask = nil
            // A delete in progress owns the state until it finishes.
            if self.deleteTask == nil { self.state = outcome }
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Stops any download, waits for every active session to cancel, then
    /// removes the model. The local transcription setting is left as it is.
    public func deleteModel() async {
        if let deleteTask {
            await deleteTask.value
            return
        }
        guard LocalModelSupport.isAvailable else { return }
        let task = Task { [self] in
            state = .deleting
            downloadTask?.cancel()
            await downloadTask?.value
            let cancels = Array(sessions.values)
            sessions.removeAll()
            await withTaskGroup(of: Void.self) { group in
                for cancel in cancels { group.addTask { await cancel() } }
            }
            let manifest = manifest
            let removed = await Task.detached(priority: .userInitiated) { () -> Bool in
                (try? LocalModelInstaller.removeAll(manifest)) != nil
            }.value
            deleteTask = nil
            state = removed ? .notDownloaded : .failed("The model could not be deleted.")
        }
        deleteTask = task
        await task.value
    }

    private func report(bytes: Int64) {
        guard case .downloading(let current) = state else { return }
        let progress = min(1, Double(bytes) / Double(manifest.totalBytes))
        if progress > current { state = .downloading(progress: progress) }
    }
}
