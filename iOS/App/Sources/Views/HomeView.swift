import SwiftUI
import VoiceIQCore

/// Home is the dictation history: a title, the setup checklist until it is
/// done, a search, and every dictation grouped by day as a hairline list. The
/// dock at the bottom tries the keyboard or records a note.
struct HomeView: View {
    @Binding var tab: RootView.Tab
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: VoiceSession
    @EnvironmentObject private var setup: SetupMonitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var records: [DictationRecord] = []
    @State private var search = ""
    @State private var stats: HistoryStore.Stats?
    @State private var confirmDeleteAll = false
    @State private var tryingKeyboard = false

    private var sections: [HistoryDaySection] { HistoryDaySection.group(records) }

    var body: some View {
        ListDetailNavigation {
            List {
                if search.isEmpty { overview }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.records) { record in
                            DictationRow(record: record, delete: { delete(record) })
                                .background {
                                    // The id gives each dictation its own detail state;
                                    // without it the split view kept showing the first
                                    // one opened.
                                    NavigationLink("") { HistoryDetail(record: record, reload: reload).id(record.id) }
                                        .opacity(0)
                                }
                                .homeRow()
                        }
                        .onDelete { offsets in offsets.forEach { delete(section.records[$0]) } }
                    } header: {
                        Text(section.title)
                            .font(Theme.Fonts.caption())
                            .foregroundStyle(Theme.Colors.muted)
                            .textCase(nil)
                    }
                }
                if !search.isEmpty && records.isEmpty {
                    Text("No dictations match “\(search)”.")
                        .font(Theme.Fonts.callout())
                        .foregroundStyle(Theme.Colors.muted)
                        .homeRow(separator: false)
                }
                // Room for the dock, so the last row scrolls clear of it.
                Color.clear.frame(height: 72).homeRow(separator: false)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.canvas.ignoresSafeArea())
            .keyboardDismissable()
            .searchable(text: $search, prompt: "Search what you said")
            .onChange(of: search) { _, _ in reload() }
            .navigationTitle("VoiceiQ")
            .toolbar { toolbar }
            .overlay(alignment: .bottom) { dock }
            .confirmationDialog("Delete all history?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    model.historyStore?.deleteAll(removeFolders: true, sparing: model.coordinator.activeSessionFolders)
                    model.coordinator.clearLastResult()
                    reload()
                }
            }
            .sheet(isPresented: $tryingKeyboard) { TryKeyboardSheet() }
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .gtHistoryDidChange).receive(on: RunLoop.main)) { _ in refresh() }
        } placeholder: {
            DetailPlaceholder(systemImage: "text.alignleft", title: "No dictation selected")
        }
    }

    /// Above the days: setup until it is done, the iPad's hardware keyboard
    /// steps, and one line of totals that opens Statistics.
    @ViewBuilder private var overview: some View {
        if !setup.status.isComplete {
            SetupCard().homeRow(separator: false)
        }
        if UIDevice.isPad {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                GroupLabel(text: "Hardware keyboard")
                Card { HardwareKeyboardSteps() }
            }
            .homeRow(separator: false)
        }
        if let stats, stats.totalDictations > 0 {
            NavigationLink { StatsView() } label: { StatsLine(stats: stats) }
                .homeRow(separator: false)
        } else if records.isEmpty {
            Text("Your dictations will appear here. Tap the mic on the VoiceiQ keyboard in any app, or try it below.")
                .font(Theme.Fonts.callout())
                .foregroundStyle(Theme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .homeRow(separator: false)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if session.isActive { SessionChip() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                NavigationLink { StatsView() } label: { Label("Statistics", systemImage: "chart.bar") }
                if !records.isEmpty {
                    Button("Delete All History", systemImage: "trash", role: .destructive) { confirmDeleteAll = true }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    private var dock: some View {
        HStack(spacing: Theme.Spacing.m) {
            DockCapsule(action: { tryingKeyboard = true }) {
                Image(systemName: "keyboard")
                Text("Try the VoiceiQ keyboard")
            }
            TalkKey(recording: model.meetings.isRecording) {
                if !model.meetings.isRecording { model.startMeeting() }
                tab = .meetings
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    private func delete(_ record: DictationRecord) {
        model.historyStore?.delete(id: record.id, removeFolder: true)
        reload()
    }

    private func reload() {
        records = model.historyStore?.records(matching: search.isEmpty ? nil : search) ?? []
    }

    private func refresh() {
        setup.refresh()
        stats = model.historyStore?.stats()
        reload()
    }
}

private extension View {
    /// A row on the canvas at the page margin, with a hairline between rows.
    func homeRow(separator: Bool = true) -> some View {
        listRowBackground(Theme.Colors.canvas)
            .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.page, bottom: 0, trailing: Theme.Spacing.page))
            .listRowSeparator(separator ? .visible : .hidden)
            .listRowSeparatorTint(Theme.Colors.hairline)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}

/// One dictation: time and app, the text, then its length and actions.
private struct DictationRow: View {
    let record: DictationRecord
    let delete: () -> Void
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(meta)
                statusView
            }
            .font(Theme.Fonts.footnote())
            .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.8) : Theme.Colors.muted)
            Text(record.displayText.isEmpty ? statusLabel : record.displayText)
                .font(Theme.Fonts.body())
                .foregroundStyle(record.displayText.isEmpty ? Theme.Colors.muted : (selected ? Theme.Colors.onAccent : Theme.Colors.ink))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if let seconds = record.durationSeconds, seconds > 0 { DurationChip(seconds: seconds) }
                Spacer()
                Menu {
                    if !record.displayText.isEmpty {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = record.displayText }
                        ShareLink(item: record.displayText)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Colors.muted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Actions")
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder private var statusView: some View {
        if record.status == "failed" {
            Text("· Failed").foregroundStyle(Theme.Colors.recording)
        } else if record.status == "queuedForRetry" {
            Text("· Waiting to send").foregroundStyle(Theme.Colors.pending)
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

/// Totals in one muted line under the title; it opens Statistics.
private struct StatsLine: View {
    let stats: HistoryStore.Stats

    var body: some View {
        let parts = [
            "\(stats.totalWords.formatted(.number.notation(.compactName))) words",
            stats.averageWPM > 0 ? "\(stats.averageWPM) wpm" : nil,
            stats.currentStreak > 1 ? "\(stats.currentStreak)-day streak" : nil,
        ].compactMap { $0 }
        HStack(spacing: 4) {
            Text(parts.joined(separator: " · "))
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
        }
        .font(Theme.Fonts.footnote())
        .foregroundStyle(Theme.Colors.muted)
        .padding(.vertical, Theme.Spacing.xs)
    }
}

/// While the mic session is on: a capsule with the time left that turns it off.
private struct SessionChip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        Menu {
            Text("The keyboard's mic starts in place while this is on.")
            Button("Turn Off Now", systemImage: "mic.slash", action: model.endSession)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Theme.Colors.success).frame(width: 7, height: 7)
                if let until = session.warmUntil {
                    // The warm timer can fire just after the deadline; a range
                    // that ends before it starts traps.
                    Text(timerInterval: Date()...max(until, Date()), countsDown: true).monospacedDigit()
                } else {
                    Text(session.dictationPhase == .processing ? "Writing…" : "Mic on")
                }
            }
            .font(Theme.Fonts.label())
            .foregroundStyle(Theme.Colors.ink)
        }
        .accessibilityLabel("Mic session on")
    }
}

/// The keyboard tryout, as a sheet from the dock.
private struct TryKeyboardSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                TryItCard()
                    .padding(Theme.Spacing.page)
            }
            .themedBackground()
            .navigationTitle("Try the keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SetupCard: View {
    @EnvironmentObject private var setup: SetupMonitor

    var body: some View {
        let status = setup.status
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            GroupLabel(text: "Finish setup")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink { KeysView() } label: {
                        SetupLine(title: "API key", done: status.hasKey)
                    }
                    Divider().padding(.leading, 52)
                    NavigationLink { KeyboardSetupView() } label: {
                        SetupLine(title: "Microphone", done: status.micGranted)
                    }
                    Divider().padding(.leading, 52)
                    NavigationLink { KeyboardSetupView() } label: {
                        SetupLine(title: "Keyboard and Full Access", done: status.keyboardReady,
                                  waiting: status.keyboardAdded && !status.fullAccess)
                    }
                }
            }
        }
    }
}

