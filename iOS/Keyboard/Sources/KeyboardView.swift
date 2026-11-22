import SwiftUI
import UIKit
import VoiceIQBridge

enum KeyboardPalette {
    static let accentUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.341, green: 0.525, blue: 0.941, alpha: 1)
            : UIColor(red: 0.133, green: 0.322, blue: 0.737, alpha: 1)
    }
    static let accent = Color(accentUIColor)
    static let recording = Color(red: 0.92, green: 0.26, blue: 0.21)
    static let keyUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray4 : .systemBackground
    }
    static let key = Color(keyUIColor)
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var offer: DictionaryOffer
    @ObservedObject var typing: TypingController

    private enum Panel { case keys, voice, emoji, edit, answer }

    private var panel: Panel {
        if model.answer != nil { return .answer }
        if !isLive, typing.voiceOpen || model.phase == .recording || model.phase == .processing
            || (model.waitingForApp && !typing.dictationKeyStarting) { return .voice }
        if typing.emojiQuery != nil { return .keys }
        if typing.showsEdit { return .edit }
        return typing.showsEmoji ? .emoji : .keys
    }

    /// The mini keyboard's keys: only typing on a text field. Panels, the
    /// voice screen, emoji search, which types letters, and number pads use
    /// the full height.
    private var showsMini: Bool {
        typing.mini && panel == .keys && typing.emojiQuery == nil && !typing.isDigitPad
    }

    /// The mic bar's room above and below it, so the keyboard's edge is as far
    /// above it as the mini keys' first row (6 pt into `MiniKeys`) is below it.
    static func miniBarInsets(compact: Bool) -> (top: CGFloat, bottom: CGFloat) {
        let bottom: CGFloat = compact ? 2 : 7
        return (bottom + MiniKeys.topInset, bottom)
    }

    static func miniBarHeight(compact: Bool) -> CGFloat {
        let insets = miniBarInsets(compact: compact)
        return insets.top + MicBar.height(compact: compact) + insets.bottom
    }

    /// Hex's keys with VoiceiQ's buttons in their strip: one row above the keys.
    private var showsHexKeys: Bool { panel == .keys && !showsMini && !typing.isDigitPad }

    /// What covers Hex's strip: a recording or the emoji search all of it, the
    /// Dictionary offer the suggestions.
    private var stripCover: TypingController.StripCover {
        guard showsHexKeys else { return .none }
        if isLive || typing.emojiQuery != nil { return .all }
        return showsOffer ? .suggestions : .none
    }

    var body: some View {
        Group {
            if showsHexKeys {
                KeysArea(typing: typing).overlay(alignment: .topLeading) { stripOverlay }
            } else {
                VStack(spacing: 0) {
                    if showsMini {
                        // Recording or not, the content sits where the mic bar does,
                        // as far above it as below, and up with iOS's band.
                        let insets = Self.miniBarInsets(compact: typing.compact)
                        Group {
                            if isLive { RecordingStrip(model: model, size: typing.stripBar.height) } else { miniBar }
                        }
                        .frame(height: MicBar.height(compact: typing.compact))
                        .padding(.top, insets.top - typing.bandShift)
                        .padding(.bottom, insets.bottom + typing.bandShift)
                    } else {
                        // In the strip's place, spaced as the strip is.
                        let bar = typing.stripBar.height > 0 ? typing.stripBar : CGRect(x: 0, y: 0, width: 0, height: typing.stripArea)
                        Group {
                            if isLive { RecordingStrip(model: model, size: bar.height) } else { topBar }
                        }
                        .frame(height: bar.height)
                        .padding(.top, bar.minY)
                        .padding(.bottom, max(0, typing.stripArea - bar.maxY))
                    }
                    panelContent.frame(maxHeight: .infinity)
                }
            }
        }
        .onChange(of: showsMini, initial: true) { _, mini in typing.showsMini = mini }
        .onChange(of: stripCover, initial: true) { _, cover in typing.stripCover = cover }
        .onChange(of: model.waitingForApp) { _, waiting in if !waiting { typing.dictationKeyStarting = false } }
        .onChange(of: model.phase) { old, new in
            // A finished session goes back to the keys.
            if old == .processing, new == .off || new == .warm { typing.voiceOpen = false }
        }
    }

    /// Over Hex's strip: the recording, the emoji search or the Dictionary offer.
    @ViewBuilder private var stripOverlay: some View {
        let bar = typing.stripBar
        switch stripCover {
        case .all:
            Group {
                if isLive { RecordingStrip(model: model, size: bar.height) } else { EmojiSearchBar(typing: typing) }
            }
            .frame(width: bar.width, height: bar.height)
            .offset(x: bar.minX, y: bar.minY)
        case .suggestions:
            DictionaryOfferChip(offer: offer, selection: typing.selection)
                .frame(width: typing.stripSlots.width, height: bar.height)
                .offset(x: typing.stripSlots.minX, y: bar.minY)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var panelContent: some View {
                switch panel {
                case .answer:
                    if let answer = model.answer { AnswerPanel(answer: answer, model: model).padding(8) }
                case .voice:
                    VStack(spacing: 8) {
                        Spacer(minLength: 0)
                        center
                        Spacer(minLength: 0)
                        bottomRow
                    }
                    .padding(8)
                case .emoji:
                    EmojiPanel(typing: typing)
                case .edit:
                    EditPanel(typing: typing)
                case .keys where showsMini:
                    MiniKeys(typing: typing, showsGlobe: model.showsGlobeKey, controller: model.controller)
                case .keys where typing.isDigitPad:
                    DigitPad(typing: typing, showsGlobe: model.showsGlobeKey, controller: model.controller)
                case .keys:
                    KeysArea(typing: typing)
                }
    }

    /// Recording, or writing the text while the app is running.
    private var isLive: Bool {
        model.hasFullAccess && (model.phase == .recording || (model.phase == .processing && !model.needsAppToFinish))
    }

    private var showsOffer: Bool {
        if offer.feedback != nil { return true }
        switch offer.offer(selection: typing.selection) {
        case .selection: return true
        case .copied: return !typing.typedSinceAppear
        case nil: return false
        }
    }

    private var topBar: some View {
        HStack(spacing: 2) {
            BarButton(systemImage: panel == .voice ? "keyboard" : "waveform",
                      label: panel == .voice ? "Keyboard" : "VoiceiQ") {
                typing.voiceOpen.toggle()
                typing.showsEmoji = false
                typing.showsEdit = false
                typing.emojiQuery = nil
            }
            Group {
                switch panel {
                case .voice:
                    ModePicker(mode: $model.mode, locked: model.phase == .recording || model.phase == .processing)
                case .keys where typing.emojiQuery != nil:
                    EmojiSearchBar(typing: typing)
                case .keys where showsOffer:
                    DictionaryOfferChip(offer: offer, selection: typing.selection)
                default:
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if panel != .voice, typing.emojiQuery == nil {
                BarButton(systemImage: panel == .edit ? "keyboard" : "character.cursor.ibeam",
                          label: panel == .edit ? "Keyboard" : "Edit") {
                    typing.showsEmoji = false
                    typing.showsEdit.toggle()
                }
            }
            if panel != .voice {
                BarButton(systemImage: "mic.fill", label: "Dictate", action: model.micTapped)
            } else if typing.stripBar.width > 0, typing.stripBar.width < StripButton.narrowBar {
                // The strip has no room for it on a narrow keyboard.
                BarButton(systemImage: StripButton.mini.symbol, label: StripButton.mini.label) {
                    typing.voiceOpen = false
                    if !typing.mini { typing.toggleMini() }
                }
            } else {
                Color.clear.frame(width: 40)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Leads the mini keyboard: the voice screen's button and the mic bar.
    private var miniBar: some View {
        HStack(spacing: 4) {
            BarButton(systemImage: "waveform", label: "VoiceiQ") {
                typing.voiceOpen = true
                typing.showsEmoji = false
                typing.showsEdit = false
            }
            // Without Full Access the bar asks for it, and VoiceOver should say so.
            MicBar(phase: model.phase, waiting: model.waitingForApp, title: micTitle,
                   height: MicBar.height(compact: typing.compact), label: model.hasFullAccess ? nil : micTitle, action: model.micTapped)
        }
        .padding(.leading, 4)
        .padding(.trailing, 7)
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
                HStack(spacing: 8) {
                    Color.clear.frame(width: 36, height: 36)
                    MicBar(
                        phase: model.phase,
                        waiting: model.waitingForApp,
                        title: micTitle,
                        action: model.micTapped
                    )
                    .frame(maxWidth: 300)
                    Color.clear.frame(width: 36, height: 36)
                }
                .frame(maxWidth: .infinity)

                Group {
                    if let notice = model.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(KeyboardPalette.recording)
                            .lineLimit(1)
                    } else if model.phase == .off || model.phase == .warm {
                        DictionaryOfferChip(offer: offer, selection: typing.selection)
                    }
                }
                .frame(height: DictionaryOfferChip.height)
            }
        }
    }

    private var micTitle: String {
        if !model.hasFullAccess { return "Allow Full Access" }
        if model.waitingForApp, model.phase != .recording { return "Starting…" }
        switch model.phase {
        case .recording: return "Tap to finish"
        case .processing where model.needsAppToFinish: return "Open VoiceiQ to finish"
        case .processing: return model.mode == .ask ? "Thinking…" : "Writing…"
        case .warm, .off:
            switch model.mode {
            case .dictate: return "Tap to speak"
            case .translate: return "Tap to translate"
            case .ask: return "Tap to ask"
            }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobeKey {
                GlobeKey(controller: model.controller).frame(width: 44)
            }
            KeyCap(systemImage: "doc.on.clipboard", label: "Paste last", enabled: model.lastText != nil) {
                model.pasteLast()
            }
            .frame(width: 44)
            KeyCap(title: "space") { model.insertSpace() }
            RepeatingKey(action: model.deleteBackward).frame(width: 52)
            KeyCap(systemImage: "return", label: "Return") { model.insertReturn() }
                .frame(width: 52)
        }
        .frame(height: 42)
    }
}

private struct ModePicker: View {
    @Binding var mode: KeyboardMode
    let locked: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(KeyboardMode.allCases, id: \.self) { item in
                Button {
                    mode = item
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if mode == item {
                                Capsule().fill(KeyboardPalette.accent.opacity(0.16))
                            }
                        }
                        .foregroundStyle(mode == item ? KeyboardPalette.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(locked)
            }
        }
        .padding(2)
        .frame(maxWidth: 286, maxHeight: 32)
        .background(Capsule().fill(Color(.secondarySystemFill)))
        .opacity(locked ? 0.7 : 1)
        .frame(maxWidth: .infinity)
    }
}

private struct MicBar: View {
    let phase: SessionSnapshot.Phase
    let waiting: Bool
    let title: String
    var height: CGFloat = 56
    /// The mini keyboard's mic bar.
    static func height(compact: Bool) -> CGFloat { compact ? 36 : 46 }
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

private struct AnswerPanel: View {
    let answer: Delivery
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                Text(answer.text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Close", action: model.dismissAnswer).buttonStyle(AnswerButtonStyle())
                Spacer()
                Button("Copy", action: model.copyAnswer).buttonStyle(AnswerButtonStyle())
                Button("Insert", action: model.insertAnswer).buttonStyle(AnswerButtonStyle(primary: true))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
}

/// Stands in for the suggestion bar while a dictation runs, with the keys
/// still below it: Cancel, the time over a glow that rises with the voice,
/// Done. With Real-time transcription the words heard so far replace the
/// time and the glow once they arrive. While the text is written: a spinner.
private struct RecordingStrip: View {
    @ObservedObject var model: KeyboardModel
    /// The strip's height: its buttons fit inside it, as Hex's pills do.
    let size: CGFloat

    private var recording: Bool { model.phase == .recording }
    private var buttonSize: CGFloat { size > 0 ? min(32, size - 1) : 32 }

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
                        Text(model.mode == .ask ? "Thinking…" : "Writing…")
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

private struct BarButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(KeyboardPalette.accent)
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

private struct AnswerButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(primary ? KeyboardPalette.accent : Color(.secondarySystemFill)))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct MicBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

