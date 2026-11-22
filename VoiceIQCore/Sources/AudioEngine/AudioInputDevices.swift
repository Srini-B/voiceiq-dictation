#if os(macOS)
import CoreAudio
import Foundation

public extension Notification.Name {
    /// The system default input device changed (AirPods connected, headset
    /// unplugged, picker used). Anything holding device-specific state — a
    /// prewarmed capture graph, a menu checkmark — must refresh.
    static let voiceIQDefaultInputChanged = Notification.Name("io.blue.voiceiq.default-input-changed")
    static let voiceIQInputDevicesChanged = Notification.Name("io.blue.voiceiq.input-devices-changed")
}

/// Enumerates input devices and gets/sets the SYSTEM default input.
///
/// Deliberately system-level: engine-level device pinning (AU property or
/// AUAudioUnit.setDeviceID) silently kills the AVAudioEngine tap on macOS 26 —
/// probed, do not reintroduce. VoiceiQ always records from the system default;
/// the menu's Microphone picker simply moves that default, exactly like
/// Control Center's input picker.
public enum AudioInputDevices {
    public struct Device: Identifiable, Equatable, Sendable {
        public let id: AudioDeviceID
        public let name: String
        public let uid: String
    }

    public static func list() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard hasInputStreams(id), !isPrivateAggregate(id),
                  let name = name(of: id), let uid = uid(of: id) else { return nil }
            return Device(id: id, name: name, uid: uid)
        }
    }

    /// CoreAudio builds a private aggregate (`CADefaultDeviceAggregate-<pid>-0`,
    /// `VPAUAggregateAudioDevice-…`) around whatever this process captures from.
    /// Its name is its UID and the UID changes every launch, so it is neither a
    /// microphone the user can pick nor a new device worth announcing.
    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeAggregate else { return false }
        address.mSelector = kAudioAggregateDevicePropertyComposition
        var composition: Unmanaged<CFDictionary>?
        size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &composition) == noErr,
              let dict = composition?.takeRetainedValue() as? [String: Any] else { return false }
        return (dict[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
    }

    /// Signal, never poll: CoreAudio tells us when the default input moves.
    public static func startMonitoringDefaultChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { _, _ in
            NotificationCenter.default.post(name: .voiceIQDefaultInputChanged, object: nil)
        }
    }

    public static func startMonitoringDeviceChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { _, _ in
            NotificationCenter.default.post(name: .voiceIQInputDevicesChanged, object: nil)
        }
    }

    public static func currentDefaultID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    /// Name of whatever the engine will actually record from right now.
    public static func currentDefaultName() -> String? {
        currentDefaultID().flatMap(name(of:))
    }

    @discardableResult
    public static func setDefault(id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
        )
        if status != noErr {
            Log.audio.error("AudioInputDevices: set default failed (\(status))")
        }
        return status == noErr
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let cfName = name?.takeRetainedValue() else {
            return nil
        }
        return cfName as String
    }

    static func uid(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let uid = value?.takeRetainedValue() else { return nil }
        return uid as String
    }
}
#endif
