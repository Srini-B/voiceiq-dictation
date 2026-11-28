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

    /// Written text or the transcript as heard, when they differ.
    @State private var showsHeard = false

    private var heard: String? {
        guard let raw = record.rawTranscript, raw != record.displayText, !raw.isEmpty else { return nil }
        return raw
    }

    /// A document page, as Voicenotes reads: the meta line, the text at
    /// reading size, then the recording and the details as hairline rows.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text(meta)
                        .font(Theme.Fonts.footnote())
                        .foregroundStyle(Theme.Colors.muted)
                    if heard != nil {
                        Picker("Version", selection: $showsHeard) {
                            Text("Written").tag(false)
                            Text("What you said").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    Text(shownText)
                        .font(Theme.Fonts.body())
                        // 16 on a 24 line, as the spec says; the font's own line is 20.
                        .lineSpacing(4)
                        .padding(.top, heard != nil ? Theme.Spacing.s : 0)
                        .foregroundStyle(record.displayText.isEmpty && !showsHeard ? Theme.Colors.muted : Theme.Colors.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                actions
                if canRetry { retryCard }
                section("Recording") {
                    RecordingAudioControls(audio: .dictation(folder: record.folderURL, startedAt: record.startedAt))
                }
                section("Details") { details }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.l)
            .readableWidth()
        }
        .themedBackground()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadCalls)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    private var shownText: String {
        if showsHeard, let heard { return heard }
        return record.displayText.isEmpty ? "No text" : record.displayText
    }

    private var meta: String {
        var parts = [record.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let app = AppNames.name(for: record) { parts.append(app) }
        if let seconds = record.durationSeconds, seconds > 0 {
            parts.append(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
        }
        return parts.joined(separator: " · ")
    }

    private func loadCalls() {
        calls = UsageMeter.store?.records(forSession: record.id) ?? []
    }

    /// Copy is the one dark pill; Share sits beside it.
    @ViewBuilder private var actions: some View {
        if !record.displayText.isEmpty {
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    UIPasteboard.general.string = shownText
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PillButtonStyle(kind: .ink, compact: true))
                .animation(.default, value: copied)
                ShareLink(item: shownText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.compactSecondary)
            }
        }
    }

    private var retryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
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
            .buttonStyle(.compactPrimary)
            .disabled(retrying)
            // Why it failed, beside the action that fixes it; a retry's own
            // message replaces it.
            if let text = message ?? errorText {
                Text(text)
                    .font(Theme.Fonts.footnote())
                    .foregroundStyle(message == nil ? Theme.Colors.pending : Theme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var errorText: String? { record.errorMessage ?? record.errorCode }

    /// When, app and length are in the meta line above the text, so the
    /// rows start with what it doesn't say.
    private var detailRows: [DetailRow] {
        var rows: [DetailRow] = []
        if let origin = record.origin { rows.append(DetailRow(label: "Dictated on", value: origin)) }
        if let pipeline = record.pipelineSeconds {
            rows.append(DetailRow(label: "Pipeline", value: String(format: "%.2fs", pipeline)))
        }
        rows += (record.steps?.rows ?? []).map { DetailRow(label: $0.label, value: $0.value) }
        if !calls.isEmpty {
            rows.append(DetailRow(label: "Cost", value: UsageView.money(
                calls.reduce(0) { $0 + ($1.costUSD ?? 0) },
                approximate: calls.contains { $0.isEstimated || $0.costUSD == nil }
            )))
            rows += UsageLine.lines(calls).map { line in
                let call = line.total
                let count = line.calls > 1 ? " · \(line.calls) calls" : ""
                return DetailRow(label: call.stageValue?.displayName ?? call.stage,
                                 value: "\(call.model)\(count) · \(UsageView.money(call.costUSD, approximate: call.isEstimated))")
            }
        }
        if !canRetry, let error = errorText {
            rows.append(DetailRow(label: "Error", value: error, wraps: true))
        }
        return rows
    }

    private var details: some View {
        let rows = detailRows
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 { divider }
                rows[index]
            }
        }
    }

    private var divider: some View { Divider().overlay(Theme.Colors.hairline) }

    /// A caption over hairline content, with no card around it.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(Theme.Fonts.caption())
                .foregroundStyle(Theme.Colors.muted)
            Divider().overlay(Theme.Colors.hairline)
            content()
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    /// Model names stay on one line, cut in the middle; an error wraps.
    var wraps = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.l) {
            Text(label).font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
            Spacer(minLength: Theme.Spacing.l)
            Text(value)
                .font(Theme.Fonts.footnote())
                .foregroundStyle(Theme.Colors.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.middle)
        }
        .padding(.vertical, Theme.Spacing.s)
    }
}
