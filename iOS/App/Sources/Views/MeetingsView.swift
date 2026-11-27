import SwiftUI
import VoiceIQCore

struct MeetingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var meetings: [MeetingMeta] = []
    @StateObject private var folders = MeetingFolderModel()
    /// The note a swipe is filing, in the folder sheet.
    @State private var filing: MeetingID?
    /// The note being renamed, and the title typed so far.
    @State private var renaming: MeetingMeta?
    @State private var titleDraft = ""

    var body: some View {
        ListDetailNavigation {
            List {
                NextMeetingSection()
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
                    Section(folders.filterFolder?.name ?? "Past notes") {
                        ForEach(shown) { meta in
                            NavigationLink { MeetingDetail(meta: meta, folders: folders) } label: {
                                MeetingRow(meta: meta, folders: folders.names(of: meta.id))
                            }
                            // Deleting mid-transcription would leave its Gemini calls running
                            // with nowhere to save (the Mac's More menu is disabled the same way).
                            .deleteDisabled(model.meetings.isBusy(meta.id))
                            .contextMenu {
                                Button("Rename…", systemImage: "pencil") { titleDraft = rowTitle(meta); renaming = meta }
                                    .disabled(model.meetings.isBusy(meta.id))
                                Menu("Folders", systemImage: "folder") { MeetingFolderToggles(model: folders, meeting: meta.id) }
                            }
                            // The iPhone's stand-in for the Mac's hover button.
                            .swipeActions(edge: .leading) {
                                Button("Folders", systemImage: "folder") { filing = meta.id }.tint(Theme.Colors.accent)
                            }
                        }
                        .onDelete(perform: delete)
                        if shown.isEmpty {
                            Text("No notes in this folder").font(Theme.Fonts.callout()).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listRowBackground(Theme.Colors.surface)
            .themedBackground()
            .navigationTitle("Notes")
            .toolbar {
                // Also with no notes, as on the Mac: folders outlive their notes.
                Menu {
                    MeetingFolderFilterItems(model: folders, allTitle: "All notes")
                } label: {
                    Label("Folders", systemImage: folders.filter == nil ? "folder" : "folder.fill")
                }
            }
            .onAppear(perform: reload)
            .onReceive(model.meetings.$phase) { _ in reload() }
            .onReceive(model.meetings.$processing) { _ in reload() }
            .onReceive(NotificationCenter.default.publisher(for: .gtMeetingsDidChange).receive(on: RunLoop.main)) { note in
                if note.object as? String == "sync" { reload() }
            }
        } placeholder: {
            DetailPlaceholder(systemImage: "doc.text", title: "No note selected")
        }
        .meetingFolderEditing(folders, noun: "notes")
        .alert("Rename Note", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $titleDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename", action: rename)
        } message: {
            Text("Leave it empty to use the title from the notes.")
        }
        .sheet(isPresented: Binding(get: { filing != nil }, set: { if !$0 { filing = nil } })) {
            if let filing {
                MeetingFolderPicker(model: folders, meeting: filing) { self.filing = nil }
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var shown: [MeetingMeta] { folders.shown(meetings) }

    private func delete(_ offsets: IndexSet) {
        let shown = shown
        for index in offsets where !model.meetings.isBusy(shown[index].id) {
            try? model.meetings.store.delete(id: shown[index].id)
        }
        reload()
    }

    private func rename() {
        guard let meta = renaming, titleDraft.trimmingCharacters(in: .whitespacesAndNewlines) != rowTitle(meta) else { return }
        try? model.meetings.store.renameMeeting(id: meta.id, title: titleDraft)
        reload()
    }

    private func reload() {
        meetings = model.meetings.store.list().sorted { $0.startedAt > $1.startedAt }
        folders.reload(meetings)
    }
}

/// The title a note's row shows.
private func rowTitle(_ meta: MeetingMeta) -> String {
    [meta.shownTitle(), meta.calendarEvent?.title].compactMap { $0 }.first { !$0.isEmpty } ?? "Notes"
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
    let folders: [String]
    /// `.increased` while the row is selected in the iPad split view.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(rowTitle(meta))
                    .font(Theme.Fonts.callout())
                    .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.ink)
                    .lineLimit(1)
                // An import has no length to show (Granola's export has none).
                Text(meta.importedFrom == nil
                     ? "\(meta.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(duration)"
                     : meta.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Fonts.caption())
                    .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.8) : Theme.Colors.muted)
                if !folders.isEmpty {
                    // Text, not a Label: a list row gives a Label's icon a column of its own.
                    Text("\(Image(systemName: "folder")) \(folders.joined(separator: ", "))")
                        .font(Theme.Fonts.caption())
                        .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.8) : Theme.Colors.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    @ViewBuilder private var status: some View {
        switch meta.status {
        case .done: EmptyView()
        case .failed where meta.waitsForGemini == true: StatusChip(text: "Waiting", tone: .pending)
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
    @Environment(\.dismiss) private var dismiss
    /// Deleted on another device while open.
    @State private var gone = false
    @State private var meta: MeetingMeta
    @State private var notes: MeetingNotes?
    @State private var transcript: [TranscriptSegment] = []
    /// Markdown files to share, one per export choice.
    @State private var exports: [(label: String, url: URL)] = []
    /// The speaker whose name is being chosen.
    @State private var naming: String?
    /// The transcript line in the edit sheet.
    @State private var editing: TranscriptSegment?
    /// What the note is doing in the background; nil when idle.
    @State private var step: MeetingStatus?
    @ObservedObject var folders: MeetingFolderModel

    init(meta: MeetingMeta, folders: MeetingFolderModel) {
        _meta = State(initialValue: meta)
        self.folders = folders
    }

    /// Nothing to play while the note is still recording.
    private var audio: RecordedAudio {
        .meeting(folder: meta.status == .recording ? nil : model.meetings.store.folder(for: meta.id),
                 name: meta.shownTitle(notes: notes) ?? "Notes")
    }

    /// Nil until the note has a transcript to ask about.
    private var chat: MeetingChatModel? {
        transcript.isEmpty ? nil : MeetingChatModel.shared(meta.id, store: model.meetings.store)
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if gone {
                        Card { Text("This note was deleted on another device.").font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.muted) }
                    }
                    let filedIn = folders.names(of: meta.id)
                    if !filedIn.isEmpty && !gone {
                        Label(filedIn.joined(separator: ", "), systemImage: "folder")
                            .font(Theme.Fonts.footnote())
                            .foregroundStyle(Theme.Colors.muted)
                    }
                    if let step { processingCard(step) }
                    if let notes { notesContent(notes) }
                    else if case .failed(let reason) = meta.status { failureCard(reason) }
                    else if step == nil && !gone { processingCard(.summarizing) }
                    if let chat { MeetingChatTurns(chat: chat, scroller: scroller) }
                    if !gone {
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            GroupLabel(text: "Audio")
                            Card { RecordingAudioControls(audio: audio) }
                        }
                    }
                    if !transcript.isEmpty { transcriptContent }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, Theme.Spacing.l)
                .readableWidth()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let chat { MeetingChatInput(chat: chat) }
        }
        .themedBackground()
        .navigationTitle(meta.displayTitle(notes: notes) ?? "Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !gone {
                Menu {
                    MeetingFolderToggles(model: folders, meeting: meta.id)
                } label: {
                    Label("Folders", systemImage: folders.names(of: meta.id).isEmpty ? "folder" : "folder.fill")
                }
            }
            if meta.status == .done && !gone {
                Menu {
                    Button("Notes") { model.meetings.regenerateNotes(id: meta.id) }.disabled(transcript.isEmpty)
                    Button("Transcript and notes") { model.meetings.retry(id: meta.id, fresh: true) }
                        .disabled(!audio.isAvailable)
                } label: { Label("Redo", systemImage: "arrow.clockwise") }
                    .disabled(model.meetings.isBusy(meta.id))
            }
            if !exports.isEmpty {
                Menu {
                    ForEach(exports, id: \.label) { export in ShareLink(export.label, item: export.url) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
        }
        .sheet(isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            if let speaker = naming { speakerNames(speaker) }
        }
        .sheet(item: $editing) { segment in
            TranscriptLineEditor(segment: segment, speaker: meta.displayName(segment.speaker, notes: notes)) { text in
                try? model.meetings.store.editTranscriptSegment(segment.id, text: text, meeting: meta.id)
                load()
            }
        }
        .onAppear(perform: load)
        .onReceive(model.meetings.$processing) { busy in
            step = busy[meta.id]
            if step == nil { load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtMeetingsDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == "sync", note.userInfo?[MeetingStore.idKey] as? String == meta.id.uuid.uuidString { load() }
        }
    }

    @ViewBuilder private func notesContent(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(meta.shownTitle(notes: notes) ?? notes.title).font(Theme.Fonts.title2()).foregroundStyle(Theme.Colors.ink)
                    Text(meta.whenText).font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
                }
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
                    ForEach(MeetingSpeaker.turns(in: transcript), id: \.[0].id) { turn in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            HStack(spacing: Theme.Spacing.s) {
                                speakerMenu(turn[0].speaker)
                                Spacer(minLength: 0)
                                if let start = turn[0].start {
                                    Text(MeetingNotesPrompt.clock(start)).font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
                                }
                            }
                            ForEach(turn) { segment in
                                Text(segment.text).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        // A redo running now would write over the change.
                                        if !model.meetings.isBusy(meta.id) && !gone {
                                            Button("Edit", systemImage: "pencil") { editing = segment }
                                            Button("Delete", systemImage: "trash", role: .destructive) {
                                                try? model.meetings.store.deleteTranscriptSegment(segment.id, meeting: meta.id)
                                                load()
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The speaker's name in their colour; tapping it offers the names this
    /// note knows, under a search field that also takes a new name.
    private func speakerMenu(_ speaker: String) -> some View {
        let hex = MeetingSpeaker.colorHex(speaker, others: MeetingSpeaker.others(in: transcript))
        let name = meta.displayName(speaker, notes: notes)
        return Button { naming = speaker } label: {
            HStack(spacing: 3) {
                Text(name).font(Theme.Fonts.label())
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.Colors.dynamic(light: hex.light, dark: hex.dark))
        }
    }

    private func speakerNames(_ speaker: String) -> some View {
        let name = meta.displayName(speaker, notes: notes)
        let pick: (String) -> Void = { rename(speaker, $0); naming = nil }
        return SearchableListSheet(title: "Speaker name", options: meta.knownNames(notes).map { SearchOption(value: $0, name: $0) },
                                   isSelected: { $0 == name }, prompt: "Search or type a name", other: pick,
                                   reset: (meta.speakerNames[speaker] ?? "").isEmpty ? nil : { pick("") }, choose: pick)
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

    private func processingCard(_ step: MeetingStatus) -> some View {
        Card {
            HStack(spacing: Theme.Spacing.m) {
                ProgressView().tint(Theme.Colors.accent)
                Text(step == .transcribing ? "Transcribing" : "Writing notes").font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
            }
        }
    }

    private func load() {
        let store = model.meetings.store
        guard let current = store.list().first(where: { $0.id == meta.id }) else {
            gone = true; notes = nil; transcript = []; exports = []
            dismiss()
            return
        }
        meta = current
        notes = try? store.loadNotes(id: meta.id)
        transcript = (try? store.loadTranscript(id: meta.id)) ?? []
        // Shared as files so "Save to Files" keeps a .md named after the note.
        let title = (meta.shownTitle(notes: notes) ?? "Notes").replacingOccurrences(of: "/", with: "-")
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
