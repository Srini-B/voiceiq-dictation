// Records what the given processes play, through a Core Audio process tap,
// to a WAV: taprecord SECONDS OUT.wav PID [PID…]
// run.sh points it at the owner's Chrome to check that each guest is heard.
// Only processes with a Core Audio process object are tapped (a browser's
// renderers have none); it waits up to 10 s for the first. Exits 1 if none appears.
// The terminal or agent running it needs System Audio Recording permission.
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
guard #available(macOS 14.2, *), args.count >= 4, let seconds = Double(args[1]) else {
    print("usage: taprecord SECONDS OUT.wav PID [PID…]"); exit(2)
}
let pids = args[3...].compactMap { pid_t($0) }
var found: [AudioObjectID] = []
for _ in 0..<20 {
    found = pids.compactMap(processObject)
    if !found.isEmpty { break }
    Thread.sleep(forTimeInterval: 0.5)
}
guard !found.isEmpty else { FileHandle.standardError.write("no audio process for \(pids)\n".data(using: .utf8)!); exit(1) }
print("taprecord: \(found.count) of \(pids.count) processes")

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
check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
    try? file.write(from: buffer)
}, "io proc")
check(AudioDeviceStart(device, proc), "start")
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(device, proc)
AudioDeviceDestroyIOProcID(device, proc!)
// After the last queued buffer: a global AVAudioFile is never deinitialized, so close it.
queue.sync { file.close() }
AudioHardwareDestroyAggregateDevice(device)
AudioHardwareDestroyProcessTap(tap)
