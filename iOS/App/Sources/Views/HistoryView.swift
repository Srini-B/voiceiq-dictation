import SwiftUI
import VoiceIQCore

/// Dictations grouped by the day they started, newest first.
struct HistoryDaySection: Identifiable {
    let day: Date
    let records: [DictationRecord]
    var id: Date { day }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    static func group(_ records: [DictationRecord]) -> [HistoryDaySection] {
        let grouped = Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { HistoryDaySection(day: $0, records: grouped[$0] ?? []) }
    }
}

struct HistoryDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var record: DictationRecord
    let reload: () -> Void
    @State private var message: String?
    @State private var retrying = false
    @State private var copied = false
    /// The model calls this dictation made, as in the Mac's History.
    @State private var calls: [UsageRecord] = []

    init(record: DictationRecord, reload: @escaping () -> Void) {
        _record = State(initialValue: record)
        self.reload = reload
    }

    /// As on the Mac: Retry needs the recording, or the words of an
    /// unfinished dictation (`RetryQueue.canRetry`).
    private var canRetry: Bool { RetryQueue.canRetry(record) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if !record.displayText.isEmpty { transcriptCard }
                if let raw = record.rawTranscript, raw != record.displayText {
                    cardGroup("As heard") {
                        Text(raw)
                            .font(Theme.Fonts.body())
                            .foregroundStyle(Theme.Colors.muted)
                            .textSelection(.enabled)
                    }
                }
                if canRetry { retryCard }
                cardGroup("Audio") {
                    RecordingAudioControls(audio: .dictation(folder: record.folderURL, startedAt: record.startedAt))
                }
                cardGroup("Details") { details }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.l)
            .readableWidth()
        }
        .themedBackground()
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadCalls)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    private func loadCalls() {
        calls = UsageMeter.store?.records(forSession: record.id) ?? []
    }

    private var transcriptCard: some View {
        Card {
            Text(record.displayText)
                .font(Theme.Fonts.body())
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    UIPasteboard.general.string = record.displayText
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.compactSecondary)
                .animation(.default, value: copied)
                ShareLink(item: record.displayText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.compactSecondary)
            }
        }
    }

    private var retryCard: some View {
        Card {
            Button(retrying ? "Transcribing again…" : "Retry transcription") {
                retrying = true
                message = nil
                Task {
                    message = await model.retry(record)
                    retrying = false
                    if let fresh = model.historyStore?.record(id: record.id) { record = fresh }
                    loadCalls()
                    reload()
                }
            }
            .buttonStyle(.primaryPill)
            .disabled(retrying)
            if let message {
                Text(message).font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
            }
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            DetailRow(label: "When", value: record.startedAt.formatted(date: .abbreviated, time: .shortened))
            if let app = AppNames.name(for: record) { divider; DetailRow(label: "App", value: app) }
            if let origin = record.origin { divider; DetailRow(label: "Dictated on", value: origin) }
            if let seconds = record.durationSeconds {
                divider
                DetailRow(label: "Length", value: Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
            }
            if let pipeline = record.pipelineSeconds {
                divider
                DetailRow(label: "Pipeline", value: String(format: "%.2fs", pipeline))
            }
            ForEach(record.steps?.rows ?? [], id: \.self) { step in
                divider
                DetailRow(label: step.label, value: step.value)
            }
            if !calls.isEmpty {
                divider
                DetailRow(label: "Cost", value: UsageView.money(
                    calls.reduce(0) { $0 + ($1.costUSD ?? 0) },
                    approximate: calls.contains { $0.isEstimated || $0.costUSD == nil }
                ))
                ForEach(UsageLine.lines(calls)) { line in
                    let call = line.total
                    let count = line.calls > 1 ? " · \(line.calls) calls" : ""
                    divider
                    DetailRow(label: call.stageValue?.displayName ?? call.stage,
                              value: "\(call.model)\(count) · \(UsageView.money(call.costUSD, approximate: call.isEstimated))")
                }
            }
            if let error = record.errorMessage ?? record.errorCode { divider; DetailRow(label: "Error", value: error) }
        }
    }

    private var divider: some View { Divider().overlay(Theme.Colors.hairline) }

    private func cardGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            GroupLabel(text: title)
            Card { content() }
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.l) {
            Text(label).font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
            Spacer(minLength: Theme.Spacing.l)
            Text(value)
                .font(Theme.Fonts.footnote())
                .foregroundStyle(Theme.Colors.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, Theme.Spacing.s)
    }
}
