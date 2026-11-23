#if os(macOS)
import CoreAudio
import Foundation
import IOKit

/// A closed MacBook lid turns the built-in mic off, but macOS keeps it listed
/// and as the default input, so a dictation records digital silence. Hex
/// (anomalyco/hex, `src/audio/lid.rs`, MIT) reads the same clamshell flag.
public enum MacLid {
    /// True only on a MacBook whose lid is shut. Desktops have no clamshell state.
    public static var isClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// The lid is shut and the default input is the Mac's own mic, not a
    /// headset on the jack, so nothing it records can be speech.
    public static var mutesDefaultInput: Bool {
        guard isClosed, let id = AudioInputDevices.currentDefaultID() else { return false }
        return isInternalMic(id)
    }

    private static func isInternalMic(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        // Intel Macs share one built-in input between the mic ('imic') and the
        // headset jack ('emic'); Apple silicon lists the jack as its own device.
        address.mSelector = kAudioDevicePropertyDataSource
        address.mScope = kAudioDevicePropertyScopeInput
        var source: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source) == noErr, source == 0x656D_6963 { // 'emic'
            return false
        }
        return !(AudioInputDevices.uid(of: id)?.contains("Headphone") ?? false)
    }
}
#endif
