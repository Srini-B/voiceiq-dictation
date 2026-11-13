import AppKit
import VoiceIQCore
import SwiftUI

struct ShortcutRecorderRow: View {
    let title: String
    let action: ShortcutAction

    private let store = ShortcutStore()
    // @State, not let: the struct is rebuilt on every render and a fresh UUID
    // would no longer own the capture it started.
    @State private var captureID = UUID()
    @State private var shortcut: KeyShortcut
    @State private var isRecording = false
    @State private var monitor: Any?

    init(action: ShortcutAction) {
        self.title = action.displayName
        self.action = action
        _shortcut = State(initialValue: ShortcutStore().shortcut(for: action))
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Button(isRecording ? "Press keys…" : shortcut.displayString) {
                    isRecording ? stopRecording() : startRecording()
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .controlSize(.small)

                if isRecording {
                    Button {
                        stopRecording()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                }

                Text("Side")
                SearchablePicker("", selection: sideBinding,
                                 options: KeyShortcut.Side.allCases.map { SearchOption(value: $0, name: $0.displayName) })

                Button {
                    stopRecording()
                    store.reset(action)
                    shortcut = store.shortcut(for: action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .help("Reset shortcut")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceIQShortcutDidChange)) { note in
            guard note.object as? ShortcutAction == action else { return }
            shortcut = store.shortcut(for: action)
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceIQShortcutCaptureDidBegin)) { note in
            if note.object as? UUID != captureID { stopRecording() }
        }
        .onDisappear { stopRecording() }
    }

    private var sideBinding: Binding<KeyShortcut.Side> {
        Binding(
            get: { shortcut.side },
            set: { side in
                let updated = KeyShortcut(
                    keyCode: shortcut.keyCode,
                    modifiers: shortcut.modifiers,
                    side: side
                )
                store.set(updated, for: action)
                shortcut = updated
            }
        )
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        ShortcutCapture.begin(owner: captureID)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.type == .keyDown else { return event }
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            guard let updated = KeyShortcut.recorded(from: event) else { return nil }
            store.set(updated, for: action)
            shortcut = updated
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        ShortcutCapture.end(owner: captureID)
    }
}

extension KeyShortcut {
    /// The combination a keyDown describes, or nil when no modifier is held
    /// (a bare letter is never a global shortcut).
    static func recorded(from event: NSEvent) -> KeyShortcut? {
        let modifiers = modifiers(from: event.modifierFlags)
        guard !modifiers.isEmpty else { return nil }
        let side = side(for: modifiers, rawFlags: event.modifierFlags.rawValue)
        return KeyShortcut(keyCode: event.keyCode, modifiers: modifiers, side: side)
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> Set<KeyShortcut.Modifier> {
        var result: Set<KeyShortcut.Modifier> = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private static func side(
        for modifiers: Set<KeyShortcut.Modifier>,
        rawFlags: UInt
    ) -> KeyShortcut.Side {
        let raw = UInt64(rawFlags)
        let masks: [KeyShortcut.Modifier: (left: UInt64, right: UInt64)] = [
            .command: (0x0008, 0x0010),
            .option: (0x0020, 0x0040),
            .control: (0x0001, 0x2000),
            .shift: (0x0002, 0x0004),
        ]
        let allLeft = modifiers.allSatisfy { raw & masks[$0]!.left != 0 && raw & masks[$0]!.right == 0 }
        if allLeft { return .left }
        let allRight = modifiers.allSatisfy { raw & masks[$0]!.right != 0 && raw & masks[$0]!.left == 0 }
        return allRight ? .right : .either
    }
}
