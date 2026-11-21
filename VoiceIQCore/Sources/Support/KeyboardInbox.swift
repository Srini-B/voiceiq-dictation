import Foundation
import VoiceIQBridge

/// Dictations the iPhone keyboard recorded and processed itself, on their way
/// into the app's History.
///
/// The keyboard runs the same `DictationCoordinator` as the app with
/// `FileLayout.overrideRoot` set to `root`, so its session folders (audio,
/// meta.json with the step times) land in `root/recordings`. When a dictation
/// ends, the keyboard moves the folder to `root/finished` with its billed
/// calls in `usage.json`. The app moves finished folders, and folders the
/// keyboard abandoned (it was ended mid-dictation), into its own recordings
/// and adds them to History, where retry and recovery work as for its own.
/// The keyboard never opens the History or usage databases: a suspended
/// process holding a lock on a database in the shared container is ended by
/// iOS.
///
/// A dictation whose transcription outlived the keyboard has a job in
/// `root/jobs` (`KeyboardJob`); its folder stays in `recordings` until the
/// job finishes or the app takes it over.
public enum KeyboardInbox {
    public static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID)?
            .appendingPathComponent("KeyboardInbox", isDirectory: true)
    }

    private static let usageFile = "usage.json"
    /// A folder still in `recordings` this long after its last write was
    /// left behind by a keyboard that iOS ended.
    static let abandonedAfter: TimeInterval = 600

    /// Keyboard: the dictation in `folder` is over. False when its billed
    /// calls could not be written next to it, so the caller keeps them.
    @discardableResult
    public static func finish(folder: URL, usage: [UsageRecord], root: URL? = root) -> Bool {
        guard let root, FileManager.default.fileExists(atPath: folder.path) else { return false }
        let finished = root.appendingPathComponent("finished", isDirectory: true)
        try? FileManager.default.createDirectory(at: finished, withIntermediateDirectories: true)
        var saved = true
        if !usage.isEmpty {
            saved = (try? JSONEncoder().encode(usage).write(to: folder.appendingPathComponent(usageFile), options: .atomic)) != nil
        }
        // A folder that cannot move stays in `recordings`, usage and all, and
        // is collected as abandoned.
        try? FileManager.default.moveItem(at: folder, to: finished.appendingPathComponent(folder.lastPathComponent))
        return saved
    }

    /// App: moves what the keyboard left into `FileLayout.recordingsRoot` and
    /// returns each folder's meta and new place, plus the billed calls. A
    /// folder with a pending job stays until the job is done.
    public static func collect(from root: URL? = root, now: Date = Date()) -> (sessions: [(meta: SessionMeta, folder: URL)], usage: [UsageRecord]) {
        guard let root else { return ([], []) }
        let fileManager = FileManager.default
        let pending = Set(KeyboardJob.pending(in: root).map(\.folder))
        var candidates = (try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("finished"), includingPropertiesForKeys: nil)) ?? []
        for folder in (try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("recordings"),
                                                           includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where !pending.contains(folder.lastPathComponent) {
            let touched = [FileLayout.metaJSON(in: folder), FileLayout.audioCAF(in: folder), folder]
                .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
                .max() ?? .distantPast
            if now.timeIntervalSince(touched) > abandonedAfter { candidates.append(folder) }
        }
        var sessions: [(SessionMeta, URL)] = []
        var usage: [UsageRecord] = []
        try? fileManager.createDirectory(at: FileLayout.recordingsRoot, withIntermediateDirectories: true)
        for folder in candidates {
            let usageURL = folder.appendingPathComponent(usageFile)
            if let data = try? Data(contentsOf: usageURL), let records = try? JSONDecoder().decode([UsageRecord].self, from: data) {
                usage += records
            }
            try? fileManager.removeItem(at: usageURL)
            let target = FileLayout.recordingsRoot.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            guard (try? fileManager.moveItem(at: folder, to: target)) != nil else { continue }
            if let meta = SessionMeta.read(from: target) { sessions.append((meta, target)) }
        }
        return (sessions, usage)
    }
}

