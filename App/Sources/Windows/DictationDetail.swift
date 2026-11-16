import AppKit
import SwiftUI
import VoiceIQCore

/// History's right column: one dictation's text, what was heard, and its metadata.
struct DictationDetail: View {
    let record: DictationRecord
    var calls: [UsageRecord] = []
    let onRetry: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var scheme
    /// Download's result, shown as the same message as a meeting export.
    @State private var exported: ExportResult?
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.l) {
                    Text(shownText)
                        .font(VoiceIQUI.TypeScale.bodyLarge(grad: grad))
                        .textSelection(.enabled)
                    // What the transcription model heard, before the writing rules.
                    // Shown only when the writing model changed it, as on iPhone.
                    if let raw = record.rawTranscript, raw != shownText {
                        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
                            metaLabel("As heard")
                            Text(raw)
                                .font(VoiceIQUI.TypeScale.bodyLarge(grad: grad))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Divider()
                    metadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VoiceIQUI.Spacing.xxl)
                .padding(.vertical, VoiceIQUI.Spacing.xl)
            }
        }
        .overlay(alignment: .bottom) {
            if let exported { ExportToast(result: exported) { self.exported = nil }.padding(.bottom, VoiceIQUI.Spacing.l) }
        }
        .animation(.easeOut(duration: 0.2), value: exported)
    }

    private var header: some View {
        HStack(spacing: VoiceIQUI.Spacing.xs) {
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(VoiceIQUI.TypeScale.title(grad: grad))
                .lineLimit(1)
            Spacer(minLength: VoiceIQUI.Spacing.s)
            RecordingAudioButtons(audio: audio) { exported = $0 }
            // Dictations synced from another device have no local folder to retry from.
            if !record.isFromOtherDevice {
                Button("Retry transcription", systemImage: "arrow.clockwise", action: onRetry)
                    .help(RetryQueue.canRetry(record) ? "Retry transcription" : "The audio isn't on this Mac")
                    .disabled(!RetryQueue.canRetry(record))
            }
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shownText, forType: .string)
            }
            .help("Copy")
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .help("Delete this dictation")
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, VoiceIQUI.Spacing.l)
        .padding(.top, VoiceIQUI.Spacing.l)
        .padding(.bottom, VoiceIQUI.Spacing.s)
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: VoiceIQUI.Spacing.l, verticalSpacing: 4) {
            if let app = record.targetAppName {
                GridRow { metaLabel("Dictated into"); metaValue(app) }
            }
            if let duration = record.durationSeconds {
                GridRow { metaLabel("Duration"); metaValue(String(format: "%.1fs", duration)) }
            }
            if let pipeline = record.pipelineSeconds {
                GridRow { metaLabel("Pipeline"); metaValue(String(format: "%.2fs", pipeline)) }
            }
            if !calls.isEmpty {
                GridRow {
                    metaLabel("Cost")
                    metaValue(CostPane.money(
                        calls.reduce(0) { $0 + ($1.costUSD ?? 0) },
                        approximate: calls.contains { $0.isEstimated || $0.costUSD == nil }
                    ))
                }
                ForEach(UsageLine.lines(calls)) { line in
                    let call = line.total
                    let count = line.calls > 1 ? " · \(line.calls) calls" : ""
                    GridRow {
                        metaLabel(call.stageValue?.displayName ?? call.stage)
                        metaValue("\(call.model)\(count) · \(UsageFormat.measure(call)) · \(CostPane.money(call.costUSD, approximate: call.isEstimated))")
                    }
                }
            }
            GridRow { metaLabel("Status"); metaValue(HistoryPane.statusDisplayName(record)) }
            if let message = record.errorMessage, !message.isEmpty {
                GridRow { metaLabel("Details"); metaValue(String(message.prefix(160))) }
            }
            if !audio.isAvailable {
                GridRow {
                    metaLabel("Audio")
                    metaValue(record.isFromOtherDevice ? "On the device it was dictated on" : "Removed by retention policy")
                }
            }
        }
    }

    private var shownText: String {
        record.cleanedTranscript ?? record.rawTranscript ?? "—"
    }

    private var audio: RecordedAudio { .dictation(folder: record.folderURL, startedAt: record.startedAt) }

    private func metaLabel(_ text: String) -> some View {
        Text(text).font(VoiceIQUI.TypeScale.labelSmall(grad: grad)).foregroundStyle(.secondary)
    }

    private func metaValue(_ text: String) -> some View {
        Text(text).font(VoiceIQUI.TypeScale.labelSmall(grad: grad)).textSelection(.enabled)
    }
}
