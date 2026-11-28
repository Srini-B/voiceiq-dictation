import AVFoundation
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A recording's audio, to play or save as one `.m4a`: a dictation's
/// `audio.caf`, or a meeting's two tracks mixed the way the transcriber hears
/// them (`CallAudio`: each track levelled, the mic ducked under the far side).
public struct RecordedAudio: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The dictation's `audio.caf`.
        case dictation(URL)
        /// The meeting's folder, holding `mic.caf` and `system.caf`.
        case meeting(URL)
    }

    /// Nil when the audio is not on this device: a dictation synced from
    /// another device or removed by the audio retention setting, or a meeting
    /// still recording.
    public let source: Source?
    /// The saved file's name, without the extension.
    public let name: String

    public var isAvailable: Bool { source != nil }

    init(source: Source?, name: String) {
        self.source = source
        // A file name holds at most 255 bytes, ".m4a" and a copy number included.
        var name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        while name.utf8.count > 200 { name.removeLast() }
        self.name = name
    }

    public static func dictation(folder: URL, startedAt: Date) -> RecordedAudio {
        let caf = FileLayout.audioCAF(in: folder)
        return RecordedAudio(source: FileManager.default.fileExists(atPath: caf.path) ? .dictation(caf) : nil,
                             name: "Dictation \(startedAt.formatted(date: .abbreviated, time: .shortened))")
    }

    /// Pass nil for `folder` while the meeting is recording: its tracks are still being written.
    public static func meeting(folder: URL?, name: String) -> RecordedAudio {
        let complete = folder.map { folder in
            ["mic.caf", "system.caf"].allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        } ?? false
        return RecordedAudio(source: complete ? folder.map(Source.meeting) : nil, name: name)
    }

    /// The recording as `<name>.m4a` in its own folder's `playback` folder,
    /// made once and reused by Play and Download. It lives beside the audio
    /// so deleting the recording, or its audio by retention, removes it too.
    public func m4a() async throws -> URL {
        guard let source else { throw CocoaError(.fileNoSuchFile) }
        let recording: URL
        switch source {
        case .dictation(let caf): recording = caf.deletingLastPathComponent()
        case .meeting(let folder): recording = folder
        }
        let folder = FileLayout.playbackFolder(in: recording)
        let url = folder.appendingPathComponent(name + ".m4a")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }
        // Rendered on the caller's task, off the main actor, so stopping Play cancels it.
        // Play and Download can both ask at once; each renders its own file,
        // in the folder launch empties in case the app quits mid-render.
        let partials = FileLayout.partialRendersFolder
        try fm.createDirectory(at: partials, withIntermediateDirectories: true)
        let partial = partials.appendingPathComponent("\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: partial) }
        try await Self.render(source, to: partial)
        try Task.checkCancellation()
        if fm.fileExists(atPath: url.path) { return url }
        // Deleted, or its audio purged, while this ran: never bring it back.
        guard Self.isPresent(source) else { throw CocoaError(.fileNoSuchFile) }
        // One copy per recording: a renamed meeting replaces its old one.
        for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != url.lastPathComponent {
            try? fm.removeItem(at: old)
        }
        if !fm.fileExists(atPath: folder.path) {
            // Never the recording's own folder: that is gone only when the recording is.
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        // A render that finished first already put the same file there.
        do { try fm.moveItem(at: partial, to: url) } catch where fm.fileExists(atPath: url.path) {}
        // Retention and "never keep audio" remove the audio before `playback/`.
        // If the audio went between the check above and the move, take the
        // copy back out; if it goes after this check, `playback/` goes with it.
        guard Self.isPresent(source) else {
            try? fm.removeItem(at: folder)
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private static func isPresent(_ source: Source) -> Bool {
        switch source {
        case .dictation(let caf): return FileManager.default.fileExists(atPath: caf.path)
        case .meeting(let folder): return meeting(folder: folder, name: "").isAvailable
        }
    }

    private static func render(_ source: Source, to url: URL) async throws {
        switch source {
        case .dictation(let caf):
            let input = try AVAudioFile(forReading: caf, commonFormat: .pcmFormatInt16, interleaved: true)
            let output = try aac(url, like: input.processingFormat)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else { return }
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
        case .meeting(let folder):
            let audio = CallAudio(mic: try TrackAudio(url: folder.appendingPathComponent("mic.caf")),
                                  system: try TrackAudio(url: folder.appendingPathComponent("system.caf")))
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: TrackAudio.sampleRate,
                                             channels: 1, interleaved: true) else { return }
            let output = try aac(url, like: format)
            var start = 0.0
            while start < audio.duration {
                try Task.checkCancellation()
                let samples = try audio.samples(start...min(audio.duration, start + 60))
                start += 60
                guard !samples.isEmpty,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.int16ChannelData?[0] else { continue }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
                try output.write(from: buffer)
            }
        }
    }

    /// An AAC file taking buffers in `format`; it is finished when released.
    private static func aac(_ url: URL, like format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ], commonFormat: .pcmFormatInt16, interleaved: true)
    }
}

