import SwiftUI
import VoiceIQCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var records: [DictationRecord] = []
    @State private var search = ""
    @State private var confirmDeleteAll = false
    /// Stats outlive History, so Statistics stays after History is cleared.
    @State private var hasStats = false

    private var sections: [HistoryDaySection] { HistoryDaySection.group(records) }

    var body: some View {
        ListDetailNavigation {
            List {
                if search.isEmpty && hasStats {
                    Section {
                        NavigationLink { StatsView() } label: { StatsLinkRow() }
                    }
                }
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.records) { record in
                            // The id gives each dictation its own detail state;
                            // without it the split view kept showing the first
                            // one opened.
                            NavigationLink { HistoryDetail(record: record, reload: reload).id(record.id) } label: {
                                HistoryRow(record: record)
                            }
                        }
                        .onDelete { offsets in delete(offsets, from: section.records) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listRowBackground(Theme.Colors.surface)
            .themedBackground()
            .keyboardDismissable()
            .overlay {
                if records.isEmpty && !(search.isEmpty && hasStats) { HistoryEmptyState(isSearching: !search.isEmpty) }
            }
            .searchable(text: $search)
            .onChange(of: search) { _, _ in reload() }
            .navigationTitle("History")
            .toolbar {
                if !records.isEmpty {
                    Menu {
                        Button("Delete All", role: .destructive) { confirmDeleteAll = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("History actions")
                }
            }
            .confirmationDialog("Delete all history?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    model.historyStore?.deleteAll(removeFolders: true, sparing: model.coordinator.activeSessionFolder)
                    model.coordinator.clearLastResult()
                    reload()
                }
            }
            .onAppear {
                reload()
                reloadStats()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gtHistoryDidChange).receive(on: RunLoop.main)) { _ in
                reload()
                reloadStats()
            }
        } placeholder: {
            DetailPlaceholder(systemImage: "text.alignleft", title: "No dictation selected")
        }
    }

    private func delete(_ offsets: IndexSet, from sectionRecords: [DictationRecord]) {
        for index in offsets { model.historyStore?.delete(id: sectionRecords[index].id, removeFolder: true) }
        reload()
    }

    private func reload() {
        records = model.historyStore?.records(matching: search.isEmpty ? nil : search) ?? []
    }

    /// Not on each search keystroke: the query does not change the stats.
    private func reloadStats() {
        hasStats = (model.historyStore?.stats().activeDays ?? 0) > 0
    }
}

/// The row above the days that opens Statistics, as the stats head the
/// Mac's History list.
private struct StatsLinkRow: View {
    /// `.increased` while the row is selected in the iPad split view, on the
    /// accent fill.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        HStack(spacing: Theme.Spacing.m) {
            IconTile(systemImage: "chart.bar.xaxis", tint: selected ? Theme.Colors.onAccent : Theme.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Statistics")
                    .font(Theme.Fonts.callout())
                    .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.ink)
                Text("Words, speed, time saved and streaks")
                    .font(Theme.Fonts.caption())
                    .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.8) : Theme.Colors.muted)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

private struct HistoryDaySection: Identifiable {
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

private struct HistoryEmptyState: View {
    let isSearching: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            IconTile(systemImage: isSearching ? "magnifyingglass" : "waveform", size: 72)
            Text(isSearching ? "No results" : "No dictations yet")
                .font(Theme.Fonts.title2())
                .foregroundStyle(Theme.Colors.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.canvas)
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    /// `.increased` while the row is selected in the iPad split view, on the
    /// accent fill.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        let ink = selected ? Theme.Colors.onAccent : Theme.Colors.ink
        let muted = selected ? Theme.Colors.onAccent.opacity(0.8) : Theme.Colors.muted
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Text(record.displayText.isEmpty ? statusLabel : record.displayText)
                    .font(Theme.Fonts.callout())
                    .foregroundStyle(record.displayText.isEmpty ? muted : ink)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statusView
            }
            Text(meta)
                .font(Theme.Fonts.caption())
                .foregroundStyle(muted)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    @ViewBuilder private var statusView: some View {
        if record.status == "failed" {
            Text("Failed")
                .font(Theme.Fonts.caption())
                .foregroundStyle(Theme.Colors.recording)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.Colors.recording.opacity(0.12)))
        } else if record.status == "queuedForRetry" {
            StatusChip(text: "Waiting to send", tone: .pending)
        }
    }

    private var meta: String {
        let time = record.startedAt.formatted(date: .omitted, time: .shortened)
        return [time, AppNames.name(for: record)].compactMap { $0 }.joined(separator: " · ")
    }

    private var statusLabel: String {
        switch record.status {
        case "failed": return "Failed"
        case "queuedForRetry": return "Waiting to send"
        case "silent": return "No speech"
        case "cancelled": return "Cancelled"
        case "recording", "recorded", "transcribing": return "In progress"
        default: return "Empty"
        }
    }
}

private struct HistoryDetail: View {
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
