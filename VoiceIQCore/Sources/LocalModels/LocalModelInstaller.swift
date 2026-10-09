import CryptoKit
import Foundation

enum LocalModelInstallError: LocalizedError {
    case insufficientSpace(required: Int64)
    case httpStatus(Int)
    case corrupted(String)

    var errorDescription: String? {
        switch self {
        case .insufficientSpace(let required):
            let size = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            return "Not enough free storage. The model needs \(size)."
        case .httpStatus(let code):
            return "The server returned HTTP \(code)."
        case .corrupted(let path):
            return "\(path) failed verification."
        }
    }

    /// Folds system errors into the cases the UI shows. Cancellation maps to
    /// `CancellationError` so callers treat it as a user action, not a failure.
    static func normalize(_ error: Error, required: Int64) -> Error {
        if error is CancellationError || error is LocalModelInstallError { return error }
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSURLErrorDomain, NSURLErrorCancelled):
            return CancellationError()
        case (NSURLErrorDomain, NSURLErrorCannotWriteToFile),
             (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
             (NSPOSIXErrorDomain, Int(ENOSPC)):
            return LocalModelInstallError.insufficientSpace(required: required)
        default:
            return error
        }
    }
}

/// File work for one model's manifest. Everything here runs off the main actor.
/// Each manifest has its own root folder, so models never touch each other's files.
enum LocalModelInstaller {
    private static let stagingPrefix = ".staging-"

    /// Cheap readiness check: the marker matches the pinned revision and every
    /// file has its pinned size. Hashes are checked once, before publishing.
    static func isInstalled(_ manifest: LocalModelManifest) -> Bool {
        let directory = manifest.installDirectory
        let marker = directory.appendingPathComponent(LocalModelManifest.markerName)
        guard let data = try? Data(contentsOf: marker),
              String(decoding: data, as: UTF8.self) == manifest.revision else { return false }
        return manifest.files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
            return size == file.size
        }
    }

    /// Clears staging folders left by a crash or quit and folders from other revisions.
    static func removeStaleItems(_ manifest: LocalModelManifest) {
        let fileManager = FileManager.default
        let root = manifest.rootDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name != manifest.revision {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    static func removeAll(_ manifest: LocalModelManifest) throws {
        let root = manifest.rootDirectory
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    /// Downloads every file into a staging folder, verifies each one, then
    /// renames the folder into place. `progress` receives total bytes received.
    static func install(_ manifest: LocalModelManifest, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fileManager = FileManager.default
        let root = manifest.rootDirectory
        let staging = root.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        let downloader = LocalModelFileDownloader()
        defer { downloader.invalidate() }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try checkFreeSpace(at: root, required: manifest.totalBytes)
            var completed: Int64 = 0
            for file in manifest.files {
                try Task.checkCancellation()
                let destination = staging.appendingPathComponent(file.path)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = completed
                try await downloader.download(manifest.remoteURL(for: file), to: destination) { written in
                    progress(base + min(written, file.size))
                }
                try verify(destination, against: file)
                completed += file.size
                progress(completed)
            }
            try Task.checkCancellation()
            try Data(manifest.revision.utf8)
                .write(to: staging.appendingPathComponent(LocalModelManifest.markerName), options: .atomic)
            let target = manifest.installDirectory
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw LocalModelInstallError.normalize(error, required: manifest.totalBytes)
        }
    }

    private static func checkFreeSpace(at url: URL, required: Int64) throws {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        let headroom: Int64 = 64 * 1_024 * 1_024
        if let available, available < required + headroom {
            throw LocalModelInstallError.insufficientSpace(required: required)
        }
    }

    private static func verify(_ url: URL, against file: LocalModelManifest.File) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? Int64
        guard size == file.size, try sha256(of: url) == file.sha256 else {
            throw LocalModelInstallError.corrupted(file.path)
        }
    }

    /// Streams the file in 1 MiB chunks so a multi-hundred-MB encoder never sits in memory.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One `URLSessionDownloadTask` at a time, with byte progress from the delegate.
/// Redirects to the Hugging Face CDN follow the session default.
final class LocalModelFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let task: URLSessionDownloadTask
        let destination: URL
        let onBytes: @Sendable (Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
        var lastReported: Int64 = 0
        var finishError: Error?
    }

    private let lock = NSLock()
    private var pending: Pending?
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 1
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// The session retains its delegate until invalidated.
    func invalidate() {
        session.invalidateAndCancel()
    }

    func download(_ url: URL, to destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    let task = session.downloadTask(with: url)
                    pending = Pending(task: task, destination: destination, onBytes: onBytes, continuation: continuation)
                    task.resume()
                }
                // The cancellation handler runs first, with nothing to cancel,
                // when the task was cancelled before this point.
                if Task.isCancelled { cancelCurrent() }
            }
        } onCancel: {
            cancelCurrent()
        }
    }

    private func cancelCurrent() {
        lock.withLock { pending?.task.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let report: (@Sendable (Int64) -> Void)? = lock.withLock {
            guard var current = pending,
                  totalBytesWritten - current.lastReported >= 1 << 20 else { return nil }
            current.lastReported = totalBytesWritten
            pending = current
            return current.onBytes
        }
        report?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.withLock {
            guard var current = pending else { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) {
                current.finishError = LocalModelInstallError.httpStatus(status)
            } else {
                // The temporary file is deleted when this method returns.
                do {
                    try? FileManager.default.removeItem(at: current.destination)
                    try FileManager.default.moveItem(at: location, to: current.destination)
                } catch {
                    current.finishError = error
                }
            }
            pending = current
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let current = lock.withLock({ () -> Pending? in
            defer { pending = nil }
            return pending
        }) else { return }
        if let error = error ?? current.finishError {
            current.continuation.resume(throwing: error)
        } else {
            current.continuation.resume()
        }
    }
}
