import SwiftUI
import VoiceIQCore

/// The one main action on a page (Copy, Share): an ink capsule.
/// docs/design/redesign-2026-11.md › Components.
struct InkPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GTFont.flex(12.5, weight: 600))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(VQ.Colors.canvas)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(VQ.Colors.ink))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// A muted caption with a hairline under it, over a plain section.
struct SectionCaption: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
            Text(text)
                .font(GTFont.flex(VQ.TypeScale.caption.size, weight: VQ.TypeScale.caption.weight))
                .foregroundStyle(VQ.Colors.muted)
            Rectangle().fill(VQ.Colors.hairline).frame(height: 1)
        }
    }
}

/// A selectable list row's highlight, passed to `.listRowBackground`: brand
/// blue while the list has focus in the key window, the soft fill otherwise,
/// so an unfocused selection is not the system grey. The opaque backing hides
/// the system highlight at the rounded corners; it matches the panes' window
/// background.
struct ListSelectionBackground: View {
    let selected: Bool
    let focused: Bool
    @Environment(\.controlActiveState) private var windowState

    /// The light accent in both modes: macOS draws the selected row's text
    /// white, and white on the dark-mode accent read at 2.3:1.
    private static let emphasized = VQ.Colors.dynamic(light: 0x2252BC, dark: 0x2252BC)

    var body: some View {
        if selected {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RoundedRectangle(cornerRadius: VQ.Radius.control, style: .continuous)
                    .fill(focused && windowState == .key ? Self.emphasized : VQ.Colors.fill)
            }
        } else {
            Color.clear
        }
    }
}

/// An icon action in a page header: a 30 point canvas circle with a hairline ring.
struct CircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(VQ.Colors.ink2)
            .frame(width: 30, height: 30)
            .background(Circle().fill(VQ.Colors.canvas))
            .overlay(Circle().strokeBorder(VQ.Colors.hairline, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Circle())
    }
}

/// A two-to-four way switch: a fill capsule track with the chosen option on
/// a canvas capsule. Replaces the system segmented picker.
struct SegmentSwitch<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index].label, value: options[index].value)
            }
        }
        .padding(2)
        .background(Capsule().fill(VQ.Colors.fill))
        .fixedSize()
    }

    private func segment(_ label: String, value: Value) -> some View {
        let selected = value == selection
        return Button { selection = value } label: {
            Text(label)
                .font(GTFont.flex(VQ.TypeScale.meta.size, weight: 500))
                .foregroundStyle(selected ? VQ.Colors.ink : VQ.Colors.muted)
                .padding(.horizontal, VoiceIQUI.Spacing.s)
                .frame(height: 24)
                .background {
                    if selected {
                        Capsule().fill(VQ.Colors.canvas)
                            .overlay(Capsule().strokeBorder(VQ.Colors.hairline, lineWidth: 1))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
