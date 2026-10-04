import SwiftUI
import VoiceIQCore

/// One transcript line, drawn the same in the agent panel and in the
/// Agent section of the main window.
struct AgentEntryRow: View {
    let entry: AgentEntry

    var body: some View {
        switch entry {
        case .command(_, let text, _):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(VoiceIQUI.TypeScale.body())
                    .foregroundStyle(VoiceIQUI.Colors.onPrimaryContainer)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(VoiceIQUI.Colors.primaryContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .textSelection(.enabled)
            }
        case .thought(_, let text):
            Text(text)
                .font(VoiceIQUI.TypeScale.body())
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                .textSelection(.enabled)
        case .action(_, _, let summary, let status):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                actionIcon(status)
                    .frame(width: 14)
                Text(summary)
                    .font(VoiceIQUI.TypeScale.label())
                    .foregroundStyle(VoiceIQUI.Colors.onSurface)
                if case .failed(let reason) = status {
                    Text(reason)
                        .font(VoiceIQUI.TypeScale.labelSmall())
                        .foregroundStyle(VoiceIQUI.Colors.error)
                        .lineLimit(2)
                }
            }
        case .observation(_, let summary):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "eye")
                    .font(.system(size: 10))
                    .frame(width: 14)
                Text(summary)
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .lineLimit(1)
            }
            .foregroundStyle(VoiceIQUI.Colors.outline)
        case .answer(_, let text):
            MarkdownView(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .confirmation(_, let request, let allowed):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: allowed == true ? "checkmark.shield" : allowed == false ? "hand.raised" : "questionmark.circle")
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(request)
                    .font(VoiceIQUI.TypeScale.label())
            }
            .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
        case .failure(_, let text):
            Text(text)
                .font(VoiceIQUI.TypeScale.label())
                .foregroundStyle(VoiceIQUI.Colors.error)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func actionIcon(_ status: AgentActionStatus) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(VoiceIQUI.Colors.success)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(VoiceIQUI.Colors.error)
        case .declined:
            Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).foregroundStyle(VoiceIQUI.Colors.outline)
        }
    }
}
