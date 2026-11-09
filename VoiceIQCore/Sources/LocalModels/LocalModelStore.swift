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

/// A newer pinned revision of a model whose earlier revision is on disk. The
/// earlier one stays in use (`LocalModelState.ready`) until the update is
/// installed.
public enum LocalModelUpdate: Equatable, Sendable {
    case available
    /// Fraction of all model bytes in place and verified, 0...1.
    case downloading(progress: Double)
    case failed(String)
}

/// Owns one downloaded model or pack. Nothing here downloads or loads it on its
/// own: downloads start only from `download()`, and inference code loads it
/// from the folder `acquireSession` returns. Each store has its own folder and
/// state, so one download or delete never affects another.
@MainActor
public final class LocalModelStore: ObservableObject {
    private static let parakeet = LocalModelStore(model: .parakeet)
    private static let fluidSpeechPro = LocalModelStore(model: .fluidSpeechPro)

    /// Speech detection and Parakeet dictionary correction for English
    /// dictation. The install folder holds one subfolder per
    /// `EnglishToolsFolder` case.
    public static let englishTools = LocalModelStore(manifest: .englishTools, displayName: "English tools")

    /// Who spoke when, for meetings transcribed on device. Words come from
    /// Fluid Speech Mini; this model only tells the speakers apart.
    public static let speakerDiarizer = LocalModelStore(manifest: .speakerDiarizer, displayName: "Speaker Separation (pyannote community-1)")

    public static func store(for model: LocalSpeechModel) -> LocalModelStore {
        switch model {
        case .parakeet: return parakeet
        case .fluidSpeechPro: return fluidSpeechPro
        }
    }

    private static let writer2B = LocalModelStore(manifest: LocalWriterModel.qwen3_5_2b.manifest,
                                                  displayName: LocalWriterModel.qwen3_5_2b.displayName, isWriter: true)
    private static let writer06B = LocalModelStore(manifest: LocalWriterModel.qwen3_0_6b.manifest,
                                                   displayName: LocalWriterModel.qwen3_0_6b.displayName, isWriter: true)

    /// A speech model, the English tools or the diarizer is held by a
    /// dictation, meeting or retry: the writer must not load beside it.
    static var speechInUse: Bool {
        [parakeet, fluidSpeechPro, englishTools, speakerDiarizer].contains { !$0.sessions.isEmpty }
    }

    public static func store(for model: LocalWriterModel) -> LocalModelStore {
        switch model {
        case .qwen3_5_2b: return writer2B
        case .qwen3_0_6b: return writer06B
        }
    }

    public let displayName: String
    @Published public private(set) var state: LocalModelState
    /// Nil while the pinned revision is installed, or nothing is.
    @Published public private(set) var update: LocalModelUpdate?
    /// What `update` downloads: the files the installed revision lacks. Nil
    /// until counted, which hashes the installed files once.
    @Published public private(set) var updateBytes: Int64?
    private let manifest: LocalModelManifest
    /// A VoiceIQ Writer size. On the Mac its helper keeps the model loaded
    /// between dictations, so deleting it stops the helper too.
    private let isWriter: Bool
    /// The revision sessions load: the pinned one, or a previous one until
    /// its update is installed.
    private var installedRevision: String?

    /// Total size of every file a download fetches.
    public var downloadBytes: Int64 { manifest.totalBytes }

    private var downloadTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var sessions: [UUID: @Sendable () async -> Void] = [:]

    private convenience init(model: LocalSpeechModel) {
        self.init(manifest: model.manifest, displayName: model.displayName)
    }

    private init(manifest: LocalModelManifest, displayName: String, isWriter: Bool = false) {
        self.displayName = displayName
        self.manifest = manifest
        self.isWriter = isWriter
        guard LocalModelSupport.isAvailable else {
            state = .unsupported
            return
        }
        if LocalModelInstaller.isInstalled(manifest) {
            installedRevision = manifest.revision
        } else if let previous = LocalModelInstaller.previousRevision(manifest) {
            installedRevision = previous
            update = .available
        }
        state = installedRevision == nil ? .notDownloaded : .ready
        let keeping = installedRevision
        cleanupTask = Task.detached(priority: .utility) { LocalModelInstaller.removeStaleItems(manifest, keeping: keeping) }
        if let keeping, update != nil {
            let previous = manifest.rootDirectory.appendingPathComponent(keeping, isDirectory: true)
            Task.detached(priority: .utility) { [weak self] in
                let bytes = LocalModelInstaller.updateBytes(manifest, from: previous)
                await MainActor.run { if self?.update != nil { self?.updateBytes = bytes } }
            }
        }
    }