/// A keyboard dictation whose transcription request went to the keyboard's
/// background `URLSession` (`KeyboardTransfers`): the keyboard was hidden
/// before it finished, or the device was offline. Written atomically to
/// `KeyboardInbox.root/jobs/<id>.json` next to the request body
/// (`<id>.body`); the answer lands in `<id>.response` and `<id>.status`.
public struct KeyboardJob: Codable, Equatable, Sendable {
    public var id: UUID
    /// The session folder's name in `KeyboardInbox.root/recordings`.
    public var folder: String
    public var mode: KeyboardMode
    public var translationTargets: [String]
    public var selectedText: String?
    public var host: String?
    public var hostName: String?
    /// The field it was started in, for the held result.
    public var document: UUID?
    public var durationSeconds: Double
    public var createdAt: Date
    /// Who the request went to, which decides how its answer reads, even
    /// after the provider in Settings changed. Nil in jobs of older builds.
    public var transcriber: ModelEndpoint?

    public init(id: UUID = UUID(), folder: String, mode: KeyboardMode, translationTargets: [String] = [],
                selectedText: String? = nil, host: String? = nil, hostName: String? = nil, document: UUID? = nil,
                durationSeconds: Double, createdAt: Date = Date(), transcriber: ModelEndpoint? = nil) {
        self.id = id
        self.folder = folder
        self.mode = mode
        self.translationTargets = translationTargets
        self.selectedText = selectedText
        self.host = host
        self.hostName = hostName
        self.document = document
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.transcriber = transcriber
    }

    /// Only a recording sent in one request goes to the background session:
    /// a replayed answer stands for the first request, so a longer one
    /// (several chunks) stays with the app's chunk-aware retry.
    public static func fitsOneRequest(durationSeconds: Double) -> Bool {
        durationSeconds <= AudioChunker.maxChunkSeconds
    }

    public var context: DictationContext {
        let dictationMode: DictationMode = switch mode {
        case .dictate: .dictate
        case .translate: .translate(targets: translationTargets)
        case .ask: .askAnything(selectedText: selectedText)
        }
        return DictationContext(targetAppBundleID: host, targetAppName: hostName, mode: dictationMode)
    }

    /// The provider's answer, once the transfer ended.
    public struct Answer: Codable, Equatable, Sendable {
        /// HTTP status, or nil when the transfer failed without one.
        public var status: Int?
        public var error: String?
    }

    // MARK: - Files

    static func directory(in root: URL?) -> URL? { root?.appendingPathComponent("jobs", isDirectory: true) }

    public static func bodyURL(_ id: UUID, root: URL? = KeyboardInbox.root) -> URL? {
        directory(in: root)?.appendingPathComponent("\(id.uuidString).body")
    }

    public static func responseURL(_ id: UUID, root: URL? = KeyboardInbox.root) -> URL? {
        directory(in: root)?.appendingPathComponent("\(id.uuidString).response")
    }

    static func answerURL(_ id: UUID, root: URL?) -> URL? {
        directory(in: root)?.appendingPathComponent("\(id.uuidString).status")
    }

    public func write(root: URL? = KeyboardInbox.root) throws {
        guard let directory = Self.directory(in: root) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
    }

