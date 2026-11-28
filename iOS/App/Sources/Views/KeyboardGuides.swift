import SwiftUI

// Animated how-tos for the two things iOS makes the user do by hand: turning
// the keyboard on in Settings, and switching to it with the globe key. Both
// loop; with Reduce Motion each holds its most telling frame.

/// Settings › Apps › VoiceiQ, then Keyboards, VoiceiQ on, Allow Full Access on
/// and its alert, drawn with system colours and type so it reads as the real
/// Settings pages in light and dark mode.
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
                .frame(height: 248)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                GuideInstruction(number: 1, text: Text("Tap **Keyboards**"), current: phase.instruction == 0)
                GuideInstruction(number: 2, text: Text("Turn on **VoiceiQ**"), current: phase.instruction == 1)
                GuideInstruction(number: 3, text: Text("Turn on **Allow Full Access**, then tap **Allow**"), current: phase.instruction == 2)
            }
        }
        .loopingPhases($phase, still: .done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In VoiceiQ's Settings, tap Keyboards, turn on VoiceiQ, then turn on Allow Full Access and tap Allow.")
    }

    private var screen: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            if phase.rawValue < Phase.keyboardsPage.rawValue {
                appPage.transition(.move(edge: .leading))
            } else {
                keyboardsPage.transition(.move(edge: .trailing))
            }
            if phase == .alert || phase == .tapAllow {
                Color.black.opacity(0.25).transition(.opacity)
                FullAccessAlert(tapping: phase == .tapAllow)
                    .transition(.scale(scale: 1.1).combined(with: .opacity))
            }
        }
    }

    private var appPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            MockNavigationBar(back: "Apps", title: "VoiceiQ")
            MockSectionHeader(text: "Allow VoiceiQ to access")
            MockGroup {
                MockRow(symbol: "mic.fill", tint: .orange, title: "Microphone") { MockSwitch(on: true) }
                MockRow(symbol: "waveform.circle.fill", tint: .indigo, title: "Live Activities") { MockSwitch(on: true) }
            }
            Spacer().frame(height: 14)
            MockGroup {
                MockRow(symbol: "keyboard.fill", tint: .gray, title: "Keyboards", tapping: phase == .tapKeyboards) {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var keyboardsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            MockNavigationBar(back: "VoiceiQ", title: "Keyboards")
            Spacer().frame(height: 14)
            MockGroup {
                MockRow(title: "VoiceiQ", tapping: phase == .voiceIQOn) {
                    MockSwitch(on: phase.rawValue >= Phase.voiceIQOn.rawValue)
                }
                MockRow(title: "Allow Full Access", tapping: phase == .tapFullAccess) {
                    MockSwitch(on: phase == .done)
                }
            }
            Text("Full Access lets the keyboard hand your voice to the VoiceiQ app.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}

/// Touch and hold the globe key, pick VoiceiQ, and the VoiceiQ keyboard comes
/// up: Apple's keyboard, its keyboard menu, then VoiceiQ's.
struct GlobeSwitchDemo: View {
    @State private var phase = Phase.idle

    enum Phase: Int, CaseIterable, LoopPhase {
        case idle, holding, menu, pickVoiceIQ, switched

        var hold: Double {
            switch self {
            case .idle: return 1.0
            case .holding: return 0.7
            case .menu: return 0.8
            case .pickVoiceIQ: return 0.8
            case .switched: return 2.2
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MiniKeyboard(style: phase == .switched ? .voiceIQ(listening: false) : .apple,
                         globePressed: phase == .holding || phase == .menu || phase == .pickVoiceIQ)
            if phase == .menu || phase == .pickVoiceIQ {
                KeyboardMenu(voiceIQSelected: phase == .pickVoiceIQ)
                    .padding(.leading, 8)
                    .padding(.bottom, 40)
                    .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
            }
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

// MARK: - Mini keyboard

/// A small drawing of an iPhone keyboard with the globe and dictation keys
/// below it. `.voiceIQ` adds the bar with VoiceiQ's mic.
struct MiniKeyboard: View {
    enum Style: Equatable { case apple, voiceIQ(listening: Bool) }

    var style: Style = .apple
    var globePressed = false

    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let tray = Theme.Colors.dynamic(light: 0xD3D5DB, dark: 0x2C2C2F)
    private static let key = Theme.Colors.dynamic(light: 0xFFFFFF, dark: 0x6A6A6E)
    private static let modifierKey = Theme.Colors.dynamic(light: 0xAEB2BB, dark: 0x464649)

    var body: some View {
        VStack(spacing: 6) {
            if case .voiceIQ(let listening) = style {
                HStack {
                    Wordmark(height: 13).opacity(0.7)
                    Spacer()
                    micButton(listening: listening)
                }
                .padding(.horizontal, 4)
                .frame(height: 30)
                .transition(.opacity)
            }
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 4) {
                    if index == 2 { modifier("shift") }
                    ForEach(Array(row), id: \.self) { letter in
                        Text(String(letter))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.ink)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Self.key))
                    }
                    if index == 2 { modifier("delete.left") }
                }
                .padding(.horizontal, index == 1 ? 12 : 0)
            }
            HStack(spacing: 4) {
                Text("123").font(.system(size: 11)).frame(width: 40, height: 26)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Self.modifierKey))
                Text(style == .apple ? "space" : "VoiceiQ").font(.system(size: 11))
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Self.key))
                Image(systemName: "return").font(.system(size: 11)).frame(width: 52, height: 26)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Self.modifierKey))
            }
            .foregroundStyle(Theme.Colors.ink)
            HStack {
                globe
                Spacer()
                Image(systemName: "mic").font(.system(size: 16)).foregroundStyle(Theme.Colors.ink.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Self.tray))
    }

    private func modifier(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.Colors.ink)
            .frame(width: 32, height: 26)
            .background(RoundedRectangle(cornerRadius: 4).fill(Self.modifierKey))
    }

    private var globe: some View {
        Image(systemName: "globe")
            .font(.system(size: 18))
            .foregroundStyle(Theme.Colors.ink.opacity(0.8))
            .frame(width: 34, height: 34)
            .background(Circle().fill(Self.key.opacity(globePressed ? 1 : 0)))
            .overlay(TouchDot(visible: globePressed, size: 44))
    }

    private func micButton(listening: Bool) -> some View {
        ZStack {
            if listening {
                Circle().stroke(Theme.Colors.accent.opacity(0.35), lineWidth: 6).frame(width: 34, height: 34)
            }
            Circle().fill(listening ? Theme.Colors.recording : Theme.Colors.accent).frame(width: 28, height: 28)
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: listening)
        }
    }
}

