// Records what matching processes play, through a Core Audio process tap,
// to a WAV: taprecord SECONDS OUT.wav PATTERN
// run.sh points it at the owner's Chrome to check that each guest is heard.
// It stops SECONDS after it starts, however long the wait below took, so the
// recording ends before the call's speech. Until then it reruns
// `pgrep -f PATTERN` (a browser starts its audio helper late) until one of
// them is playing sound, then taps every one with a Core Audio process
// object. Exits 1 if none plays, 3 if the recording is all exact zeros: what a
// tap returns without System Audio Recording permission, which the terminal
// or agent running it needs.
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

func processObject(_ pid: pid_t) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var pid = pid, object = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
    return status == noErr && object != kAudioObjectUnknown ? object : nil
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { FileHandle.standardError.write("\(what) failed: \(status)\n".data(using: .utf8)!); exit(1) }
}

let args = CommandLine.arguments
// 15, not the tap's 14.2: AVAudioFile.close() below is macOS 15.
guard #available(macOS 15.0, *), args.count == 4, let seconds = Double(args[1]) else {
    print("usage: taprecord SECONDS OUT.wav PATTERN"); exit(2)
}
let deadline = Date(timeIntervalSinceNow: seconds)

func pids(matching pattern: String) -> [pid_t] {
    let pgrep = Process(), pipe = Pipe()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", "--", pattern]
    pgrep.standardOutput = pipe
    guard (try? pgrep.run()) != nil else { return [] }
    pgrep.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    // Its own command line holds the pattern too.
    return out.split(separator: "\n").compactMap { pid_t($0) }.filter { $0 != getpid() }
}

func isPlaying(_ object: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr && running != 0
}

var found: [AudioObjectID] = []
var playing = false
while !playing, deadline.timeIntervalSinceNow > 2 {
    found = pids(matching: args[3]).compactMap(processObject)
    playing = found.contains(where: isPlaying)
    if !playing { Thread.sleep(forTimeInterval: 0.5) }
}
guard playing else { FileHandle.standardError.write("no process matching \(args[3]) played sound\n".data(using: .utf8)!); exit(1) }
print("taprecord: \(found.count) processes, recording \(String(format: "%.0f", deadline.timeIntervalSinceNow)) s")

let description = CATapDescription(stereoMixdownOfProcesses: found)
description.uuid = UUID(); description.muteBehavior = .unmuted
var tap = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(description, &tap), "create tap")
var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                         mElement: kAudioObjectPropertyElementMain)
var asbd = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "tap format")
guard let format = AVAudioFormat(streamDescription: &asbd) else { print("unusable tap format"); exit(1) }
let file = try AVAudioFile(forWriting: URL(fileURLWithPath: args[2]), settings: format.settings,
                           commonFormat: format.commonFormat, interleaved: format.isInterleaved)
let aggregate: [String: Any] = [
    kAudioAggregateDeviceNameKey: "taprecord", kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
]
var device = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create aggregate")
var proc: AudioDeviceIOProcID?
let queue = DispatchQueue(label: "taprecord")
var heardSound = false
check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
    if !heardSound {
        heardSound = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).contains { buffer in
            buffer.mData.map { UnsafeRawBufferPointer(start: $0, count: Int(buffer.mDataByteSize)).contains { $0 != 0 } } ?? false
        }
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
    try? file.write(from: buffer)
}, "io proc")
check(AudioDeviceStart(device, proc), "start")
Thread.sleep(until: deadline)
AudioDeviceStop(device, proc)
AudioDeviceDestroyIOProcID(device, proc!)
// After the last queued buffer: a global AVAudioFile is never deinitialized, so close it.
queue.sync { file.close() }
AudioHardwareDestroyAggregateDevice(device)
AudioHardwareDestroyProcessTap(tap)
if !(queue.sync { heardSound }) {
    FileHandle.standardError.write("the tap recorded only zeros: the terminal or agent lacks System Audio Recording permission, or the call played only silence\n".data(using: .utf8)!)
    exit(3)
}