    public static func pending(in root: URL? = KeyboardInbox.root) -> [KeyboardJob] {
        guard let directory = directory(in: root),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(KeyboardJob.self, from: $0) } }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public static func read(_ id: UUID, root: URL? = KeyboardInbox.root) -> KeyboardJob? {
        pending(in: root).first { $0.id == id }
    }

    public func answer(root: URL? = KeyboardInbox.root) -> Answer? {
        guard let url = Self.answerURL(id, root: root), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: data)
    }

    static func record(_ answer: Answer, for id: UUID, root: URL? = KeyboardInbox.root) {
        guard let url = answerURL(id, root: root), let data = try? JSONEncoder().encode(answer) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The job is over: its files go, its folder stays for the caller.
    public func remove(root: URL? = KeyboardInbox.root) {
        guard let directory = Self.directory(in: root) else { return }
        for suffix in ["json", "body", "response", "status", "claim"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).\(suffix)"))
        }
    }

    /// A claim older than this belongs to a process that ended mid-finish.
    static let claimLifetime: TimeInterval = 300

    /// One process's hold on a job: the keyboard's while it starts the
    /// upload, a finish's or the app's takeover until the job is removed.
    public struct Claim: Sendable {
        let url: URL
        let token: String

        /// Lets go, unless the claim went stale and someone else holds it now.
        public func release() {
            guard (try? String(contentsOf: url, encoding: .utf8)) == token else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Claims the job across processes, or nil when another one holds it.
    /// The claim file appears atomically with its owner's token (`link`).
    /// A stale one is moved aside atomically and deleted only if it is the
    /// one judged stale; a fresh claim taken meanwhile is put back.
    public func claim(root: URL? = KeyboardInbox.root, now: Date = Date()) -> Claim? {
        guard let directory = Self.directory(in: root) else { return nil }
        let url = directory.appendingPathComponent("\(id.uuidString).claim")
        let token = UUID().uuidString
        let staging = directory.appendingPathComponent("\(id.uuidString).claim-\(token)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? Data(token.utf8).write(to: staging)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: staging) }
        for _ in 0..<2 {
            if link(staging.path, url.path) == 0 { return Claim(url: url, token: token) }
            guard errno == EEXIST, let held = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let taken = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            guard now.timeIntervalSince(taken) > Self.claimLifetime else { return nil }
            let aside = directory.appendingPathComponent("\(id.uuidString).claim-stale-\(token)")
            guard rename(url.path, aside.path) == 0 else { continue }
            let moved = try? String(contentsOf: aside, encoding: .utf8)
            if moved != held { _ = link(aside.path, url.path) }
            try? FileManager.default.removeItem(at: aside)
            if moved != held { return nil }
        }
        return nil
    }

    /// App, in the foreground: takes over each job with no answer and no
    /// upload running (Background App Refresh off, the app force-quit).
    /// Each is claimed before the session's tasks are read, so a keyboard
    /// still between writing a job and starting its upload (it holds the
    /// claim) is left alone, and one that started its upload is in the list.
    @discardableResult
    public static func takeOverIdle(_ jobs: [KeyboardJob], root: URL? = KeyboardInbox.root,
                                    uploading: @Sendable () async -> Set<UUID>) async -> [KeyboardJob] {
        let claimed = jobs.filter { $0.answer(root: root) == nil }.compactMap { job in job.claim(root: root).map { (job, $0) } }
        guard !claimed.isEmpty else { return [] }
        let running = await uploading()
        var taken: [KeyboardJob] = []
        for (job, claim) in claimed {
            guard !running.contains(job.id), job.answer(root: root) == nil, read(job.id, root: root) != nil else {
                claim.release()
                continue
            }
            job.takeOver(root: root)
            taken.append(job)
        }
        return taken
    }

    public func folderURL(root: URL? = KeyboardInbox.root) -> URL? {
        root?.appendingPathComponent("recordings/\(folder)", isDirectory: true)
    }

    /// App, in the foreground: a job whose transfer has not answered goes
    /// through the app's own retry like any queued dictation. Its folder
    /// moves to `finished` for `KeyboardInbox.collect`, and an answer that
    /// still arrives later finds no job and is dropped.
    ///
    /// The retry queue transcribes as Dictate, as for the app's own
    /// dictations; the app does not queue a Translate or Ask that failed
    /// either, it marks it failed with Retry in History. A taken-over
    /// Translate or Ask job does the same.
    public func takeOver(root: URL? = KeyboardInbox.root) {
        if let folder = folderURL(root: root) {
            if mode != .dictate, var meta = SessionMeta.read(from: folder), meta.status == .queuedForRetry {
                meta.status = .failed
                meta.errorCode = "mode_transform"
                meta.write(to: folder)
            }
            KeyboardInbox.finish(folder: folder, usage: [], root: root)
        }
        remove(root: root)
    }
}
