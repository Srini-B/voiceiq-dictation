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
                    .frame(width: row.width, height: row.height)
                    .padding(.leading, row.minX)
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
            RecordingStrip(model: model, compact: compact, buttonHeight: buttonHeight)
                .frame(height: buttonHeight)
                .background(Capsule().fill(Color(.secondarySystemFill)))
                .clipShape(Capsule())
                .frame(maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                HStack(spacing: TypingBridge.buttonGap) {
                    ShortcutIconButton(
                        systemImage: showingEdit ? "keyboard" : Self.cursorSymbol,
                        label: showingEdit ? "Keyboard" : "Cursor control",
                        active: showingEdit,
                        height: buttonHeight
                    ) {
                        editOpen.toggle()
                    }
                    if typing.pasteInRow {
                        ShortcutIconButton(systemImage: Self.pasteLastSymbol, label: "Paste last dictation", height: buttonHeight) {
                            model.pasteLast()
                        }
                    }
                }
                .frame(width: typing.leadingEnd, alignment: .leading)

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
                .frame(width: TypingBridge.trailingEnd, alignment: .trailing)
            }
        }
    }

    /// The caret between two arrows: moving the cursor, not formatting text.
    static let cursorSymbol = "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right.fill"
    /// Text going in at the caret: the last dictation again (the cursor page's Paste is a clipboard).
    static let pasteLastSymbol = "text.insert"

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

    /// Three rows of one height with one gap between them, over the keys' width.
    private var editSurface: some View {
        VStack(spacing: compact ? 8 : 12) {
            EditPanel(editor: editor, pasteLast: model.pasteLast, pasteLastSymbol: Self.pasteLastSymbol)
            editBottomRow
        }
        .padding(.horizontal, typing.stripRow.minX)
        .padding(.top, compact ? 4 : 8)
        .padding(.bottom, compact ? 4 : 8)
    }

    private var editBottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobeKey {
                GlobeKey(controller: model.controller).frame(width: 44)
            }
            // Blank, as the letter pages' space bar is.
            KeyCap(title: "", label: "space") { editor.type(" ", as: .typing) }
            RepeatingKey(action: editor.deleteBackward).frame(width: 52)
            KeyCap(systemImage: "return", label: "Return") { editor.type("\n", as: .typing) }
                .frame(width: 52)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct ShortcutIconButton: View {
    let systemImage: String
    let label: String
    var active = false
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(width: TypingBridge.buttonWidth, height: height)
                .background(Capsule().fill(active ? KeyboardPalette.accent : KeyboardPalette.key))
                .shadow(color: .black.opacity(active ? 0 : 0.28), radius: 0, y: 1)
        }
        .buttonStyle(MicBarButtonStyle())
        .accessibilityLabel(label)
    }
}

/// VoiceiQ's blue pill with its mark: opens the app to dictate (or its setup without
/// Full Access); a spinner while the app starts or writes the text.
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
                    Image("DictateMark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: min(22, height - 10))
                }
            }
            .foregroundStyle(.white)
            .frame(width: TypingBridge.buttonWidth, height: height)
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
    let buttonHeight: CGFloat

    private var recording: Bool { model.phase == .recording }

    var body: some View {
        HStack(spacing: 8) {
            if recording {
                PillButton(
                    systemImage: "xmark",
                    label: "Cancel",
                    fill: KeyboardPalette.key,
                    foreground: .primary,
                    height: buttonHeight,
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
                PillButton(
                    systemImage: "stop.fill",
                    label: "Done",
                    fill: KeyboardPalette.recording,
                    foreground: .white,
                    height: buttonHeight,
                    action: model.micTapped
                )
            }
        }
        .background {
            if recording {
                LevelGlow(color: KeyboardPalette.recording)
            }
        }
    }
}

/// Cancel and Done: the same size as the Dictate pill they stand in for.
private struct PillButton: View {
    let systemImage: String
    let label: String
    let fill: Color
    let foreground: Color
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: TypingBridge.buttonWidth, height: height)
                .background(Capsule().fill(fill))
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
