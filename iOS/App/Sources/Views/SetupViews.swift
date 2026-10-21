import SwiftUI

/// Microphone, keyboard and (when off) Live Activities, on one page. Used by
/// onboarding and by Settings › Keyboard & Permissions.
struct PermissionsPanel: View {
    @EnvironmentObject private var setup: SetupMonitor

    /// The VoiceiQ Dictate control and its intent need iOS 18. On an older
    /// iPad, which has no Action button either, the Live Activities card
    /// would name a feature that does not exist.
    private static var hasDictateControl: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

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
                        Button("Settings", action: openSettings).buttonStyle(.compactPrimary)
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
                SettingsMockup(keyboardOn: status.keyboardAdded,
                               fullAccess: status.fullAccess ? .on : status.keyboardAdded ? .unconfirmed : .off)
                if status.keyboardAdded && !status.fullAccess {
                    // iOS does not tell the app whether Full Access is on. The
                    // keyboard reports it the first time it opens.
                    Label("iOS only lets VoiceiQ check Full Access from the keyboard. Switch to the VoiceiQ keyboard once in the Try it box to finish.",
                          systemImage: "keyboard")
                        .font(Theme.Fonts.footnote())
                        .foregroundStyle(Theme.Colors.pending)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings", action: openSettings).buttonStyle(.secondaryPill)
                } else if !status.keyboardReady {
                    Button("Open Settings", action: openSettings).buttonStyle(.primaryPill)
                }
            }

            if !status.liveActivitiesEnabled, !UIDevice.isPad || Self.hasDictateControl {
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
                    Button("Open Settings", action: openSettings).buttonStyle(.secondaryPill)
                }
            }
        }
    }

    private func openSettings() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }
}

/// A miniature of the Keyboards page in Settings with the two switches the
/// user must turn on, mirroring what VoiceiQ knows of their state.
private struct SettingsMockup: View {
    enum FullAccess { case on, off, unconfirmed }

    let keyboardOn: Bool
    let fullAccess: FullAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings  ›  Apps  ›  VoiceiQ  ›  Keyboards")
                .font(Theme.Fonts.caption())
                .foregroundStyle(Theme.Colors.muted)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                row("VoiceiQ", on: keyboardOn)
                Divider().padding(.leading, 12)
                if fullAccess == .unconfirmed {
                    HStack {
                        Text("Allow Full Access").font(Theme.Fonts.subheadline()).foregroundStyle(Theme.Colors.ink)
                        Spacer()
                        Text("Not confirmed").font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.pending)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                } else {
                    row("Allow Full Access", on: fullAccess == .on)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
        }
        .padding(Theme.Spacing.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.surfaceNested))
        .accessibilityElement(children: .combine)
    }

    private func row(_ title: String, on: Bool) -> some View {
        HStack {
            Text(title).font(Theme.Fonts.subheadline()).foregroundStyle(Theme.Colors.ink)
            Spacer()
            Capsule()
                .fill(on ? Theme.Colors.success : Theme.Colors.porcelain)
                .frame(width: 38, height: 23)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 19, height: 19).padding(2)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                }
                .animation(.spring(response: 0.3), value: on)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
            if #available(iOS 18.0, *) {
                NumberedStep(number: 1, text: Text("Add **VoiceiQ Dictate** to Control Center, or press ⌘Space and run **Dictate with VoiceiQ**."))
                NumberedStep(number: 2, text: Text("Speak, then run it again to stop."))
                NumberedStep(number: 3, text: Text("Press ⌘V to paste."))
                Text("To start it with keys of your own, put **Dictate with VoiceiQ** in a shortcut in the Shortcuts app, then assign that shortcut in Settings › Accessibility › Keyboards › Full Keyboard Access › Commands.")
                    .font(Theme.Fonts.footnote())
                    .foregroundStyle(Theme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.xs)
            } else {
                NumberedStep(number: 1, text: Text("Disconnect your hardware keyboard."))
                NumberedStep(number: 2, text: Text("Switch to the **VoiceiQ** keyboard, then tap the mic to dictate."))
            }
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