private struct SetupLine: View {
    let title: String
    let done: Bool
    var waiting = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: done ? "checkmark.circle.fill" : waiting ? "clock" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(done ? Theme.Colors.success : waiting ? Theme.Colors.pending : Theme.Colors.muted.opacity(0.6))
                .frame(width: 24)
            Text(title).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Colors.muted)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// All-time figures; tapping them opens Statistics, with its period menu.
private struct StatsRow: View {
    let stats: HistoryStore.Stats

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                GroupLabel(text: "Statistics")
                Spacer()
                NavigationLink("See all") { StatsView() }
                    .font(Theme.Fonts.label())
                    .foregroundStyle(Theme.Colors.accent)
            }
            NavigationLink { StatsView() } label: {
                Grid(horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.m) {
                    GridRow {
                        StatTile(value: stats.totalWords.formatted(.number.notation(.compactName)), label: "Words")
                        StatTile(value: stats.totalDictations.formatted(), label: "Dictations")
                    }
                    GridRow {
                        StatTile(value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "–", label: "Words / min")
                        StatTile(value: stats.audioLabel, label: "Audio")
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct RecentList: View {
    let records: [DictationRecord]
    let seeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                GroupLabel(text: "Recent")
                Spacer()
                Button("See all", action: seeAll).font(Theme.Fonts.label()).foregroundStyle(Theme.Colors.accent)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider().padding(.leading, Theme.Spacing.l) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.displayText.isEmpty ? "No text" : record.displayText)
                                .font(Theme.Fonts.callout())
                                .foregroundStyle(Theme.Colors.ink)
                                .lineLimit(2)
                            Text(meta(record)).font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, Theme.Spacing.m)
                    }
                }
            }
        }
    }

    private func meta(_ record: DictationRecord) -> String {
        let when = record.startedAt.formatted(.relative(presentation: .named))
        return [when, AppNames.name(for: record)].compactMap { $0 }.joined(separator: " · ")
    }
}
