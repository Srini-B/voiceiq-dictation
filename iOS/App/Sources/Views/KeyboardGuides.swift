import SwiftUI

// Animated how-tos for the two things iOS makes the user do by hand: turning
// the keyboard on in Settings, and switching to it with the globe key. Both
// are simple drawings in the app's own tokens that loop while on screen; with
// Reduce Motion each holds its most telling frame.

/// VoiceiQ's page in Settings, then Keyboards: the VoiceiQ switch, Allow Full
/// Access and its alert, with a caption for each step under the drawing.
struct KeyboardSettingsWalkthrough: View {
    @State private var phase = Phase.appPage

    enum Phase: Int, CaseIterable, LoopPhase {
        case appPage, tapKeyboards, keyboardsPage, voiceIQOn, tapFullAccess, alert, tapAllow, done

        var hold: Double {
            switch self {
            case .appPage: return 1.2
            case .tapKeyboards, .tapFullAccess, .tapAllow: return 0.6
            case .keyboardsPage: return 0.8
            case .voiceIQOn: return 1.0
            case .alert: return 1.3
            case .done: return 2.2
            }
        }

        /// Which caption line this frame illustrates.
        var instruction: Int {
            switch self {
            case .appPage, .tapKeyboards: return 0
            case .keyboardsPage, .voiceIQOn: return 1
            case .tapFullAccess, .alert, .tapAllow, .done: return 2
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            screen
                .frame(height: 216)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                GuideInstruction(number: 1, text: Text("Tap **Keyboards**"), current: phase.instruction == 0)
                GuideInstruction(number: 2, text: Text("Turn on **VoiceiQ**"), current: phase.instruction == 1)
                GuideInstruction(number: 3, text: Text("Turn on **Allow Full Access**, then tap **Allow**"), current: phase.instruction == 2)
            }
        }
        .loopingPhases($phase, still: .done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In VoiceiQ's page in Settings, tap Keyboards, turn on VoiceiQ, then turn on Allow Full Access and tap Allow.")
    }

    private var screen: some View {
        ZStack {
            Theme.Colors.grouped
            if phase.rawValue < Phase.keyboardsPage.rawValue {
                appPage.transition(.move(edge: .leading))
            } else {
                keyboardsPage.transition(.move(edge: .trailing))
            }
            if phase == .alert || phase == .tapAllow {
                Color.black.opacity(0.2).transition(.opacity)
                FullAccessAlert(tapping: phase == .tapAllow)
                    .transition(.scale(scale: 1.1).combined(with: .opacity))
            }
        }
    }

    private var appPage: some View {
        VStack(spacing: 0) {
            MockNavigationBar(back: "Apps", title: "VoiceiQ")
            MockGroup {
                MockRow(title: "Microphone") { MockSwitch(on: true) }
                MockRow(title: "Keyboards", tapping: phase == .tapKeyboards) {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.faint)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var keyboardsPage: some View {
        VStack(spacing: 0) {
            MockNavigationBar(back: "VoiceiQ", title: "Keyboards")
            MockGroup {
                MockRow(title: "VoiceiQ", tapping: phase == .voiceIQOn) {
                    MockSwitch(on: phase.rawValue >= Phase.voiceIQOn.rawValue)
                }
                MockRow(title: "Allow Full Access", tapping: phase == .tapFullAccess) {
                    MockSwitch(on: phase == .done)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Touch and hold the globe key, and pick VoiceiQ in the menu that opens.
struct GlobeSwitchDemo: View {
    @State private var phase = Phase.idle

    enum Phase: Int, CaseIterable, LoopPhase {
        case idle, holding, menu, pickVoiceIQ, switched

        var hold: Double {
            switch self {
            case .idle: return 1.0
            case .holding: return 0.8
            case .menu: return 0.8
            case .pickVoiceIQ: return 0.9
            case .switched: return 1.8
            }
        }
    }

    var body: some View {
        let pressed = phase == .holding || phase == .menu || phase == .pickVoiceIQ
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            KeyboardMenu(voiceIQSelected: phase == .pickVoiceIQ)
                .opacity(phase == .menu || phase == .pickVoiceIQ ? 1 : 0)
                .scaleEffect(phase == .menu || phase == .pickVoiceIQ ? 1 : 0.7, anchor: .bottomLeading)
            HStack(spacing: Theme.Spacing.s) {
                KeyCapShape(width: 56) {
                    Image(systemName: "globe").font(.system(size: 20, weight: .regular)).foregroundStyle(Theme.Colors.inkSecondary)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .trim(from: 0, to: pressed ? 1 : 0)
                        .stroke(Theme.Colors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .animation(phase == .holding ? .linear(duration: 0.7) : .default, value: pressed)
                )
                .overlay(TouchDot(visible: pressed, size: 52))
                KeyCapShape(width: nil) {
                    Text(phase == .switched ? "VoiceiQ" : "space")
                        .font(Theme.Fonts.footnote())
                        .foregroundStyle(phase == .switched ? Theme.Colors.ink : Theme.Colors.faint)
                        .contentTransition(.opacity)
                }
                if phase == .switched {
                    TalkKeyGlyph(size: 44).transition(.scale.combined(with: .opacity))
                } else {
                    KeyCapShape(width: 44) {
                        Image(systemName: "return").font(.system(size: 15)).foregroundStyle(Theme.Colors.inkSecondary)
                    }
                }
            }
            .padding(Theme.Spacing.s)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.grouped))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 1))
        }
        .loopingPhases($phase, still: .pickVoiceIQ)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touch and hold the globe key below the keyboard, then choose VoiceiQ.")
    }
}

/// A numbered line under a guide; the one the animation is showing is in ink,
/// the others recede.
struct GuideInstruction: View {
    let number: Int
    let text: Text
    var current = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text("\(number)")
                .font(Theme.Fonts.caption())
                .foregroundStyle(current ? Theme.Colors.onAccent : Theme.Colors.muted)
                .frame(width: 22, height: 22)
                .background(Circle().fill(current ? Theme.Colors.accent : Theme.Colors.porcelain))
            text
                .font(Theme.Fonts.callout())
                .foregroundStyle(current ? Theme.Colors.ink : Theme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.25), value: current)
    }
}

/// VoiceiQ's Talk key: a blue rounded square with the waveform, red with a
/// stop square while it records.
struct TalkKeyGlyph: View {
    var size: CGFloat = 44
    var recording = false

    var body: some View {
        RoundedRectangle(cornerRadius: size / 3, style: .continuous)
            .fill(recording ? Theme.Colors.recording : Theme.Colors.accent)
            .frame(width: size, height: size)
            .overlay {
                if recording {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: size * 0.26, height: size * 0.26)
                } else {
                    Image(systemName: "waveform").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: recording)
    }
}

/// A key on a drawn keyboard: a fill rectangle holding a label.
struct KeyCapShape<Label: View>: View {
    let width: CGFloat?
    var height: CGFloat = 44
    @ViewBuilder var label: Label

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.Colors.surface)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 1))
            .overlay(label)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }
}

