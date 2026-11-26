#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Records the far side of a meeting to a 16 kHz mono CAF file. With call
/// processes it taps only their sound, before it reaches any output device,
/// so music, other apps, and notifications stay out of the meeting. Without
/// them (a recording started by hand with no call found) it taps everything.
///
/// A tap hears the output that was default when it was made. When the
/// default output changes (headphones in or out) or the track goes to exact
/// zeros while sound plays, a new tap is started before the old one stops,
/// into the same file, with the time between them written as silence.
/// Adapted from Hex (anomalyco/hex `5704885d`, `4a3e9d49`).
public final class SystemAudioTap: @unchecked Sendable {
    public enum TapError: Error { case unsupported, coreAudio(OSStatus), format }
    private let url: URL
    private let processes: [AudioObjectID]
    private let queue = DispatchQueue(label: "io.blue.voiceiq.meeting.system", qos: .userInitiated)
    /// `follow`, rebuilds and `stop` run here, so none touches a tap being torn down.
    private let control = DispatchQueue(label: "io.blue.voiceiq.meeting.system.control")
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// One process tap and the private aggregate device that runs it. Changed
    /// only on `control`; the I/O queue reads `input` and `converter`, which
    /// are set before its I/O proc exists.
    private final class Stream: @unchecked Sendable {
        var tapID: AudioObjectID = kAudioObjectUnknown
        var aggregateID: AudioObjectID = kAudioObjectUnknown
        var procID: AudioDeviceIOProcID?
        /// The `CATapDescription` the tap was made with, kept to change its processes.
        var description: AnyObject?
        var input: AVAudioFormat?
        var converter: AVAudioConverter?
        /// The default output when the tap was made.
        var output: AudioDeviceID = kAudioObjectUnknown
    }

    // On `control`:
    private var stream: Stream?
    private var tapped: [AudioObjectID]
    private var running = false
    // On `queue`:
    /// The stream whose buffers are written; a replacement's first buffers are dropped until it takes over.
    private var live: Stream?
    private var silence = SystemTapWatch.Silence()
    private var lastBufferAt: TimeInterval = 0
    /// Set when a replacement takes over: when the old stream's last buffer came.
    private var padFrom: TimeInterval?
    private var writer: CAFWriter?
    private var frames: Int64 = 0

