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
        self.name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
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
@MainActor public final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    public enum State: Equatable { case idle, preparing, playing }
    @Published public private(set) var state: State = .idle
    private var player: AVAudioPlayer?
    private var preparing: Task<Void, Never>?

    public override init() { super.init() }

    /// Plays `audio`, or stops whatever is preparing or playing.
    public func toggle(_ audio: RecordedAudio) {
        guard state == .idle else { stop(); return }
        state = .preparing
        preparing = Task {
            do {
                let url = try await audio.m4a()
                try Task.checkCancellation()
                Self.activateSession()
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self
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

    public func stop() {
        preparing?.cancel(); preparing = nil
        player?.stop(); player = nil
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

    // A voice session holds `.playAndRecord` with the speaker as output, and
    // the player plays through it. Otherwise iPhone's default category is
    // silenced by the ring/silent switch, so playback takes the session.
    private static func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // A voice session keeps its category, but may have been deactivated.
        if session.category != .playAndRecord { try? session.setCategory(.playback) }
        try? session.setActive(true)
        #endif
    }

    private static func deactivateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playback else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
