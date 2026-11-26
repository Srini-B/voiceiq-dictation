#if os(macOS)
import AppKit
import ApplicationServices
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

    public enum Result: Equatable, Sendable {
        case typed
        /// The app in front changed part way; `rest` was not typed.
        case stopped(rest: String)
        /// Nothing was typed: some character has no key on the layout (a
        /// remote session that reads key codes would get the wrong key), or
        /// the focused window can't be watched.
        case unsupported
    }

    /// Typographic punctuation the writing model produces, as the plain keys
    /// a remote session can type.
    static let plainPunctuation: [Character: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"",
        "\u{2013}": "-", "\u{2014}": "-", "\u{2026}": "...", "\u{00A0}": " ",
    ]

    static func plain(_ text: String) -> String {
        text.reduce(into: "") { out, character in out += plainPunctuation[character] ?? String(character) }
    }

    /// Types `text` into the app in front. Paced typing checks before each
    /// character that `targetPID` is still in front with the same focused
    /// window (Windows App opens one per remote session), and stops otherwise.
    @MainActor
    public static func type(_ text: String, mode: Mode, targetPID: pid_t?) async -> Result {
        guard KeystrokeAccess.mayPost else {
            Log.insertion.warning("no System & App Protection Override grant — nothing typed")
            return .unsupported
        }
        guard let source = CGEventSource(stateID: .privateState) else { return .unsupported }
        switch mode {
        case .burst:
            for stroke in strokes(text, maxUnits: maxUnitsPerEvent) {
                post(stroke, source: source, keyCode: 0, shift: false)
            }
            return .typed
        case .paced:
            let keys = layoutKeys()
            let all = strokes(plain(text), maxUnits: 1)
            if let missing = all.first(where: { $0 != .lineBreak && keys[$0.text] == nil }) {
                Log.insertion.info("not typing: no key for U+\(String(missing.text.unicodeScalars.first?.value ?? 0, radix: 16, uppercase: true), privacy: .public) on this layout")
                return .unsupported
            }
            let app = targetPID.map(AXUIElementCreateApplication)
            // An app that stops answering must not hold the main actor; a
            // timeout reads as a changed window and stops the typing.
            if let app { AXUIElementSetMessagingTimeout(app, 0.25) }
            let startWindow = app.flatMap(focusedWindow(of:))
            if app != nil, startWindow == nil {
                // Without the window there is no telling when the user moves
                // to another remote session part way.
                Log.insertion.info("not typing: the focused window can't be read")
                return .unsupported
            }
            for (index, stroke) in all.enumerated() {
                var movedApp = false
                if let targetPID { movedApp = NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID }
                var movedWindow = false
                if let app, let startWindow {
                    let window = focusedWindow(of: app)
                    movedWindow = window.map { !CFEqual(startWindow, $0) } ?? true
                }
                if movedApp || movedWindow {
                    Log.insertion.info("typing stopped: the \(movedApp ? "app" : "window", privacy: .public) in front changed")
                    return .stopped(rest: all[index...].map(\.text).joined())
                }
                let key = keys[stroke.text] ?? (code: 0, shift: false)
                post(stroke, source: source, keyCode: key.code, shift: key.shift)
                try? await Task.sleep(nanoseconds: pacedGap)
            }
            return .typed
        }
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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

    /// The key codes that type characters: the ANSI/ISO block and the two
    /// JIS keys. Sauce labels the others (Return "↩", Space "␣", Delete "⌫",
    /// the function keys) with symbols, and the numeric keypad (65–92) would
    /// reach a Windows session with NumLock off as arrows, with "." as Delete.
    static let characterKeyCodes: [Int] = (0...50).filter { ![kVK_Return, kVK_Tab, kVK_Space].contains($0) }
        + [kVK_JIS_Yen, kVK_JIS_Underscore]

    /// The key (and whether Shift is held) the current layout types each
    /// character with, so a client that reads key codes gets the right key.
    /// The first key found wins, unshifted before shifted.
    @MainActor
    static func layoutKeys() -> [String: (code: CGKeyCode, shift: Bool)] {
        var keys: [String: (code: CGKeyCode, shift: Bool)] = [" ": (CGKeyCode(kVK_Space), false)]
        for shift in [false, true] {
            for code in characterKeyCodes {
                guard let character = Sauce.shared.character(for: code, modifiers: .cocoa(shift ? [.shift] : [])),
                      character.count == 1, keys[character] == nil else { continue }
                keys[character] = (CGKeyCode(code), shift)
            }
        }
        return keys
    }
}
#endif
