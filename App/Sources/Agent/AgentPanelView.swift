import AppKit
import SwiftUI
import VoiceIQCore

/// The agent session in the pill's expanded panel: the Ask Anything answer
/// frame, with the transcript of commands, thoughts and actions in order.
struct AgentPanelView: View {
    @ObservedObject var model: AgentPanelModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            transcript
            if let pending = model.pendingConfirmation {
                confirmation(pending.request, answer: pending.answer)
            }
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiceIQUI.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            PillDragHandle()
                .fixedSize()
                .accessibilityLabel("Move agent")
            Text("Agent")
                .font(.headline)
            if let session = model.session, !session.modelID.isEmpty {
                Text(session.modelID)
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                copy()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(model.session?.entries.isEmpty ?? true)
            Button("Stop") {
                NotificationCenter.default.post(name: .agentStopRequested, object: nil)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Stop agent")
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.session?.entries ?? []) { entry in
                        AgentEntryRow(entry: entry).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.session?.entries.count ?? 0) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: model.phase) { _, _ in
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Confirmation

    private func confirmation(_ request: String, answer: @escaping (AgentConfirmation) -> Void) -> some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            Text(request)
                .font(VoiceIQUI.TypeScale.label())
                .lineLimit(2)
            Spacer()
            Button("Not now") { answer(.notNow) }
            Button("Always this session") { answer(.alwaysThisSession) }
            Button("Allow once") { answer(.once) }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(10)
        .background(VoiceIQUI.Colors.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            Button {
                NotificationCenter.default.post(name: .agentListenTapped, object: nil)
            } label: {
                Label(model.phase == .listening ? "Done" : "Speak", systemImage: model.phase == .listening ? "stop.circle.fill" : "mic.fill")
            }
            .buttonStyle(.borderless)
            .disabled(model.phase == .thinking || model.phase == .transcribing)
            .accessibilityLabel(model.phase == .listening ? "Finish speaking" : "Speak a command")
            Text(phaseLine)
                .font(VoiceIQUI.TypeScale.labelSmall())
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                .lineLimit(1)
            Spacer()
            if let notice = model.notice {
                Text(notice)
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(VoiceIQUI.Colors.error)
                    .lineLimit(1)
            }
        }
    }

    private var phaseLine: String {
        switch model.phase {
        case .idle: return "Press the Agent shortcut or \(SettingsStore().dictationTrigger.displayName) and speak"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Working"
        }
    }

    // MARK: - Helpers

    private func copy() {
        guard let session = model.session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.transcriptText, forType: .string)
        copied = true
    }
}
