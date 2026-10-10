#if os(macOS)
import Foundation
import VoiceIQSpeech

public extension LocalSpeechModel {
    var manifest: LocalModelManifest {
        switch self {
        case .parakeet: return .parakeet
        case .nemotron: return .nemotron
        }
    }
}

/// One model's files, pinned to one Hugging Face commit.
public struct LocalModelManifest: Sendable {
    public struct File: Sendable, Hashable {
        /// Relative to the install folder.
        public let path: String
        public let size: Int64
        public let sha256: String
        /// Pinned source for a file outside the manifest's repository and
        /// revision. Nil downloads from `repository` at `revision`.
        public let downloadURL: URL?

        init(path: String, size: Int64, sha256: String, downloadURL: URL? = nil) {
            self.path = path
            self.size = size
            self.sha256 = sha256
            self.downloadURL = downloadURL
        }
    }

    public let repository: String
    public let revision: String
    /// Repository folder that holds the files, with a trailing slash, or "".
    public let remotePrefix: String
    /// Folder under `<appSupport>/Models` that holds every revision and staging folder.
    public let directoryName: String
    public let files: [File]
    public let totalBytes: Int64

    init(repository: String, revision: String, remotePrefix: String = "", directoryName: String, files: [File]) {
        self.repository = repository
        self.revision = revision
        self.remotePrefix = remotePrefix
        self.directoryName = directoryName
        self.files = files
        totalBytes = files.reduce(0) { $0 + $1.size }
    }

    public func remoteURL(for file: File) -> URL {
        file.downloadURL ?? Self.huggingFaceURL(repository: repository, revision: revision, path: remotePrefix + file.path)
    }

    static func huggingFaceURL(repository: String, revision: String, path: String) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!
    }

    public var rootDirectory: URL {
        FileLayout.appSupportRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The published model folder.
    public var installDirectory: URL {
        rootDirectory.appendingPathComponent(revision, isDirectory: true)
    }

    /// Written last inside the staging folder, so the atomic rename publishes
    /// the files and the marker together.
    static let markerName = ".verified"
}
#endif
