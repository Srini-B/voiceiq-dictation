import SwiftUI
import UIKit
import VoiceIQBridge

/// Hex's QWERTY keyboard with VoiceiQ's shortcuts in its suggestion row: cursor
/// control and Paste last at the left end, Dictate (handing off to the app) at the
/// right, suggestions between them. While a dictation runs, VoiceiQ's recording
/// strip takes the whole row; cursor control swaps the keys for the edit panel.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var offer: DictionaryOffer
    @ObservedObject var editor: EditController
    @ObservedObject var typing: TypingBridge
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var editOpen = false

    private var compact: Bool { verticalSizeClass == .compact }

    /// Recording, or writing the text while the app is running.
    private var isLive: Bool {
        model.hasFullAccess && (model.phase == .recording || (model.phase == .processing && !model.needsAppToFinish))
    }

    private var showingEdit: Bool { editOpen && !isLive }

    private var showsOffer: Bool {
        offer.feedback != nil || offer.offer(selection: editor.selection) != nil
    }

    /// VoiceiQ shows something of its own where Hex's suggestions are.
    private var coversSuggestions: Bool {
        isLive || showingEdit || model.needsAppToFinish || model.notice != nil || showsOffer
    }

    var body: some View {
        let row = typing.stripRow
        ZStack(alignment: .topLeading) {
            HexKeyboardRepresentable(bridge: typing)
                .opacity(showingEdit ? 0 : 1)
                .allowsHitTesting(!showingEdit)
                .accessibilityHidden(showingEdit)

            if showingEdit {
                editSurface
                    .padding(.top, row.maxY)
            }

            if row.height > 0, !typing.emojiOpen {
                suggestionRow
                    .padding(.horizontal, typing.sideInset)
                    .frame(maxWidth: .infinity)
                    .frame(height: row.height)
                    .padding(.top, row.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.phase) { _, new in
            if new == .starting || new == .recording || new == .processing { editOpen = false }
        }
        .onChange(of: coversSuggestions, initial: true) { _, covered in
            typing.setSuggestionsHidden(covered)
        }
    }

    @ViewBuilder private var suggestionRow: some View {
        if isLive {
            RecordingStrip(model: model, compact: compact)
                .frame(height: buttonHeight)
                .background(Capsule().fill(Color(.secondarySystemFill)))
                .clipShape(Capsule())
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    ShortcutIconButton(
                        systemImage: showingEdit ? "keyboard" : "character.cursor.ibeam",
                        label: showingEdit ? "Keyboard" : "Cursor control",
                        active: showingEdit,
                        height: buttonHeight
                    ) {
                        editOpen.toggle()
                    }
                    ShortcutIconButton(
                        systemImage: "doc.on.clipboard",
                        label: "Paste last dictation",
                        enabled: model.lastText != nil,
                        height: buttonHeight
                    ) {
                        model.pasteLast()
                    }
                }
                .padding(.leading, 6)
                .frame(width: TypingBridge.leadingEnd, alignment: .leading)

                // Clear, so touches between the ends reach Hex's suggestions underneath.
                ZStack { Color.clear; centerSlot }
                    .frame(maxWidth: .infinity)

                DictateButton(
                    phase: model.phase,
                    waiting: model.waitingForApp,
                    hasFullAccess: model.hasFullAccess,
                    height: buttonHeight,
                    action: model.micTapped
                )
                .padding(.trailing, 6)
                .frame(width: TypingBridge.trailingEnd, alignment: .trailing)
            }
        }
    }

    /// As tall as Hex's suggestion capsule, so the row reads as one bar.
    private var buttonHeight: CGFloat {
        min(compact ? 30 : 34, max(24, typing.stripRow.height - 8))
    }

    @ViewBuilder private var centerSlot: some View {
        if model.needsAppToFinish {
            Button("Open VoiceiQ to finish", action: model.micTapped)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KeyboardPalette.accent)
                .lineLimit(1)
                .buttonStyle(.plain)
        } else if let notice = model.notice {
            Text(notice)
                .font(.caption.weight(.medium))
                .foregroundStyle(KeyboardPalette.recording)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
        } else if showsOffer, !showingEdit {
            DictionaryOfferChip(offer: offer, selection: editor.selection)
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
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(width: 36, height: height)
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

/// VoiceiQ's blue mic: opens the app to dictate (or its setup without Full Access);
/// a spinner while the app starts or writes the text.
private struct DictateButton: View {
    let phase: SessionSnapshot.Phase
    let waiting: Bool
    let hasFullAccess: Bool
    let height: CGFloat
    let action: () -> Void

    private var writing: Bool { hasFullAccess && phase == .processing }
    private var starting: Bool { hasFullAccess && (phase == .starting || (waiting && phase != .recording)) }

    var body: some View {
        Button(action: action) {
            Group {
                if writing || starting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(writing ? KeyboardPalette.accent : .white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 46, height: height)
            .background(Capsule().fill(writing ? Color(.secondarySystemFill) : KeyboardPalette.accent))
        }
        .buttonStyle(MicBarButtonStyle())
        .accessibilityLabel(writing ? "Writing" : starting ? "Starting" : hasFullAccess ? "Dictate" : "Allow Full Access to dictate")
    }
}

/// Stands in for the suggestion row while a dictation runs: Cancel, elapsed
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
