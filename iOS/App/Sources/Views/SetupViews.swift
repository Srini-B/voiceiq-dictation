import SwiftUI

/// Microphone, keyboard and (when off) Live Activities, on one page:
/// Settings › Keyboard & Permissions.
struct PermissionsPanel: View {
    @EnvironmentObject private var setup: SetupMonitor

    var body: some View {
        let status = setup.status
        VStack(spacing: Theme.Spacing.m) {
            Card {
                SetupCheckRow(symbol: "mic",
                              title: "Dictate with your voice",
                              detail: "The microphone, used only while you dictate or record notes.",
                              state: status.micGranted ? .done("Allowed") : .todo) {
                    if status.micDenied {
                        Button("Settings", action: openAppSettings).buttonStyle(.compactPrimary)
                    } else if !status.micGranted {
                        Button("Allow", action: setup.requestMicrophone).buttonStyle(.compactPrimary)
                    }
                }
            }

            Card {
                SetupCheckRow(symbol: "keyboard",
                              title: "VoiceiQ in every app",
                              detail: "The VoiceiQ keyboard, added in Settings.",
                              state: status.keyboardAdded ? .done("Added") : .todo)
                Divider()
                SetupCheckRow(symbol: "lock.open",
                              title: "Dictation from the keyboard",
                              detail: status.keyboardAdded && !status.fullAccess
                                  ? "Allow Full Access. iOS shows it to VoiceiQ only from the keyboard: switch to it once in the Try it box."
                                  : "Allow Full Access.",
                              state: status.fullAccess ? .done("Allowed") : status.keyboardAdded ? .waiting : .todo)
                if !status.keyboardReady {
                    KeyboardSettingsWalkthrough().padding(.top, Theme.Spacing.s)
                    FullAccessPrivacyNote()
                    Button("Open VoiceiQ Settings", action: openAppSettings)
                        .buttonStyle(PillButtonStyle(kind: status.keyboardAdded ? .secondary : .primary))
                }
            }

            LiveActivitiesOffCard()
        }
    }
}

/// One setup step, named for what the user gets: an outline symbol, the
/// benefit, why it's needed, and its state, which turns to a green ✓ once
/// VoiceiQ sees it done. `action` shows in place of the state while the step
/// is still to do.
struct SetupCheckRow<Action: View>: View {
    enum Progress: Equatable {
        case todo
        /// Done on the user's side, but VoiceiQ can't see it yet.
        case waiting
        case done(String)
    }

    let symbol: String
    let title: String
    let detail: String
    let state: Progress
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.Colors.inkSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
                Text(detail).font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.s)
            trailing
        }
        .padding(.vertical, 2)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .done(let text):
            Label(text, systemImage: "checkmark")
                .font(Theme.Fonts.label())
                .foregroundStyle(Theme.Colors.success)
                .labelStyle(.titleAndIcon)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Waiting…").font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
            }
        case .todo:
            action
        }
    }
}

extension SetupCheckRow where Action == EmptyView {
    init(symbol: String, title: String, detail: String, state: Progress) {
        self.init(symbol: symbol, title: title, detail: detail, state: state) { EmptyView() }
    }
}

/// Shown only while Live Activities are off for VoiceiQ: the Action button
/// and the VoiceiQ Dictate control need them to dictate without opening it.
struct LiveActivitiesOffCard: View {
    @EnvironmentObject private var setup: SetupMonitor

    /// The VoiceiQ Dictate control and its intent need iOS 18. On an older
    /// iPad, which has no Action button either, the card would name a
    /// feature that does not exist.
    private static var hasDictateControl: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    var body: some View {
        if !setup.status.liveActivitiesEnabled, !UIDevice.isPad || Self.hasDictateControl {
            Card {
                SetupCheckRow(symbol: "bolt",
                              title: "Dictate without opening VoiceiQ",
                              detail: UIDevice.isPad ? "Turn on Live Activities for VoiceiQ Dictate." : "Turn on Live Activities for the Action button.",
                              state: .todo) {
                    Button("Settings", action: openAppSettings).buttonStyle(.compactSecondary)
                }
            }
        }
    }
}

