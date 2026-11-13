#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Records the far side of a meeting to a 16 kHz mono CAF file. With call
/// processes it taps only their sound, before it reaches any output device,
/// so music, other apps, and notifications stay out of the meeting. Without
/// them (a recording started by hand with no call found) it taps everything.
public final class SystemAudioTap: @unchecked Sendable {
    public enum TapError: Error { case unsupported, coreAudio(OSStatus), format }
    private let url: URL
    private let processes: [AudioObjectID]
    private let queue = DispatchQueue(label: "io.blue.voiceiq.meeting.system", qos: .userInitiated)
    /// `follow` and `stop` run here, so a follow never touches a tap being torn down.
    private let control = DispatchQueue(label: "io.blue.voiceiq.meeting.system.control")
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var procID: AudioDeviceIOProcID?
    /// The `CATapDescription` the tap was made with, kept to change its processes.
    private var description: AnyObject?
    private var tapped: [AudioObjectID]
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var writer: CAFWriter?
    private var frames: Int64 = 0

    /// Each converted 16 kHz mono Int16 buffer, after it is written; set
    /// before `start`. Feeds the live meeting transcript.
    public var onPCM: (@Sendable (Data) -> Void)?

    public init(url: URL, processes: [AudioObjectID] = []) { self.url = url; self.processes = processes; tapped = processes }

    public func start() throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupported }
        let description = processes.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID(); description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID))
        self.description = description
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var stream = AudioStreamBasicDescription(), size = UInt32(MemoryLayout.size(ofValue: stream))
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &stream))
        guard let input = AVAudioFormat(streamDescription: &stream), let converter = AVAudioConverter(from: input, to: target) else { throw TapError.format }
        inputFormat = input; self.converter = converter; writer = try CAFWriter(url: url, format: target); frames = 0
        let uid = UUID().uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoiceiQ Meeting Audio",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            self?.consume(inputData)
        })
        try check(AudioDeviceStart(aggregateID, procID))
        Log.meeting.notice("system tap started: \(self.processes.isEmpty ? "all audio" : "\(self.processes.count) call processes", privacy: .public)")
    }

    /// Moves a call tap to the call's current processes: a helper that started
    /// late, or one that restarted under a new process object. A global tap
    /// stays global, and an empty list keeps the processes it has.
    public func follow(processes next: [AudioObjectID]) {
        guard #available(macOS 14.2, *), !processes.isEmpty, !next.isEmpty else { return }
        control.sync {
            guard tapID != kAudioObjectUnknown, let current = description as? CATapDescription, Set(tapped) != Set(next) else { return }
            let description = CATapDescription(stereoMixdownOfProcesses: next)
            description.uuid = current.uuid; description.muteBehavior = current.muteBehavior
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var reference = description
            let status = withUnsafeMutablePointer(to: &reference) {
                AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
            }
            if status == noErr { self.description = description; tapped = next; Log.meeting.notice("system tap follows \(next.count) call processes") }
            else { Log.meeting.error("system tap follow failed: \(status)") }
        }
    }

    public func stop() -> Double {
        control.sync {
            if aggregateID != kAudioObjectUnknown {
                _ = AudioDeviceStop(aggregateID, procID)
                if let procID { _ = AudioDeviceDestroyIOProcID(aggregateID, procID) }
                _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            }
            if #available(macOS 14.2, *), tapID != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tapID) }
            aggregateID = kAudioObjectUnknown; tapID = kAudioObjectUnknown; procID = nil; description = nil
        }
        queue.sync {}; writer?.close(); writer = nil; converter = nil; inputFormat = nil
        return Double(frames) / target.sampleRate
    }

    private func consume(_ list: UnsafePointer<AudioBufferList>) {
        guard let inputFormat, let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                             bufferListNoCopy: list, deallocator: nil),
              let converter, let writer else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / inputFormat.sampleRate))
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        do { try writer.write(output); frames += Int64(output.frameLength) }
        catch { Log.meeting.error("system write failed: \(String(describing: error), privacy: .public)") }
        onPCM?(output.int16Data)
    }

    private func check(_ status: OSStatus) throws { if status != noErr { throw TapError.coreAudio(status) } }
}
#endif