/// The menu iOS shows while the globe key is held.
private struct KeyboardMenu: View {
    let voiceIQSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Keyboard Settings…")
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            item(title: "English (US)", subtitle: nil, selected: !voiceIQSelected)
            item(title: "VoiceiQ", subtitle: "English", selected: voiceIQSelected)
        }
        .foregroundStyle(Color.primary)
        .padding(6)
        .frame(width: 176, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6))
    }

    private func item(title: String, subtitle: String?, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
            if let subtitle {
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(Color.primary.opacity(selected ? 0.1 : 0)))
    }
}

// MARK: - Settings mock parts

private struct MockNavigationBar: View {
    let back: String
    let title: String

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 2) {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                Text(back).font(.system(size: 15))
                Spacer()
            }
            .foregroundStyle(Color(uiColor: .systemBlue))
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

private struct MockSectionHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 30)
            .padding(.top, 8)
            .padding(.bottom, 5)
    }
}

private struct MockGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .padding(.horizontal, 14)
    }
}

private struct MockRow<Accessory: View>: View {
    var symbol: String?
    var tint: Color = .gray
    let title: String
    var tapping = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint))
            }
            Text(title).font(.system(size: 15)).foregroundStyle(Color.primary)
            Spacer()
            accessory.overlay(TouchDot(visible: tapping, size: 40))
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.primary.opacity(tapping && symbol != nil ? 0.08 : 0))
    }
}

/// A drawn UISwitch.
private struct MockSwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Color(uiColor: .systemGreen) : Color(uiColor: .systemFill))
            .frame(width: 46, height: 28)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 24, height: 24).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
    }
}

private struct FullAccessAlert: View {
    let tapping: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Allow Full Access for “VoiceiQ” Keyboards?")
                    .font(.system(size: 14, weight: .semibold))
                Text("Full access allows the developer of this keyboard to transmit anything you type.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(14)
            Divider()
            HStack(spacing: 0) {
                Text("Don’t Allow").frame(maxWidth: .infinity)
                Divider()
                Text("Allow").fontWeight(.semibold).frame(maxWidth: .infinity)
                    .overlay(TouchDot(visible: tapping, size: 40))
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(uiColor: .systemBlue))
            .frame(height: 40)
        }
        .frame(width: 236)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.thickMaterial))
    }
}

/// Where a finger is touching.
struct TouchDot: View {
    let visible: Bool
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(Theme.Colors.accent.opacity(0.25))
            .overlay(Circle().strokeBorder(Theme.Colors.accent.opacity(0.6), lineWidth: 2))
            .frame(width: size, height: size)
            .scaleEffect(visible ? 1 : 1.6)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: - Looping

/// One frame of a looping animation and how long it stays on screen.
protocol LoopPhase: CaseIterable, Equatable {
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
