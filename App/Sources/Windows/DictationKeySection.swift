import AppKit
import AVFoundation
import VoiceIQCore
import SwiftUI

/// The dictation key, recorded by pressing it like the other shortcuts. A
/// bare modifier (fn, ⌘, ⌥, ⌃ on either side; the side is part of the key) or
/// a modifier-plus-key combination both qualify. Combos already bound to
/// another shortcut are refused so two taps never race for one keystroke.
struct DictationKeySection: View {
    private let settings = SettingsStore()
    private let shortcuts = ShortcutStore()
    // @State, not let: the struct is rebuilt on every render and a fresh UUID
    // would no longer own the capture it started.
    @State private var captureID = UUID()
    @State private var trigger = SettingsStore().dictationTrigger
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var conflict: String?
    @State private var pendingModifier: HotkeyKey?

    var body: some View {
        Section("Dictation key") {
            LabeledContent("Press to start and stop") {
                HStack(spacing: 8) {
                    Button(isRecording ? "Press a key…" : trigger.displayName) {
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

                    if case .combo(let shortcut) = trigger {
                        Text("Side")
                        SearchablePicker("", selection: sideBinding(shortcut),
                                         options: KeyShortcut.Side.allCases.map { SearchOption(value: $0, name: $0.displayName) })
                    }

                    Button {
                        stopRecording()
                        apply(.default)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Reset to fn")
                }
            }
            if let conflict {
                Text(conflict)
                    .font(.caption)
                    .foregroundStyle(VoiceIQUI.Colors.error)
            }
        }
        .onAppear { trigger = settings.dictationTrigger }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: .voiceIQShortcutCaptureDidBegin)) { note in
            if note.object as? UUID != captureID { stopRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            switch note.object as? String {
            case "dictationTrigger": trigger = settings.dictationTrigger
            default: break
            }
        }
    }

    private func sideBinding(_ shortcut: KeyShortcut) -> Binding<KeyShortcut.Side> {
        Binding(
            get: { shortcut.side },
            set: { side in
                apply(.combo(KeyShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, side: side)))
            }
        )
    }

    private func apply(_ newTrigger: DictationTrigger) {
        settings.setDictationTrigger(newTrigger)
        trigger = newTrigger
        conflict = nil
    }

    /// The shortcut row already using this combination, if any. Sides are
    /// ignored on purpose: two taps racing for the same key is the problem,
    /// and a sided variant of a bound combo still collides on "either".
    private func boundAction(for shortcut: KeyShortcut) -> ShortcutAction? {
        ShortcutAction.allCases.first {
            let bound = shortcuts.shortcut(for: $0)
            return bound.keyCode == shortcut.keyCode && bound.modifiers == shortcut.modifiers
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        conflict = nil
        ShortcutCapture.begin(owner: captureID)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }
                pendingModifier = nil
                guard let shortcut = KeyShortcut.recorded(from: event) else { return nil }
                if let taken = boundAction(for: shortcut) {
                    conflict = "\(shortcut.displayString) is already used by \(taken.displayName)."
                    return nil
                }
                apply(.combo(shortcut))
                stopRecording()
                return nil
            case .flagsChanged:
                guard let key = HotkeyKey(keyCode: Int64(event.keyCode)) else { return event }
                // Modifier keys report a flagsChanged on press and again on
                // release; the press is the one where the key's own flag is set.
                // A modifier going down may be the start of a combo, so the
                // decision waits for its release with no other key in between.
                guard !key.isDown(in: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) else {
                    // A second modifier means a chord, not a single key.
                    pendingModifier = pendingModifier == nil ? key : nil
                    return nil
                }
                guard pendingModifier == key else { return nil }
                pendingModifier = nil
                apply(.modifier(key))
                stopRecording()
                return nil
            default:
                return event
            }
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        pendingModifier = nil
        ShortcutCapture.end(owner: captureID)
    }
}

/// Live status of the permissions dictation depends on. A revoked grant used
/// to be visible only from the menu bar; here each row opens the matching
/// System Settings pane and updates on its own once the grant lands.
struct PermissionsSection: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Permissions") {
            PermissionRow(title: "Accessibility", granted: accessibility, settingsAnchor: "Privacy_Accessibility")
            PermissionRow(title: "Screen Recording", granted: screenRecording, settingsAnchor: "Privacy_ScreenCapture")
            PermissionRow(title: "Microphone", granted: microphone, settingsAnchor: "Privacy_Microphone")
        }
        .onReceive(poll) { _ in refresh() }
        .onAppear { refresh() }
    }

    private func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let settingsAnchor: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle" : "xmark.circle.fill")
                    .foregroundStyle(granted ? AnyShapeStyle(.secondary) : AnyShapeStyle(VoiceIQUI.Colors.error))
                Text(granted ? "Granted" : "Not granted")
                    .foregroundStyle(.secondary)
                if !granted {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")!)
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