/// Shares the recording as its `.m4a` (iPhone's Download: Save to Files).
extension RecordedAudio: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Audio) { audio in
            SentTransferredFile(try await audio.m4a())
        }
    }
}

/// Plays one recording at a time. A meeting is mixed into an `.m4a` first,
/// which takes a few seconds for a long one, so `state` says `.preparing`.
/// The meeting player pauses, seeks and changes speed; a dictation's Play only
/// starts and stops (`toggle`).
@MainActor public final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    public enum State: Equatable { case idle, preparing, playing, paused }
    @Published public private(set) var state: State = .idle
    /// Playback speed; the meeting playback bar sets it.
    @Published public var rate: Float = 1 { didSet { player?.rate = rate } }
    private var player: AVAudioPlayer?
    private var preparing: Task<Void, Never>?
    /// Where play starts when nothing is loaded: a seek made before Play.
    private var parked: TimeInterval = 0

    public override init() {
        super.init()
        #if os(iOS)
        // Selector-based, so the centre drops it when the player goes away.
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        #endif
    }

    #if os(iOS)
    /// A phone call, Siri or another app's audio paused the player; without
    /// this the bar showed Pause on a player that had stopped.
    @objc nonisolated private func audioInterrupted(_ note: Notification) {
        let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
        guard type == .began else { return }
        Task { @MainActor [weak self] in self?.interruptionBegan() }
    }
    #endif

    /// Shows the player as paused, so Play resumes where the interruption stopped it.
    func interruptionBegan() {
        guard state == .playing else { return }
        player?.pause()
        state = .paused
    }

    /// Seconds into the recording; read it on a timeline, it is not published.
    public var position: TimeInterval { player?.currentTime ?? parked }
    /// The recording's length once it is loaded; nil before the first Play.
    public var duration: TimeInterval? { player?.duration }

    /// Plays `audio`, or stops whatever is preparing, playing or paused.
    public func toggle(_ audio: RecordedAudio) {
        guard state == .idle else { stop(); return }
        start(audio)
    }

    /// Play, Pause, and Play again from where it paused. Pressed while
    /// the meeting is still being mixed, it cancels.
    public func playPause(_ audio: RecordedAudio) {
        switch state {
        case .idle: start(audio)
        case .preparing: stop()
        case .playing: player?.pause(); state = .paused
        case .paused:
            // A voice session that held the audio session may have ended while paused.
            Self.activateSession()
            if player?.play() == true { state = .playing } else { stop() }
        }
    }

    /// Moves to `seconds`, playing on from there if it was playing.
    public func seek(to seconds: TimeInterval) {
        let seconds = max(0, seconds)
        // `position` is not published; a seek while paused still redraws.
        objectWillChange.send()
        // Just short of the end: AVAudioPlayer doesn't say what a seek to exactly its end does.
        if let player { player.currentTime = min(seconds, max(0, player.duration - 0.05)) } else { parked = seconds }
    }

    private func start(_ audio: RecordedAudio) {
        state = .preparing
        preparing = Task {
            do {
                let url = try await audio.m4a()
                try Task.checkCancellation()
                Self.activateSession()
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self
                // Speed only works when set before the player prepares.
                player.enableRate = true
                player.rate = rate
                player.currentTime = parked < player.duration ? parked : 0
                guard player.play() else { throw CocoaError(.fileReadUnknown) }
                self.player = player
                state = .playing
            } catch is CancellationError {
            } catch {
                // A stopped preparation must not stop what played after it.
                guard !Task.isCancelled else { return }
                Log.audio.error("RecordingPlayer: \(String(describing: error), privacy: .public)")
                stop()
            }
        }
    }

    /// Stops and goes back to the start.
    public func stop() {
        preparing?.cancel(); preparing = nil
        player?.stop(); player = nil
        parked = 0
        state = .idle
        Self.deactivateSession()
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.stop()
        }
    }

    /// Whether the iPhone app's voice session is running; the app sets it.
    /// A running voice session holds `.playAndRecord` with the speaker as
    /// output, and the player plays through it.
    public static var voiceSessionIsActive: @MainActor () -> Bool = { false }
    /// The player activated the audio session itself, so it deactivates it.
    private static var ownsSession = false

    // Without a voice session iPhone's default category is silenced by the
    // ring/silent switch, so playback takes the session as `.playback`.
    private static func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if !voiceSessionIsActive() {
            try? session.setCategory(.playback)
            ownsSession = true
        }
        try? session.setActive(true)
        #endif
    }

    private static func deactivateSession() {
        #if os(iOS)
        guard ownsSession else { return }
        ownsSession = false
        // A voice session that started meanwhile now holds the session.
        guard !voiceSessionIsActive() else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
