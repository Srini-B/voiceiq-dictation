import SwiftUI
import VoiceIQCore

struct MeetingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var meetings: [MeetingMeta] = []

    var body: some View {
        ListDetailNavigation {
            List {
                Section {
                    RecorderCard(meetings: model.meetings)
                        // The inset-grouped list already margins its rows;
                        // zero here keeps the card flush with the rows below.
                        .listRowInsets(EdgeInsets(top: Theme.Spacing.s, leading: 0,
                                                  bottom: Theme.Spacing.l, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if !meetings.isEmpty {
                    Section("Past notes") {
                        ForEach(meetings) { meta in
                            NavigationLink { MeetingDetail(meta: meta) } label: { MeetingRow(meta: meta) }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listRowBackground(Theme.Colors.surface)
            .themedBackground()
            .navigationTitle("Notes")
            .onAppear(perform: reload)
            .onReceive(model.meetings.$phase) { _ in reload() }
            .onReceive(model.meetings.$processing) { _ in reload() }
        } placeholder: {
            DetailPlaceholder(systemImage: "doc.text", title: "No note selected")
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { try? model.meetings.store.delete(id: meetings[index].id) }
        reload()
    }

    private func reload() {
        meetings = model.meetings.store.list().sorted { $0.startedAt > $1.startedAt }
    }
}

private struct RecorderCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var meetings: MeetingEngine
    @State private var pulse = false

    var body: some View {
        Card(padding: Theme.Spacing.xl) {
            switch meetings.phase {
            case let .recording(_, since): recording(since: since)
            default: idle
            }
        }
    }

    private var idle: some View {
        VStack(spacing: Theme.Spacing.m) {
            Button(action: model.startMeeting) {
                ZStack {
                    Circle().fill(Theme.Colors.recording).frame(width: 72, height: 72)
                    Circle().fill(Color.white).frame(width: 24, height: 24)
                }
            }
            .buttonStyle(.plain)
            .frame(minWidth: 72, minHeight: 72)
            .accessibilityLabel("Record notes")
            Text("Record notes").font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
            Text("Records the room with your \(UIDevice.current.localizedModel)'s mic.")
                .font(Theme.Fonts.footnote())
                .foregroundStyle(Theme.Colors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func recording(since: Date) -> some View {
        VStack(spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.s) {
                Circle()
                    .fill(Theme.Colors.recording)
                    .frame(width: 10, height: 10)
                    .opacity(pulse ? 0.35 : 1)
                    .scaleEffect(pulse ? 0.8 : 1)
                Text("Recording").font(Theme.Fonts.label()).foregroundStyle(Theme.Colors.recording)
            }
            Text(timerInterval: since...Date.distantFuture, countsDown: false)
                .font(Theme.Fonts.numeric(48, weight: 250))
                .foregroundStyle(Theme.Colors.ink)
            Button(action: model.stopMeeting) {
                Label("Stop", systemImage: "stop.fill")
                    .font(Theme.Fonts.label())
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, Theme.Spacing.l)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Theme.Colors.recording))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct MeetingRow: View {
    let meta: MeetingMeta
    /// `.increased` while the row is selected in the iPad split view.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(meta.title ?? "Notes")
                    .font(Theme.Fonts.callout())
                    .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.ink)
                    .lineLimit(1)
                Text("\(meta.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(duration)")
                    .font(Theme.Fonts.caption())
                    .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.8) : Theme.Colors.muted)
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    @ViewBuilder private var status: some View {
        switch meta.status {
        case .done: EmptyView()
        case .failed:
            Text("Failed")
                .font(Theme.Fonts.caption())
                .foregroundStyle(Theme.Colors.recording)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Theme.Colors.recording.opacity(0.12)))
        default: StatusChip(text: "Processing", tone: .pending)
        }
    }

    private var duration: String {
        Duration.seconds(meta.durationSeconds).formatted(.time(pattern: .minuteSecond))
    }
}

private struct MeetingDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var meta: MeetingMeta
    @State private var notes: MeetingNotes?
    @State private var transcript: [TranscriptSegment] = []
    /// Markdown files to share, one per export choice.
    @State private var exports: [(label: String, url: URL)] = []
    /// The speaker whose name is being typed.
    @State private var naming: String?
    @State private var draft = ""

    init(meta: MeetingMeta) { _meta = State(initialValue: meta) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let notes { notesContent(notes) }
                else if case .failed(let reason) = meta.status { failureCard(reason) }
                else { processingCard }
                if !transcript.isEmpty { transcriptContent }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.l)
            .readableWidth()
        }
        .themedBackground()
        .navigationTitle(notes?.title ?? meta.title ?? "Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if meta.status == .done {
                Menu {
                    Button("Notes") { model.meetings.regenerateNotes(id: meta.id) }.disabled(transcript.isEmpty)
                    Button("Transcript and notes") { model.meetings.retry(id: meta.id) }
                } label: { Label("Redo", systemImage: "arrow.clockwise") }
                    .disabled(model.meetings.isBusy(meta.id))
            }
            if !exports.isEmpty {
                Menu {
                    ForEach(exports, id: \.label) { export in ShareLink(export.label, item: export.url) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
        }
        .alert("Name", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $draft)
            Button("Save") { if let naming { rename(naming, draft) } }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear(perform: load)
        .onReceive(model.meetings.$processing) { busy in if !busy.contains(meta.id) { load() } }
    }

    @ViewBuilder private func notesContent(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(notes.title).font(Theme.Fonts.title2()).foregroundStyle(Theme.Colors.ink)
                Spacer(minLength: Theme.Spacing.s)
                if let kind = notes.type.flatMap(MeetingKind.init(rawValue:)) {
                    StatusChip(text: kind.displayName, tone: .off)
                }
            }
            Card { Text(notes.summary).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink) }
        }
        ForEach(Array((notes.sections ?? []).enumerated()), id: \.offset) { _, section in
            if !section.items.isEmpty { bulletGroup(section.title, items: section.items) }
        }
        if !notes.decisions.isEmpty { bulletGroup("Decisions", items: notes.decisions) }
        if !notes.actions.isEmpty { actionItems(notes.actions) }
        if !notes.notes.isEmpty { bulletGroup("Notes", items: notes.notes) }
    }

    private func bulletGroup(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            GroupLabel(text: title)
            Card {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                            Text("•").foregroundStyle(Theme.Colors.accent)
                            Text(item).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink)
                        }
                    }
                }
            }
        }
    }

    private func actionItems(_ actions: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            GroupLabel(text: "Action items")
            Card {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                                Image(systemName: "circle").foregroundStyle(Theme.Colors.muted)
                                Text(action.owner.map { "\($0): " } ?? "").font(Theme.Fonts.body().weight(.semibold))
                                    + Text(action.text).font(Theme.Fonts.body())
                            }
                            .foregroundStyle(Theme.Colors.ink)
                            if let deadline = action.deadline {
                                Text(deadline).font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
                                    .padding(.leading, 28)
                            }
                        }
                    }
                }
            }
        }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            GroupLabel(text: "Transcript")
            Card {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    ForEach(Array(transcript.enumerated()), id: \.offset) { _, segment in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            HStack(spacing: Theme.Spacing.s) {
                                speakerMenu(segment.speaker)
                                Spacer(minLength: 0)
                                if let start = segment.start {
                                    Text(MeetingNotesPrompt.clock(start)).font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
                                }
                            }
                            Text(segment.text).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink)
                        }
                    }
                }
            }
        }
    }

    /// The speaker's name in their colour; tapping it offers the names this note knows.
    private func speakerMenu(_ speaker: String) -> some View {
        let hex = MeetingSpeaker.colorHex(speaker, others: MeetingSpeaker.others(in: transcript))
        let name = meta.displayName(speaker, notes: notes)
        return Menu {
            ForEach(meta.knownNames(notes), id: \.self) { candidate in
                Button { rename(speaker, candidate) } label: {
                    if candidate == name { Label(candidate, systemImage: "checkmark") } else { Text(candidate) }
                }
            }
            Button("Other name…") { draft = ""; naming = speaker }
            if !(meta.speakerNames[speaker] ?? "").isEmpty {
                Button("Reset", role: .destructive) { rename(speaker, "") }
            }
        } label: {
            HStack(spacing: 3) {
                Text(name).font(Theme.Fonts.label())
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.Colors.dynamic(light: hex.light, dark: hex.dark))
        }
    }

    private func rename(_ speaker: String, _ name: String) {
        try? model.meetings.store.renameSpeaker(id: meta.id, label: speaker, name: name)
        load()
    }

    private func failureCard(_ reason: String) -> some View {
        Card {
            Text(reason).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.muted)
            Button("Retry") { model.meetings.retry(id: meta.id) }.buttonStyle(.primaryPill)
        }
    }

    private var processingCard: some View {
        Card {
            HStack(spacing: Theme.Spacing.m) {
                ProgressView().tint(Theme.Colors.accent)
                Text("Writing notes").font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
            }
        }
    }

    private func load() {
        let store = model.meetings.store
        meta = store.list().first { $0.id == meta.id } ?? meta
        notes = try? store.loadNotes(id: meta.id)
        transcript = (try? store.loadTranscript(id: meta.id)) ?? []
        // Shared as files so "Save to Files" keeps a .md named after the note.
        let title = (notes?.title ?? meta.title ?? "Notes").replacingOccurrences(of: "/", with: "-")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(meta.id.uuid.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var choices: [(String, String, MeetingStore.ExportParts)] = []
        if notes != nil { choices.append(("Notes", " notes", .notes)) }
        if !transcript.isEmpty { choices.append(("Transcript", " transcript", .transcript)) }
        if notes != nil, !transcript.isEmpty { choices.append(("Notes and transcript", "", .both)) }
        exports = choices.compactMap { label, suffix, parts in
            let url = folder.appendingPathComponent(title + suffix + ".md")
            guard let text = try? store.markdown(id: meta.id, parts: parts),
                  (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
            return (label, url)
        }
    }
}
