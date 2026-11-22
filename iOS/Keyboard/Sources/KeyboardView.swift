import SwiftUI
import UIKit
import VoiceIQBridge

/// The keyboard: Dictate through the VoiceiQ app, and an edit panel that
/// moves the cursor. It has no letter keys.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var offer: DictionaryOffer
    @ObservedObject var editor: EditController
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var editOpen = false

    private var compact: Bool { verticalSizeClass == .compact }

    /// Landscape on iPhone is shorter.
    static func height(compact: Bool) -> CGFloat { compact ? 136 : 164 }

    var body: some View {
        VStack(spacing: 8) {
            if editOpen, !isLive {
                EditPanel(editor: editor, rowHeight: keyHeight)
                    .frame(maxHeight: .infinity)
            } else {
                center.frame(maxHeight: .infinity)
            }
            bottomRow
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 8)
        .onChange(of: model.phase) { _, new in
            // A dictation started elsewhere shows its progress.
            if new == .recording || new == .processing { editOpen = false }
        }
    }

    private var keyHeight: CGFloat { compact ? 34 : 42 }
    private var barHeight: CGFloat { compact ? 44 : 56 }

    /// Recording, or writing the text while the app is running.
    private var isLive: Bool {
        model.hasFullAccess && (model.phase == .recording || (model.phase == .processing && !model.needsAppToFinish))
    }

    @ViewBuilder private var center: some View {
        if !model.hasFullAccess {
            VStack(spacing: 8) {
                Button("Allow Full Access") { model.micTapped() }
                    .buttonStyle(PrimaryPillStyle())
                Text("Settings › VoiceiQ › Keyboards")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 6) {
                Group {
                    if isLive {
                        RecordingStrip(model: model)
                            .frame(height: barHeight)
                            .background(Capsule().fill(Color(.secondarySystemFill)))
                            .clipShape(Capsule())
                    } else {
                        MicBar(phase: model.phase, waiting: model.waitingForApp, title: micTitle,
                               height: barHeight, action: model.micTapped)
                    }
                }
                .frame(maxWidth: 340)
                .frame(maxWidth: .infinity)

                Group {
                    if let notice = model.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(KeyboardPalette.recording)
                            .lineLimit(1)
                    } else if model.phase == .off || model.phase == .warm {
                        DictionaryOfferChip(offer: offer, selection: editor.selection)
                    }
                }
                .frame(height: DictionaryOfferChip.height)
            }
        }
    }

    private var micTitle: String {
        if model.waitingForApp, model.phase != .recording { return "Starting…" }
        switch model.phase {
        case .recording: return "Tap to finish"
        case .processing: return model.needsAppToFinish ? "Open VoiceiQ to finish" : "Writing…"
        case .warm, .off: return "Tap to speak"
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobeKey {
                GlobeKey(controller: model.controller).frame(width: 44)
            }
            KeyCap(systemImage: editOpen ? "mic" : "character.cursor.ibeam",
                   label: editOpen ? "Dictate" : "Edit", enabled: !isLive) {
                editOpen.toggle()
            }
            .frame(width: 44)
            KeyCap(systemImage: "doc.on.clipboard", label: "Paste last", enabled: model.lastText != nil) {
                model.pasteLast()
            }
            .frame(width: 44)
            KeyCap(title: "space") { editor.type(" ", as: .typing) }
            RepeatingKey(action: editor.deleteBackward).frame(width: 52)
            KeyCap(systemImage: "return", label: "Return") { editor.type("\n", as: .typing) }
                .frame(width: 52)
        }
        .frame(height: keyHeight)
    }
}

private struct MicBar: View {
    let phase: SessionSnapshot.Phase
    let waiting: Bool
    let title: String
    var height: CGFloat = 56
    /// Replaces the spoken label, which otherwise follows the phase.
    var label: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leadingContent
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(foregroundColor)
            .background(Capsule().fill(fillColor))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(MicBarButtonStyle())
        .accessibilityLabel(label ?? (phase == .recording ? "Stop" : phase == .processing ? title : "Dictate"))
    }

    @ViewBuilder private var leadingContent: some View {
        if phase == .processing || waiting {
            ProgressView().tint(phase == .processing ? KeyboardPalette.accent : .white)
        } else {
            Image(systemName: "mic.fill").font(.system(size: 18, weight: .semibold))
        }
    }

    private var fillColor: Color {
        switch phase {
        case .recording: return KeyboardPalette.recording
        case .processing: return Color(.secondarySystemFill)
        case .warm, .off: return KeyboardPalette.accent
        }
    }

    private var foregroundColor: Color {
        phase == .processing ? .primary : .white
    }
}

/// Stands in for the mic bar while a dictation runs: Cancel, the time over
/// a glow that rises with the voice, Done. With Real-time transcription the words heard so far replace the
/// time and the glow once they arrive. While the text is written: a spinner.
private struct RecordingStrip: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var recording: Bool { model.phase == .recording }
    /// The landscape strip is 44 pt tall.
    private var buttonSize: CGFloat { verticalSizeClass == .compact ? 32 : 40 }

    var body: some View {
        HStack(spacing: 8) {
            if recording {
                CircleButton(systemImage: "xmark", label: "Cancel", fill: Color(.secondarySystemFill),
                             foreground: .primary, size: buttonSize, action: model.cancelTapped)
            }
            Group {
                if !recording {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Writing…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                } else if !model.liveText.isEmpty {
                    // One line, newest words last.
                    Text(model.liveText)
                        .font(.system(size: 16))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Heard so far: \(model.liveText)")
                } else if let started = model.snapshot.recordingStartedAt {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity)
            if recording {
                CircleButton(systemImage: "stop.fill", label: "Done", fill: KeyboardPalette.recording,
                             foreground: .white, size: buttonSize, action: model.micTapped)
            }
        }
        .padding(.horizontal, 6)
        .background {
            if recording, model.liveText.isEmpty {
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
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
        }
        .buttonStyle(MicBarButtonStyle())
        .accessibilityLabel(label)
    }
}

private struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(Capsule().fill(KeyboardPalette.accent.opacity(configuration.isPressed ? 0.82 : 1)))
    }
}

private struct MicBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