/// The menu iOS shows while the globe key is held.
private struct KeyboardMenu: View {
    let voiceIQSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            item("English (US)", selected: !voiceIQSelected)
            item("VoiceiQ", selected: voiceIQSelected)
        }
        .padding(6)
        .frame(width: 184, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.surface)
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }

    private func item(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title).font(Theme.Fonts.callout()).foregroundStyle(Theme.Colors.ink)
            Spacer()
            if selected {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(selected ? Theme.Colors.accentSoft : .clear))
        .overlay(alignment: .trailing) {
            TouchDot(visible: selected && title == "VoiceiQ", size: 36).padding(.trailing, 20)
        }
    }
}

// MARK: - Settings drawing

private struct MockNavigationBar: View {
    let back: String
    let title: String

    var body: some View {
        ZStack {
            Text(title).font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
            HStack(spacing: 2) {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                Text(back).font(Theme.Fonts.callout())
                Spacer()
            }
            .foregroundStyle(Theme.Colors.inkSecondary)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: 48)
    }
}

private struct MockGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.surface))
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.top, Theme.Spacing.s)
    }
}

private struct MockRow<Accessory: View>: View {
    let title: String
    var tapping = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(title).font(Theme.Fonts.callout()).foregroundStyle(Theme.Colors.ink)
            Spacer()
            accessory.overlay(TouchDot(visible: tapping, size: 40))
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: 46)
    }
}

/// A drawn switch, green when on as in Settings.
private struct MockSwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Theme.Colors.success : Theme.Colors.porcelain)
            .frame(width: 44, height: 26)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 22, height: 22).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
            }
    }
}

private struct FullAccessAlert: View {
    let tapping: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("Allow Full Access for “VoiceiQ” Keyboards?")
                .font(Theme.Fonts.label())
                .foregroundStyle(Theme.Colors.ink)
                .multilineTextAlignment(.center)
                .padding(Theme.Spacing.l)
            Rectangle().fill(Theme.Colors.hairline).frame(height: 1)
            HStack(spacing: 0) {
                Text("Don’t Allow").frame(maxWidth: .infinity)
                Rectangle().fill(Theme.Colors.hairline).frame(width: 1)
                Text("Allow").fontWeight(.semibold).frame(maxWidth: .infinity)
                    .overlay(TouchDot(visible: tapping, size: 40))
            }
            .font(Theme.Fonts.callout())
            .foregroundStyle(Theme.Colors.accent)
            .frame(height: 42)
        }
        .frame(width: 236)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.surface))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

/// Where a finger is touching.
struct TouchDot: View {
    let visible: Bool
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(Theme.Colors.accent.opacity(0.18))
            .overlay(Circle().strokeBorder(Theme.Colors.accent.opacity(0.5), lineWidth: 2))
            .frame(width: size, height: size)
            .scaleEffect(visible ? 1 : 1.6)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: - Looping

/// One frame of a looping animation and how long it stays on screen.
protocol LoopPhase: CaseIterable, Equatable, Sendable {
    var hold: Double { get }
}

extension View {
    /// Steps `phase` through every case of its type, holding each for its
    /// `hold`, for as long as the view is on screen. With Reduce Motion it
    /// shows `still` and stays there.
    func loopingPhases<Phase: LoopPhase>(_ phase: Binding<Phase>, still: Phase) -> some View {
        modifier(LoopingPhases(phase: phase, still: still))
    }
}

private struct LoopingPhases<Phase: LoopPhase>: ViewModifier {
    @Binding var phase: Phase
    let still: Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.task(id: reduceMotion) {
            guard !reduceMotion else {
                phase = still
                return
            }
            while !Task.isCancelled {
                for next in Phase.allCases {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { phase = next }
                    try? await Task.sleep(for: .seconds(next.hold))
                    if Task.isCancelled { return }
                }
            }
        }
    }
}
