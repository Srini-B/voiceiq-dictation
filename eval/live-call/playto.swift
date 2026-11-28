// Plays a WAV to the named output device: playto DEVICE-NAME FILE [START]
// START (Unix seconds) waits until then once the file is loaded, so the owner
// speaks on the guests' clock whatever the load took.
// The file is read into memory first, so a busy disk cannot starve playback,
// and played as stereo: a mono stream lands on a multichannel device's centre
// channel, and VoiceiQ records an input device's first channel.
import AVFoundation
import CoreAudio

let args = CommandLine.arguments
func deviceID(named name: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids {
        var n = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &n, 0, nil, &s, &cf)
        if (cf?.takeRetainedValue() as String?) == name { return id }
    }
    return nil
}
guard (3...4).contains(args.count), var device = deviceID(named: args[1]) else { print("usage: playto DEVICE FILE [START]"); exit(2) }
let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: input)
let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 2)!
let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: input.frameLength)!
buffer.frameLength = input.frameLength
// Every input channel, averaged, on both outputs: a stereo file with speech
// on one side only must not play silence.
let channels = Int(input.format.channelCount)
for frame in 0..<Int(input.frameLength) {
    var sum: Float = 0
    for c in 0..<channels { sum += input.floatChannelData![c][frame] }
    for c in 0..<2 { buffer.floatChannelData![c][frame] = sum / Float(channels) }
}
let engine = AVAudioEngine()
var unit = engine.outputNode.audioUnit!
guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, 4) == noErr else {
    print("cannot play to \(args[1])"); exit(1)
}
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: stereoFormat)
try engine.start()
if args.count == 4, let start = Double(args[3]) { Thread.sleep(until: Date(timeIntervalSince1970: start)) }
let done = DispatchSemaphore(value: 0)
player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in done.signal() }
player.play()
done.wait()