    /// The folder sessions load, or nil when no revision is usable.
    public var installedDirectory: URL? {
        guard state == .ready, let installedRevision else { return nil }
        return manifest.rootDirectory.appendingPathComponent(installedRevision, isDirectory: true)
    }

    /// The verified model folder, or nil when the model is absent, damaged, or
    /// being deleted. `cancel` is called if the model is deleted mid-session;
    /// it must stop all use of the folder before returning.
    public func acquireSession(id: UUID, cancel: @escaping @Sendable () async -> Void) -> URL? {
        guard deleteTask == nil, sessions.isEmpty, let directory = installedDirectory, let installedRevision else { return nil }
        guard LocalModelInstaller.isUsable(manifest, revision: installedRevision) else {
            self.installedRevision = nil
            update = nil
            updateBytes = nil
            // An update in flight carries on as a fresh download.
            state = downloadTask == nil ? .notDownloaded : .downloading(progress: 0)
            return nil
        }
        sessions[id] = cancel
        return directory
    }

    public func releaseSession(id: UUID) {
        sessions[id] = nil
    }

    /// Downloads the pinned revision, or installs its update while the
    /// previous revision stays in use.
    public func download() {
        guard downloadTask == nil, deleteTask == nil else { return }
        let previous: URL?
        switch (state, update) {
        case (.notDownloaded, _), (.failed, _):
            previous = nil
            state = .downloading(progress: 0)
        case (.ready, .available?), (.ready, .failed?):
            previous = installedDirectory
            update = .downloading(progress: 0)
        default:
            return
        }
        let manifest = manifest, downloadBytes = updateBytes
        downloadTask = Task { [weak self] in
            await self?.cleanupTask?.value
            var failure: String?
            var cancelled = false
            do {
                try await LocalModelInstaller.install(manifest, reusing: previous, downloadBytes: downloadBytes) { bytes in
                    Task { @MainActor in self?.report(bytes: bytes) }
                }
            } catch is CancellationError {
                cancelled = true
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.downloadTask = nil
            // A delete in progress owns the state until it finishes.
            guard self.deleteTask == nil else { return }
            if !cancelled, failure == nil {
                self.installed(replacing: previous)
            } else if self.installedRevision != nil {
                self.update = failure.map { .failed($0) } ?? .available
            } else {
                self.state = failure.map { .failed($0) } ?? .notDownloaded
            }
        }
    }

    /// The pinned revision is in place: new sessions load it. The previous
    /// folder goes now if nothing has it open, else at the next launch.
    private func installed(replacing previous: URL?) {
        installedRevision = manifest.revision
        update = nil
        updateBytes = nil
        state = .ready
        if let previous, sessions.isEmpty {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: previous) }
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
            #if os(macOS)
            if isWriter { await LocalRemoteWriter.kill() }
            #endif
            let manifest = manifest
            let removed = await Task.detached(priority: .userInitiated) { () -> Bool in
                (try? LocalModelInstaller.removeAll(manifest)) != nil
            }.value
            deleteTask = nil
            if removed {
                installedRevision = nil
                update = nil
                updateBytes = nil
            }
            state = removed ? .notDownloaded : .failed("The model could not be deleted.")
        }
        deleteTask = task
        await task.value
    }

    private func report(bytes: Int64) {
        // An update downloads only `updateBytes`; the rest is cloned.
        let total = update == nil ? manifest.totalBytes : max(updateBytes ?? manifest.totalBytes, 1)
        let progress = min(1, Double(bytes) / Double(total))
        if case .downloading(let current) = update {
            if progress > current { update = .downloading(progress: progress) }
        } else if case .downloading(let current) = state, progress > current {
            state = .downloading(progress: progress)
        }
    }
}
