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