    private var listening = false
    private lazy var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    /// Bluetooth headphones can flip the default a few times while they
    /// connect; the check waits for it to settle.
    private lazy var outputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.control.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.outputChanged() }
    }
    static let rebuildRetries = 5
    /// Bumped by each new rebuild; read and written on `control` only.
    private var rebuildGeneration = 0

    public init(url: URL, processes: [AudioObjectID] = []) { self.url = url; self.processes = processes; tapped = processes }
    public let sound = SoundClock()

    public func start() throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupported }
        writer = try CAFWriter(url: url, format: target); frames = 0
        // A tap that never started leaves no open file behind.
        do { try startTap() } catch { writer?.close(); writer = nil; throw error }
    }

    private func startTap() throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupported }
        try control.sync {
            let stream = try makeStream(processes: processes)
            queue.sync { live = stream; lastBufferAt = ProcessInfo.processInfo.systemUptime }
            do { try check(AudioDeviceStart(stream.aggregateID, stream.procID)) }
            catch { tearDown(stream); throw error }
            self.stream = stream; running = true
        }
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, control, outputListener)
        listening = true
        Log.meeting.notice("system tap started: \(self.processes.isEmpty ? "all audio" : "\(self.processes.count) call processes", privacy: .public)")
    }

    @available(macOS 14.2, *)
    private func makeStream(processes: [AudioObjectID]) throws -> Stream {
        let stream = Stream()
        // Read before the tap is made: the tap hears the output that is default then.
        stream.output = Self.defaultOutputDevice()
        do {
            let description = processes.isEmpty
                ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                : CATapDescription(stereoMixdownOfProcesses: processes)
            description.uuid = UUID(); description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &stream.tapID))
            stream.description = description
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout.size(ofValue: format))
            try check(AudioObjectGetPropertyData(stream.tapID, &address, 0, nil, &size, &format))
            guard let input = AVAudioFormat(streamDescription: &format), let converter = AVAudioConverter(from: input, to: target) else { throw TapError.format }
            stream.input = input; stream.converter = converter
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "VoiceiQ Meeting Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &stream.aggregateID))
            try check(AudioDeviceCreateIOProcIDWithBlock(&stream.procID, stream.aggregateID, queue) { [weak self, weak stream] _, inputData, _, _, _ in
                guard let stream else { return }
                self?.consume(inputData, from: stream)
            })
            return stream
        } catch {
            tearDown(stream)
            throw error
        }
    }

    private func tearDown(_ stream: Stream) {
        if stream.aggregateID != kAudioObjectUnknown {
            if let procID = stream.procID {
                _ = AudioDeviceStop(stream.aggregateID, procID)
                _ = AudioDeviceDestroyIOProcID(stream.aggregateID, procID)
            }
            _ = AudioHardwareDestroyAggregateDevice(stream.aggregateID)
        }
        if #available(macOS 14.2, *), stream.tapID != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(stream.tapID) }
        stream.aggregateID = kAudioObjectUnknown; stream.tapID = kAudioObjectUnknown; stream.procID = nil
    }

    /// Moves a call tap to the call's current processes: a helper that started
    /// late, or one that restarted under a new process object. A global tap
    /// stays global, and an empty list keeps the processes it has.
    public func follow(processes next: [AudioObjectID]) {
        guard #available(macOS 14.2, *), !processes.isEmpty, !next.isEmpty else { return }
        control.sync {
            guard let stream, let current = stream.description as? CATapDescription, Set(tapped) != Set(next) else { return }
            let description = CATapDescription(stereoMixdownOfProcesses: next)
            description.uuid = current.uuid; description.muteBehavior = current.muteBehavior
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var reference = description
            let status = withUnsafeMutablePointer(to: &reference) {
                AudioObjectSetPropertyData(stream.tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
            }
            if status == noErr { stream.description = description; tapped = next; Log.meeting.notice("system tap follows \(next.count) call processes") }
            else { Log.meeting.error("system tap follow failed: \(status)") }
        }
    }

    public func stop() -> Double {
        if listening {
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, control, outputListener)
            listening = false
        }
        control.sync {
            running = false
            if let stream { tearDown(stream) }
            stream = nil
        }
        queue.sync { live = nil }; writer?.close(); writer = nil
        return Double(frames) / target.sampleRate
    }

    // MARK: - Rebuilding the tap

    private func outputChanged() {
        guard running, let stream else { return }
        let current = Self.defaultOutputDevice()
        if stream.output == kAudioObjectUnknown { stream.output = current; return }
        guard SystemTapWatch.outputMoved(from: stream.output, to: current) else { return }
        rebuild("default output moved from device \(stream.output) to \(current)")
    }

    private func silenceStalled() {
        guard running else { return }
        // Nothing playing: the silence is real. The watch asks again after another stretch of it.
        guard outputPlaying() else { return }
        rebuild("system track went to exact zeros while sound plays", forSilence: true)
    }

    /// Starts a new tap before stopping the old one, so a rebuild that fails,
    /// or was not needed, loses nothing.
    /// Only a rebuild for silence advances the watch's backoff; one for an
    /// output move restarts the count at the current wait.
    private func rebuild(_ reason: String, forSilence: Bool = false, attempt: Int = 0, generation: Int? = nil) {
        guard #available(macOS 14.2, *), running, let old = stream else { return }
        // A newer rebuild supersedes this retry chain, so a stale retry
        // never replaces a tap that already recovered.
        if let generation, generation != rebuildGeneration { return }
        if generation == nil { rebuildGeneration += 1 }
        let current = rebuildGeneration
        let next: Stream
        do {
            next = try makeStream(processes: tapped)
            do { try check(AudioDeviceStart(next.aggregateID, next.procID)) } catch { tearDown(next); throw error }
        } catch {
            Log.meeting.error("system tap rebuild failed (attempt \(attempt + 1)): \(String(describing: error), privacy: .public)")
            guard attempt < Self.rebuildRetries else { return }
            control.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.rebuild(reason, forSilence: forSilence, attempt: attempt + 1, generation: current)
            }
            return
        }
        tearDown(old)
        // After the old stream's queued buffers, so they are written first.
        queue.sync { live = next; padFrom = lastBufferAt; silence.rebuilt(backingOff: forSilence) }
        stream = next
        Log.meeting.notice("system tap rebuilt: \(reason, privacy: .public)")
    }

    private func outputPlaying() -> Bool {
        guard #available(macOS 14.2, *), !tapped.isEmpty else {
            return Self.flag(Self.defaultOutputDevice(), kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
        return tapped.contains { Self.flag($0, kAudioProcessPropertyIsRunningOutput) }
    }

    // MARK: - Writing

    private func consume(_ list: UnsafePointer<AudioBufferList>, from stream: Stream) {
        guard stream === live, let inputFormat = stream.input, let converter = stream.converter, let writer,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: list, deallocator: nil) else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / inputFormat.sampleRate))
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime, seconds = Double(output.frameLength) / target.sampleRate
        if let from = padFrom {
            padFrom = nil
            let gap = SystemTapWatch.gapFrames(lastBufferAt: from, now: now, bufferSeconds: seconds, sampleRate: target.sampleRate)
            if gap > 0 { writeSilence(frames: gap, to: writer) }
        }
        lastBufferAt = now
        sound.hear(output)
        do { try writer.write(output); frames += Int64(output.frameLength) }
        catch { Log.meeting.error("system write failed: \(String(describing: error), privacy: .public)") }
        // The tap's own samples: quiet sound can round to zero at 16 bits.
        if silence.hear(seconds: seconds, exactZero: Self.allZero(list)) {
            control.async { [weak self] in self?.silenceStalled() }
        }
    }

    /// Keeps the track on the meeting's clock across a rebuild.
    private func writeSilence(frames count: Int, to writer: CAFWriter) {
        guard let gap = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count)),
              let samples = gap.int16ChannelData?[0] else { return }
        gap.frameLength = AVAudioFrameCount(count)
        samples.update(repeating: 0, count: count)
        do { try writer.write(gap); frames += Int64(count) }
        catch { Log.meeting.error("system gap write failed: \(String(describing: error), privacy: .public)") }
        Log.meeting.notice("system track padded \(count) frames across the tap rebuild")
    }

    private static func allZero(_ list: UnsafePointer<AudioBufferList>) -> Bool {
        UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)).allSatisfy { buffer in
            guard let data = buffer.mData else { return true }
            return UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize)).allSatisfy { $0 == 0 }
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : kAudioObjectUnknown
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        guard object != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private func check(_ status: OSStatus) throws { if status != noErr { throw TapError.coreAudio(status) } }
}
#endif
