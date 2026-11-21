#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Foundation
import Sauce

/// Types the text as key events, for the apps where a synthetic ⌘V fails:
///
///  - Microsoft's Windows App (formerly Microsoft Remote Desktop) reads ⌘V as
///    a bare "v". It forwards keys one by one, so the text is typed one
///    character at a time, a few milliseconds apart, with the key the layout
///    types it with.
///  - Chromium 155 and 156 can drop a ⌘V that races their own pasteboard
///    change notification (fixed in 157). They take whole runs of text per
///    event.
///
/// Adapted from Hex, MIT licence, Copyright (c) 2026 Christopher Langton
/// (github.com/anomalyco/hex, src/paste.rs and src/keyboard.rs).
public enum TypingInserter {
    public enum Mode: Equatable, Sendable {
        /// One character per key press, paced.
        case paced
        /// Up to 20 UTF-16 units per key event, no pauses.
        case burst
    }

    static let remoteDesktopClients: Set<String> = ["com.microsoft.rdc.macos", "com.microsoft.windowsapp"]
    static let clipboardRaceChromium: ClosedRange<Int> = 155...156
    /// The most UTF-16 units one key event carries.
    static let maxUnitsPerEvent = 20
    static let pacedGap: UInt64 = 4_000_000

    /// How to insert into this app, or nil to paste.
    public static func mode(bundleID: String?, bundleURL: URL?) -> Mode? {
        if let bundleID, remoteDesktopClients.contains(bundleID.lowercased()) { return .paced }
        guard let bundleURL else { return nil }
        return chromiumMajorVersions(in: bundleURL).contains(where: clipboardRaceChromium.contains) ? .burst : nil
    }

    /// Chromium browsers ship `Contents/Frameworks/<Name> Framework.framework/
    /// Versions/<major>.<minor>.<build>.<patch>/`. Every version present
    /// counts, so a browser with an update staged is covered either way.
    /// Electron's `Versions/A` has no version.
    static func chromiumMajorVersions(in bundle: URL) -> [Int] {
        let files = FileManager.default
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let names = (try? files.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.filter { $0.hasSuffix("Framework.framework") }.flatMap { name -> [Int] in
            let versions = frameworks.appendingPathComponent(name).appendingPathComponent("Versions")
            return ((try? files.contentsOfDirectory(atPath: versions.path)) ?? []).compactMap(chromiumMajorVersion)
        }
    }

    static func chromiumMajorVersion(_ version: String) -> Int? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts[0]
    }

    enum Stroke: Equatable {
        case text([UInt16])
        case lineBreak

        var text: String {
            switch self {
            case .text(let units): return String(utf16CodeUnits: units, count: units.count)
            case .lineBreak: return "\n"
            }
        }
    }

    /// The text as key strokes of at most `maxUnits` UTF-16 units, never
    /// splitting a surrogate pair. `\r\n`, `\n` and `\r` each become one line
    /// break, typed as Shift-Return so chat boxes add a line instead of sending.
    static func strokes(_ text: String, maxUnits: Int) -> [Stroke] {
        var strokes: [Stroke] = []
        var units: [UInt16] = []
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                if !units.isEmpty { strokes.append(.text(units)); units = [] }
                strokes.append(.lineBreak)
                continue
            }
            let encoded = Array(String(character).utf16)
            if !units.isEmpty, units.count + encoded.count > maxUnits {
                strokes.append(.text(units))
                units = []
            }
            units += encoded
        }
        if !units.isEmpty { strokes.append(.text(units)) }
        return strokes
    }

    /// Types `text` into the app in front. Paced typing checks before each
    /// character that `targetPID` is still in front and stops otherwise.
    /// Returns the text not typed: empty when all of it landed.
    @MainActor
    public static func type(_ text: String, mode: Mode, targetPID: pid_t?) async -> String {
        guard let source = CGEventSource(stateID: .privateState) else { return text }
        switch mode {
        case .burst:
            for stroke in strokes(text, maxUnits: maxUnitsPerEvent) {
                post(stroke, source: source, keyCode: 0, shift: false)
            }
            return ""
        case .paced:
            let keys = layoutKeys()
            let all = strokes(text, maxUnits: 1)
            for (index, stroke) in all.enumerated() {
                if let targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
                    Log.insertion.info("typing stopped: the app in front changed")
                    return all[index...].map(\.text).joined()
                }
                var key: (code: CGKeyCode, shift: Bool) = (0, false)
                if case .text = stroke, let typed = keys[stroke.text] {
                    key = typed
                }
                post(stroke, source: source, keyCode: key.code, shift: key.shift)
                try? await Task.sleep(nanoseconds: pacedGap)
            }
            return ""
        }
    }

    private static func post(_ stroke: Stroke, source: CGEventSource, keyCode: CGKeyCode, shift: Bool) {
        var events: [CGEvent] = []
        switch stroke {
        case .text(let units):
            if shift, let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: true) {
                down.flags = .maskShift
                events.append(down)
            }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
                event.flags = shift ? .maskShift : []
                events.append(event)
            }
            if shift, let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: false) {
                up.flags = []
                events.append(up)
            }
        case .lineBreak:
            // Shift goes down and up as real keys too: a remote session reads
            // key events, not just the flag.
            for (key, down) in [(kVK_Shift, true), (kVK_Return, true), (kVK_Return, false), (kVK_Shift, false)] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { return }
                event.flags = key == kVK_Shift && !down ? [] : .maskShift
                events.append(event)
            }
        }
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventTag.magic)
            event.post(tap: .cghidEventTap)
        }
    }

    /// The key (and whether Shift is held) the current layout types each
    /// character with, so a client that reads key codes gets the right key.
    /// The first key found wins, unshifted before shifted, and the numeric
    /// keypad (65–92) is never used: a Windows session with NumLock off reads
    /// keypad "." as Delete and keypad digits as arrows.
    @MainActor
    private static func layoutKeys() -> [String: (code: CGKeyCode, shift: Bool)] {
        var keys: [String: (code: CGKeyCode, shift: Bool)] = [:]
        for shift in [false, true] {
            for code in 0..<128 where !(65...92).contains(code) {
                guard let character = Sauce.shared.character(for: code, modifiers: .cocoa(shift ? [.shift] : [])),
                      !character.isEmpty, keys[character] == nil else { continue }
                keys[character] = (CGKeyCode(code), shift)
            }
        }
        return keys
    }
}
#endif
