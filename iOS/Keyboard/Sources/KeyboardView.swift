import SwiftUI
import UIKit
import VoiceIQBridge

/// Top shortcut bar (cursor control, Paste last, Dictionary offer, Dictate hand-off
/// or VoiceiQ's LevelGlow recording strip) stacked above Hex's full QWERTY keyboard
/// (or VoiceiQ's cursor-control EditPanel when toggled open).
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var offer: DictionaryOffer
    @ObservedObject var editor: EditController
    @ObservedObject var typing: TypingBridge
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var editOpen = false

    private var compact: Bool { verticalSizeClass == .compact }

    static func topBarHeight(compact: Bool) -> CGFloat { compact ? 36 : 42 }

    /// Recording, or writing the text while the app is running.
    private var isLive: Bool {
        model.hasFullAccess && (model.phase == .recording || (model.phase == .processing && !model.needsAppToFinish))
    }

    private var showingEdit: Bool { editOpen && !isLive }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: Self.topBarHeight(compact: compact))
            ZStack {
                HexKeyboardRepresentable(bridge: typing)
                    .opacity(showingEdit ? 0 : 1)
                    .allowsHitTesting(!showingEdit)
                    .accessibilityHidden(showingEdit)

                if showingEdit {
                    editSurface
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.phase) { _, new in
            if new == .recording || new == .processing { editOpen = false }
        }
    }

    @ViewBuilder private var topBar: some View {
        if isLive {
            RecordingStrip(model: model, compact: compact)
                .frame(height: compact ? 32 : 36)
                .background(Capsule().fill(Color(.secondarySystemFill)))
                .clipShape(Capsule())
                .padding(.horizontal, 8)
                .padding(.vertical, compact ? 2 : 3)
        } else {
            shortcutBar
                .padding(.horizontal, 8)
                .padding(.vertical, compact ? 2 : 3)
        }
    }

    private var shortcutBar: some View {
        HStack(spacing: 6) {
            ShortcutIconButton(
                systemImage: showingEdit ? "keyboard" : "character.cursor.ibeam",
                label: showingEdit ? "Keyboard" : "Cursor control",
                active: showingEdit,
                compact: compact
            ) {
                editOpen.toggle()
            }

            ShortcutIconButton(
                systemImage: "doc.on.clipboard",
                label: "Paste last",
                enabled: model.lastText != nil,
                compact: compact
            ) {
                model.pasteLast()
            }

            centerSlot
                .frame(maxWidth: .infinity)

            DictatePillButton(
                phase: model.phase,
                waiting: model.waitingForApp,
                needsAppToFinish: model.needsAppToFinish,
                hasFullAccess: model.hasFullAccess,
                compact: compact,
                action: model.micTapped
            )
        }
    }

    @ViewBuilder private var centerSlot: some View {
        if !model.hasFullAccess {
            Button("Allow Full Access") { model.micTapped() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KeyboardPalette.accent)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: compact ? 28 : 32)
                .background(Capsule().fill(KeyboardPalette.accent.opacity(0.14)))
                .buttonStyle(.plain)
        } else if let notice = model.notice {
            Text(notice)
                .font(.caption.weight(.medium))
                .foregroundStyle(KeyboardPalette.recording)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if offer.feedback != nil || offer.offer(selection: editor.selection) != nil {
            DictionaryOfferChip(offer: offer, selection: editor.selection)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var editRowHeight: CGFloat { compact ? 38 : 48 }
    private var editBottomHeight: CGFloat { compact ? 34 : 42 }

    private var editSurface: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            EditPanel(editor: editor, rowHeight: editRowHeight)
            Spacer(minLength: 0)
            editBottomRow
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 8)
    }

    private var editBottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobeKey {
                GlobeKey(controller: model.controller).frame(width: 44)
            }
            KeyCap(title: "space") { editor.type(" ", as: .typing) }
            RepeatingKey(action: editor.deleteBackward).frame(width: 52)
            KeyCap(systemImage: "return", label: "Return") { editor.type("\n", as: .typing) }
                .frame(width: 52)
        }
        .frame(height: editBottomHeight)
    }
}

private struct ShortcutIconButton: View {
    let systemImage: String
    let label: String
    var active = false
    var enabled = true
    let compact: Bool
    let action: () -> Void

    private var height: CGFloat { compact ? 30 : 34 }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 14 : 15, weight: .medium))
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(width: compact ? 34 : 38, height: height)
                .background(
                    Capsule().fill(active ? KeyboardPalette.accent : Color(.secondarySystemFill))
                )
        }
        .buttonStyle(MicBarButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
        .accessibilityLabel(label)
    }
}

private struct DictatePillButton: View {
    let phase: SessionSnapshot.Phase
    let waiting: Bool
    let needsAppToFinish: Bool
    let hasFullAccess: Bool
    let compact: Bool
    let action: () -> Void

    private var height: CGFloat { compact ? 30 : 34 }

    private var title: String {
        if !hasFullAccess { return "Dictate" }
        if waiting, phase != .recording { return "Starting…" }
        if phase == .processing { return needsAppToFinish ? "Open VoiceiQ" : "Writing…" }
        return "Dictate"
    }

    private var showsSpinner: Bool {
        hasFullAccess && (phase == .processing || (waiting && phase != .recording))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if showsSpinner {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(phase == .processing ? KeyboardPalette.accent : .white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: compact ? 13 : 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(phase == .processing ? Color.primary : Color.white)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: height)
            .background(
                Capsule().fill(phase == .processing ? Color(.secondarySystemFill) : KeyboardPalette.accent)
            )
        }
        .buttonStyle(MicBarButtonStyle())
        .accessibilityLabel(title)
    }
}

/// Stands in for the top shortcut bar while a dictation runs: Cancel, elapsed
/// time over VoiceiQ's LevelGlow waveform that rises with the voice, Done.
/// While the text is written: a spinner and "Writing…".
private struct RecordingStrip: View {
    @ObservedObject var model: KeyboardModel
    let compact: Bool

    private var recording: Bool { model.phase == .recording }
    private var buttonSize: CGFloat { compact ? 26 : 30 }

    var body: some View {
        HStack(spacing: 8) {
            if recording {
                CircleButton(
                    systemImage: "xmark",
                    label: "Cancel",
                    fill: Color(.secondarySystemFill),
                    foreground: .primary,
                    size: buttonSize,
                    action: model.cancelTapped
                )
            }
            Group {
                if !recording {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Writing…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                } else if let started = model.snapshot.recordingStartedAt {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.system(size: compact ? 14 : 15, weight: .semibold).monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity)
            if recording {
                CircleButton(
                    systemImage: "stop.fill",
                    label: "Done",
                    fill: KeyboardPalette.recording,
                    foreground: .white,
                    size: buttonSize,
                    action: model.micTapped
                )
            }
        }
        .padding(.horizontal, 4)
        .background {
            if recording {
                LevelGlow(color: KeyboardPalette.recording)
            }
        }
    }
}

private struct CircleButton: View {
    let systemImage: String
    let label: String
    let fill: Color
    let foreground: Color
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
        }
        .buttonStyle(MicBarButtonStyle())
        .accessibilityLabel(label)
    }
}

private struct MicBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
