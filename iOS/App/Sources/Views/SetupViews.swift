import SwiftUI

/// Microphone, keyboard and (when off) Live Activities, on one page:
/// Settings › Keyboard & Permissions.
struct PermissionsPanel: View {
    @EnvironmentObject private var setup: SetupMonitor

    var body: some View {
        let status = setup.status
        VStack(spacing: Theme.Spacing.m) {
            Card {
                HStack(spacing: Theme.Spacing.m) {
                    IconTile(systemImage: "mic.fill", size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone").font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
                        Text("Used only while you dictate or record notes.")
                            .font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if status.micGranted {
                        StatusChip(text: "Allowed", tone: .done)
                    } else if status.micDenied {
                        Button("Settings", action: openAppSettings).buttonStyle(.compactPrimary)
                    } else {
                        Button("Allow", action: setup.requestMicrophone).buttonStyle(.compactPrimary)
                    }
                }
            }

            Card {
                HStack(spacing: Theme.Spacing.m) {
                    IconTile(systemImage: "keyboard.fill", size: 32)
                    Text("VoiceiQ keyboard").font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
                    Spacer(minLength: 0)
                    if status.keyboardReady {
                        StatusChip(text: "Ready", tone: .done)
                    } else if status.keyboardAdded {
                        StatusChip(text: "Open it once", tone: .pending)
                    }
                }
                if !status.keyboardReady {
                    KeyboardSettingsWalkthrough()
                    FullAccessPrivacyNote()
                }
                if status.keyboardAdded && !status.fullAccess {
                    // iOS does not tell the app whether Full Access is on. The
                    // keyboard reports it the first time it opens.
                    Label("iOS only lets VoiceiQ check Full Access from the keyboard. Switch to the VoiceiQ keyboard once in the Try it box to finish.",
                          systemImage: "keyboard")
                        .font(Theme.Fonts.footnote())
                        .foregroundStyle(Theme.Colors.pending)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open VoiceiQ Settings", action: openAppSettings).buttonStyle(.secondaryPill)
                } else if !status.keyboardReady {
                    Button("Open VoiceiQ Settings", action: openAppSettings).buttonStyle(.primaryPill)
                }
            }

            LiveActivitiesOffCard()
        }
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
                HStack(spacing: Theme.Spacing.m) {
                    IconTile(systemImage: "circle.dashed.inset.filled", tint: Theme.Colors.pending, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Activities are off").font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
                        Text(UIDevice.isPad ? "VoiceiQ Dictate needs them to dictate without opening VoiceiQ." : "The Action button needs them to dictate without opening VoiceiQ.")
                            .font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Button("Open Settings", action: openAppSettings).buttonStyle(.secondaryPill)
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
            Image(systemName: "lock.fill").foregroundStyle(Theme.Colors.muted)
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
