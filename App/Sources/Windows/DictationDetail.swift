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

    /// The written text or, when they differ, what was heard.
    @State private var showsHeard = false

    private var heard: String? {
        guard let raw = record.rawTranscript, raw != (record.cleanedTranscript ?? raw), !raw.isEmpty else { return nil }
        return raw
    }

    /// A document page, as on the iPhone: the actions, a meta line, the text
    /// at reading size, then the details under a caption.
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xl) {
                    Text(metaLine)
                        .font(GTFont.flex(VQ.TypeScale.meta.size, weight: VQ.TypeScale.meta.weight, grad: grad))
                        .foregroundStyle(VQ.Colors.muted)
                    if heard != nil {
                        SegmentSwitch(selection: $showsHeard, options: [("Written", false), ("What you said", true)])
                    }
                    Text(shownText)
                        .font(GTFont.flex(VQ.TypeScale.body.size + 1, weight: VQ.TypeScale.body.weight, grad: grad))
                        .lineSpacing(5)
                        .foregroundStyle(VQ.Colors.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: 640, alignment: .leading)
                    VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.s) {
                        SectionCaption(text: "Details")
                        metadata
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VQ.Spacing.page + 4)
                .padding(.top, VoiceIQUI.Spacing.s)
                .padding(.bottom, VoiceIQUI.Spacing.xl)
            }
        }
        .background(VQ.Colors.canvas)
        .overlay(alignment: .bottom) {
            if let exported { ExportToast(result: exported) { self.exported = nil }.padding(.bottom, VoiceIQUI.Spacing.l) }
        }
        .animation(.easeOut(duration: 0.2), value: exported)
    }

    private var header: some View {
        HStack(spacing: VoiceIQUI.Spacing.xs) {
            Spacer(minLength: 0)
            RecordingAudioButtons(audio: audio) { exported = $0 }
                .buttonStyle(CircleButtonStyle())
            // Dictations synced from another device have no local folder to retry from.
            if !record.isFromOtherDevice {
                Button("Retry transcription", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(CircleButtonStyle())
                    .help(RetryQueue.canRetry(record) ? "Retry transcription" : "The audio isn't on this Mac")
                    .disabled(!RetryQueue.canRetry(record))
            }
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .buttonStyle(CircleButtonStyle())
                .help("Delete this dictation")
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shownText, forType: .string)
            }
            .buttonStyle(InkPillButtonStyle())
            .fixedSize()
            .help("Copy")
        }
        .padding(.horizontal, VQ.Spacing.page + 4)
        .padding(.top, VoiceIQUI.Spacing.l)
        .padding(.bottom, VoiceIQUI.Spacing.m)
    }

    private var metaLine: String {
        var parts = [record.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let app = record.targetAppName { parts.append(app) }
        if let seconds = record.durationSeconds, seconds > 0 {
            parts.append(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
        }
        return parts.joined(separator: " · ")
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
            ForEach(record.steps?.rows ?? [], id: \.self) { step in
                GridRow { metaLabel(step.label); metaValue(step.value) }
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
        if showsHeard, let heard { return heard }
        return record.cleanedTranscript ?? record.rawTranscript ?? "—"
    }

    private var audio: RecordedAudio { .dictation(folder: record.folderURL, startedAt: record.startedAt) }

    private func metaLabel(_ text: String) -> some View {
        Text(text).font(VoiceIQUI.TypeScale.label(grad: grad)).foregroundStyle(VQ.Colors.muted)
    }

    private func metaValue(_ text: String) -> some View {
        Text(text).font(VoiceIQUI.TypeScale.label(grad: grad)).foregroundStyle(VQ.Colors.ink).textSelection(.enabled)
    }
}