/// What Full Access is for, next to the switch that asks for it.
struct FullAccessPrivacyNote: View {
    var body: some View {
        Label {
            Text("Full Access lets the keyboard hand your voice to the VoiceiQ app. There is no VoiceiQ server, account or analytics.")
        } icon: {
            Image(systemName: "lock").foregroundStyle(Theme.Colors.muted)
        }
        .font(Theme.Fonts.footnote())
        .foregroundStyle(Theme.Colors.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A field to dictate into, with a live check that the keyboard ran with Full
/// Access. The keyboard can always be put away with Done or a drag.
struct TryItCard: View {
    @EnvironmentObject private var setup: SetupMonitor
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Card {
            HStack {
                CheckLine(title: setup.status.fullAccess ? "VoiceiQ keyboard is working" : "Waiting for the VoiceiQ keyboard",
                          done: setup.status.fullAccess,
                          waiting: !setup.status.fullAccess)
                Spacer(minLength: Theme.Spacing.s)
                // In the header, not under the field: the keyboard's floating
                // Done button sits over the card's bottom-right corner.
                if !text.isEmpty {
                    Button("Clear") { text = "" }.buttonStyle(.compactSecondary)
                }
            }
            if !setup.status.fullAccess {
                KeyboardSwitchSteps()
            }
            TextField("Try: “Remind me to call Sam at three, no, four pm.”", text: $text, axis: .vertical)
                .font(Theme.Fonts.body())
                .lineLimit(4...10)
                .focused($focused)
                .padding(Theme.Spacing.m)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).fill(Theme.Colors.surfaceNested))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(focused ? Theme.Colors.accent : Theme.Colors.hairline, lineWidth: focused ? 1.5 : 0.5))
        }
    }
}

/// How to reach the VoiceiQ keyboard: iOS shows the keyboard the user last
/// picked, and switching is done with the globe key below it.
private struct KeyboardSwitchSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            GlobeSwitchDemo().padding(.bottom, Theme.Spacing.xs)
            NumberedStep(number: 1, text: Text("Tap the box below."))
            NumberedStep(number: 2, text: Text("Touch and hold \(Image(systemName: "globe")) at the bottom left of the keyboard."))
            NumberedStep(number: 3, text: Text("Choose **VoiceiQ**, then tap the mic."))
        }
        .font(Theme.Fonts.callout())
        .foregroundStyle(Theme.Colors.ink)
    }
}

/// Dictating on an iPad whose hardware keyboard is attached. iPadOS hides
/// every on-screen keyboard, VoiceiQ's included, and the keyboard's own
/// dictation key always starts Apple's dictation. `ToggleDictationIntent`
/// runs from Control Center, Spotlight or a Full Keyboard Access command
/// instead, and a result no keyboard typed goes to the clipboard.
struct HardwareKeyboardSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            NumberedStep(number: 1, text: Text("Add **VoiceiQ Dictate** to Control Center, or press ⌘Space and run **Dictate with VoiceiQ**."))
            NumberedStep(number: 2, text: Text("Speak, then run it again to stop."))
            NumberedStep(number: 3, text: Text("Press ⌘V to paste."))
            Text("To start it with keys of your own, put **Dictate with VoiceiQ** in a shortcut in the Shortcuts app, then assign that shortcut in Settings › Accessibility › Keyboards › Full Keyboard Access › Commands.")
                .font(Theme.Fonts.footnote())
                .foregroundStyle(Theme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Spacing.xs)
        }
        .font(Theme.Fonts.callout())
        .foregroundStyle(Theme.Colors.ink)
    }
}

private struct NumberedStep: View {
    let number: Int
    let text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text("\(number)")
                .font(Theme.Fonts.caption())
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.Colors.accent.opacity(0.12)))
            text.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Settings › Keyboard & Permissions.
struct KeyboardSetupView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                PermissionsPanel()
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    GroupLabel(text: "Try it")
                    TryItCard()
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    GroupLabel(text: "Typing")
                    TypingSettingsCard()
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.l)
            .readableWidth()
        }
        .keyboardDismissable()
        .themedBackground()
        .navigationTitle("Keyboard & Permissions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
