import AppKit
import SwiftUI
import VoiceIQCore

/// The History pane of the main window: proof that nothing is ever lost.
/// Stats, search and the day-grouped list on the left; the selected
/// dictation on the right with audio playback, retry, copy and delete.
struct HistoryPane: View {
    let store: HistoryStore
    var usage: UsageStore?
    let onRetry: (DictationRecord) -> Void

    @State private var query = ""
    @State private var records: [DictationRecord] = []
    @State private var costs: [String: Double] = [:]
    @State private var stats = HistoryStore.Stats(totalWords: 0, totalDictations: 0, averageWPM: 0)
    @AppStorage("historyStatsPeriod") private var statsPeriod = HistoryStore.StatsPeriod.allTime
    @State private var selection: String?
    @FocusState private var listFocused: Bool
    @State private var showAllAttention = false
    @State private var confirmingDiscardAll = false
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        Group {
            // Stats outlive History, so the sidebar stays after it is cleared.
            if records.isEmpty && query.isEmpty && stats.activeDays == 0 {
                emptyState
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 300)
                    // Same as Meetings: a rectangle reaches the top edge under the transparent titlebar.
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .ignoresSafeArea(.container, edges: .top)
                    Group {
                        if let record = selected {
                            DictationDetail(
                                record: record,
                                calls: usage?.records(forSession: record.id) ?? [],
                                onRetry: { onRetry(record) },
                                onDelete: { delete(record) }
                            )
                            .id(record.id)
                        } else {
                            ContentUnavailableView("No Dictation Selected", systemImage: "waveform")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear(perform: reload)
        // Live pane: dictations landing, retries draining, and deletions all
        // announce themselves — no polling, no guessed delays.
        .onReceive(
            NotificationCenter.default.publisher(for: .gtHistoryDidChange)
                .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        ) { _ in
            reload()
        }
    }

    private var selected: DictationRecord? { records.first { $0.id == selection } }

    // MARK: - Sidebar (stats + search + list)

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.s) {
                HStack(spacing: VoiceIQUI.Spacing.xs) {
                    Text("History")
                        .font(VoiceIQUI.TypeScale.display(grad: grad))
                        .foregroundStyle(VQ.Colors.ink)
                    Spacer(minLength: 0)
                    periodPicker
                }
                statsLine
                searchField
            }
            .padding(.horizontal, VQ.Spacing.page)
            .padding(.top, VoiceIQUI.Spacing.l)
            .padding(.bottom, VoiceIQUI.Spacing.xxs)
            recordList
        }
    }

    private var periodPicker: some View {
        SearchablePicker("", selection: $statsPeriod,
                         options: HistoryStore.StatsPeriod.allCases.map { SearchOption(value: $0, name: $0.title) })
        .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
        .fixedSize()
        .onChange(of: statsPeriod) { _, _ in reload() }
    }

    /// The totals in one muted line under the title; streaks and audio in its tooltip.
    private var statsLine: some View {
        let parts = [
            "\(stats.totalWords.formatted(.number.notation(.compactName))) words",
            stats.averageWPM > 0 ? "\(stats.averageWPM) wpm" : nil,
            stats.minutesSaved > 0 ? "\(stats.savedLabel) saved" : nil,
        ].compactMap { $0 }
        return Text(parts.joined(separator: " · "))
            .font(VoiceIQUI.TypeScale.label(grad: grad))
            .foregroundStyle(VQ.Colors.muted)
            .lineLimit(1)
            .monospacedDigit()
            .help("\(stats.totalDictations) dictations, \(stats.audioLabel) of audio. Streak: \(stats.currentStreak) days, longest \(stats.longestStreak), active on \(stats.activeDays) days")
    }

    private var searchField: some View {
        HStack(spacing: VoiceIQUI.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your dictations", text: $query)
                .textFieldStyle(.plain)
                .font(VoiceIQUI.TypeScale.body(grad: grad))
                .onChange(of: query) { _, _ in reloadRecords() }
        }
        .padding(.horizontal, VoiceIQUI.Spacing.s)
        .frame(height: 32)
        .background(Capsule().fill(VQ.Colors.fill))
    }

    // MARK: - List

    private var groupedTimeline: [(day: String, items: [DictationRecord])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        var groups: [(String, [DictationRecord])] = []
        for record in timeline {
            let day = formatter.string(from: record.startedAt)
            if groups.last?.0 == day {
                groups[groups.count - 1].1.append(record)
            } else {
                groups.append((day, [record]))
            }
        }
        return groups.map { (day: $0.0, items: $0.1) }
    }

    /// Rows needing action (retryable) — pinned above the timeline of words.
    private var attention: [DictationRecord] {
        records.filter { record in
            record.displayText.isEmpty || SessionMeta.Status(rawValue: record.status) == .queuedForRetry
                || SessionMeta.Status(rawValue: record.status) == .failed
        }
    }

    private var timeline: [DictationRecord] {
        records.filter { record in
            !record.displayText.isEmpty && SessionMeta.Status(rawValue: record.status) != .queuedForRetry
                && SessionMeta.Status(rawValue: record.status) != .failed
        }
    }

    private var recordList: some View {
        List(selection: $selection) {
            if !attention.isEmpty {
                Section {
                    // Capped shelf: attention must never bury the timeline of words.
                    ForEach(showAllAttention ? attention : Array(attention.prefix(3)), id: \.id) { record in
                        attentionRow(record)
                    }
                    if attention.count > 3 {
                        Button(showAllAttention ? "Show less" : "Show \(attention.count - 3) more") {
                            showAllAttention.toggle()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(VQ.Colors.accent)
                        .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                    }
                } header: {
                    HStack(spacing: VoiceIQUI.Spacing.xxs) {
                        Circle().fill(VQ.Colors.warning).frame(width: 6, height: 6)
                        Text("Needs attention (\(attention.count))")
                            .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Discard All") {
                            confirmingDiscardAll = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(VQ.Colors.accent)
                        .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                        .confirmationDialog(
                            "Discard all \(attention.count) recordings that need attention? Their audio will be deleted.",
                            isPresented: $confirmingDiscardAll
                        ) {
                            Button("Discard \(attention.count) Recordings", role: .destructive) {
                                for record in attention {
                                    store.delete(id: record.id, removeFolder: true)
                                }
                                reload()
                            }
                        }
                    }
                }
            }
            ForEach(groupedTimeline, id: \.day) { group in
                Section {
                    ForEach(group.items, id: \.id) { record in
                        row(record)
                    }
                } header: {
                    Text(group.day)
                        .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .focused($listFocused)
        // Row text lands on the page margin, under the title and search field.
        .padding(.horizontal, 8)
        .overlay { if records.isEmpty { Text(query.isEmpty ? "No dictations" : "No matches").foregroundStyle(.secondary) } }
        // ⌘C copies the selected dictation, as FluidVoice's history does (altic-dev/FluidVoice).
        .onCopyCommand {
            guard let text = selected?.displayText, !text.isEmpty else { return [] }
            return [NSItemProvider(object: text as NSString)]
        }
    }

    private func attentionRow(_ record: DictationRecord) -> some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(attentionTitle(record))
                    .font(VoiceIQUI.TypeScale.body(grad: grad))
                    .foregroundStyle(.primary)
                // One line joined with dots, as on the rows below; it fits beside Retry.
                Text([
                    record.targetAppName,
                    record.durationSeconds.map { String(format: "%.0fs", $0) },
                    record.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                ].compactMap { $0 }.joined(separator: " · "))
                .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            // Retry needs something to retry: no audio and no transcript is a
            // dead-end button that can only re-fail (production pass 2).
            if audioExists(record) || record.rawTranscript != nil {
                Button("Retry") {
                    onRetry(record)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button {
                store.delete(id: record.id, removeFolder: true)
                reload()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Discard this recording")
        }
        .padding(.vertical, 3)
        .tag(record.id)
        .listRowBackground(ListSelectionBackground(selected: selection == record.id, focused: listFocused))
    }

    private func audioExists(_ record: DictationRecord) -> Bool {
        FileManager.default.fileExists(atPath: FileLayout.audioCAF(in: record.folderURL).path)
    }

    private func attentionTitle(_ record: DictationRecord) -> String {
        switch SessionMeta.Status(rawValue: record.status) {
        case .queuedForRetry: return "Waiting for network"
        case .cancelled:
            // Only claim "audio kept" when it actually is (retention truth).
            return audioExists(record)
                ? "Cancelled recording — audio kept"
                : "Cancelled recording — audio deleted by your retention setting"
        case .failed where record.errorCode == "audio_purged":
            return "Audio was deleted by your retention setting"
        case .failed where record.errorCode == "tooNoisy":
            return "Too noisy — no speech heard"
        case .failed where record.errorCode == "bad_request": return "Couldn't process this one"
        case .failed where record.errorCode == "model": return "Model not available to your key — see Settings → Advanced"
        case .failed: return "Transcription failed"
        default: return "Recovered recording"
        }
    }

    private func row(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: VoiceIQUI.Spacing.xxs) {
                Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                if let app = record.targetAppName {
                    Text("·")
                    Text(app).lineLimit(1)
                }
                if let duration = record.durationSeconds {
                    Text("·")
                    Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                }
                if let cost = costs[record.id] {
                    Text("·")
                    Text(CostPane.money(cost))
                }
            }
            .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Text(record.displayText.isEmpty ? "—" : record.displayText.prefix(220).split(whereSeparator: \.isNewline).joined(separator: " "))
                .font(VoiceIQUI.TypeScale.body(grad: grad))
                .lineLimit(2)
            statusChip(record)
        }
        .padding(.vertical, 5)
        .tag(record.id)
        .listRowBackground(ListSelectionBackground(selected: selection == record.id, focused: listFocused))
        .contextMenu {
            Button("Copy") { copy(record) }
            if !record.isFromOtherDevice {
                Button("Retry Transcription") { onRetry(record) }
            }
            Divider()
            Button("Delete", role: .destructive) { delete(record) }
        }
    }

    @ViewBuilder
    private func statusChip(_ record: DictationRecord) -> some View {
        // Timeline rows all carry words; only paste-state chips remain relevant
        // (failures live in the Needs-attention shelf above).
        switch SessionMeta.Status(rawValue: record.status) {
        case .awaitingChip:
            // Only trustworthy for a few minutes — the clipboard moves on.
            if Date().timeIntervalSince(record.startedAt) < 300 {
                chip("Ready to paste", color: VoiceIQUI.Colors.primary)
            } else {
                chip("Wasn't pasted", color: Color.secondary)
            }
        case .recovered:
            chip("Recovered", color: VoiceIQUI.Colors.primary)
        case .heldSecure:
            chip("Kept — secure field", color: Color.secondary)
        case .cancelled:
            chip("Cancelled", color: Color.secondary)
        default:
            EmptyView()
        }
    }

    /// Human words, never raw enum values, in the detail sheet.
    static func statusDisplayName(_ record: DictationRecord) -> String {
        if let origin = record.origin { return "Dictated on \(origin)" }
        switch SessionMeta.Status(rawValue: record.status) {
        case .inserted: return "Inserted at the cursor"
        case .copiedToClipboard: return "Copied to the clipboard"
        case .awaitingChip: return "Ready to paste"
        case .recovered: return "Recovered — use Copy to grab the text"
        case .heldSecure: return "Kept — secure field blocked insertion"
        case .queuedForRetry: return "Queued — retries automatically"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case .silent: return "No speech detected"
        case .recording, .recorded, .transcribing, .none: return record.status
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var emptyState: some View {
        VStack(spacing: VoiceIQUI.Spacing.m) {
            Spacer()
            Text("Nothing here yet")
                .font(VoiceIQUI.TypeScale.display(grad: grad))
            Text("Press \(SettingsStore().dictationTrigger.displayName) and say hello.")
                .font(VoiceIQUI.TypeScale.body(grad: grad))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func copy(_ record: DictationRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.displayText, forType: .string)
    }

    private func delete(_ record: DictationRecord) {
        store.delete(id: record.id, removeFolder: true)
        reload()
    }

    private func reload() {
        reloadRecords()
        stats = store.stats(period: statsPeriod)
    }

    /// Search changes only the list; the stats ignore the query.
    private func reloadRecords() {
        records = store.records(matching: query.isEmpty ? nil : query)
        if selected == nil { selection = timeline.first?.id ?? attention.first?.id }
        costs = usage?.costBySession(ids: records.map(\.id)) ?? [:]
    }

}
