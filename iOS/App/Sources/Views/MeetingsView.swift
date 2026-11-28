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
                        .listRowInsets(EdgeInsets(top: Theme.Spacing.s, leading: Theme.Spacing.page,
                                                  bottom: Theme.Spacing.l, trailing: Theme.Spacing.page))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if !meetings.isEmpty {
                    if let folder = folders.filterFolder {
                        Text(folder.name)
                            .font(Theme.Fonts.caption())
                            .foregroundStyle(Theme.Colors.muted)
                            .noteRow(separator: false)
                    }
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.meetings) { meta in
                                row(meta)
                            }
                            .onDelete { offsets in delete(offsets.map { section.meetings[$0] }) }
                        } header: {
                            Text(section.title)
                                .font(Theme.Fonts.caption())
                                .foregroundStyle(Theme.Colors.muted)
                                .textCase(nil)
                                .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.page, bottom: 0, trailing: Theme.Spacing.page))
                        }
                    }
                    if shown.isEmpty {
                        Text("No notes in this folder")
                            .font(Theme.Fonts.callout())
                            .foregroundStyle(Theme.Colors.muted)
                            .noteRow(separator: false)
                    }
                }
            }
            // A plain hairline list on the canvas, as Home (docs/design/redesign-2026-11.md).
            .listStyle(.plain)
            .themedBackground()
            .navigationTitle("Notes")
            .toolbar {
                // Also with no notes, as on the Mac: folders outlive their notes.
                Menu {
                    MeetingFolderFilterItems(model: folders, allTitle: "All notes")
                } label: {
                    Label("Folders", systemImage: folders.filter == nil ? "folder" : "folder.fill")
                }
                .tint(Theme.Colors.inkSecondary)
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

    private func row(_ meta: MeetingMeta) -> some View {
        MeetingRow(meta: meta, folders: folders.names(of: meta.id))
            // A hidden link, so the list adds no chevron (as Home). The id
            // gives each note its own detail state in the split view.
            .background {
                NavigationLink("") { MeetingDetail(meta: meta, folders: folders).id(meta.id) }
                    .opacity(0)
            }
            // Deleting mid-transcription would leave its AssemblyAI calls running
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
            .noteRow()
    }

    private var sections: [NoteDaySection] { NoteDaySection.group(shown) }

    private func delete(_ notes: [MeetingMeta]) {
        for meta in notes where !model.meetings.isBusy(meta.id) {
            try? model.meetings.store.delete(id: meta.id)
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
    meta.displayTitle() ?? "New note"
}

/// Notes grouped by the day they started, newest first, as Home groups dictations.
private struct NoteDaySection: Identifiable {
    let day: Date
    let meetings: [MeetingMeta]
    var id: Date { day }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    /// Keeps the order of `meetings` within each day.
    static func group(_ meetings: [MeetingMeta]) -> [NoteDaySection] {
        let grouped = Dictionary(grouping: meetings) { Calendar.current.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { NoteDaySection(day: $0, meetings: grouped[$0] ?? []) }
    }
}

private extension View {
    /// A row on the canvas at the page margin, with a hairline between rows, as on Home.
    func noteRow(separator: Bool = true) -> some View {
        listRowBackground(Theme.Colors.canvas)
            .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.page, bottom: 0, trailing: Theme.Spacing.page))
            .listRowSeparator(separator ? .visible : .hidden)
            .listRowSeparatorTint(Theme.Colors.hairline)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}

private struct RecorderCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var meetings: MeetingEngine
    @State private var pulse = false
    @State private var confirmingDiscard = false

    var body: some View {
        Group {
            switch meetings.phase {
            case let .recording(_, since): Card(padding: Theme.Spacing.xl) { recording(since: since) }
            // On the canvas, not in a card: cards are for Settings (docs/design/redesign-2026-11.md).
            default: idle.padding(.vertical, Theme.Spacing.xl)
            }
        }
        // An alert, not a confirmation dialog: on iOS 27 the dialog drew as a
        // popover with no background over the Past notes rows.
        .alert("Discard this recording?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { meetings.discardRecording() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("Its audio is deleted and no notes are made.")
        }
        // A recording that stops on its own never leaves its Discard question up.
        .onChange(of: meetings.phase) { _, phase in
            if case .recording = phase {} else { confirmingDiscard = false }
        }
    }

    private var idle: some View {
        VStack(spacing: Theme.Spacing.m) {
            // Brand blue until it records: red means recording only.
            TalkKey(recording: false, action: model.startMeeting)
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
            // Borderless: in a List row, a default-style button takes every tap on the card.
            Button("Discard", role: .destructive) { confirmingDiscard = true }
                .buttonStyle(.borderless)
                .font(Theme.Fonts.label())
                .frame(minHeight: 44)
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
        // Centred, so a status beside a tall row sits level with it.
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            // As a Home row: the meta line, the title, then the length.
            VStack(alignment: .leading, spacing: 6) {
                Text(metaLine)
                    .font(Theme.Fonts.footnote())
                    .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.8) : Theme.Colors.muted)
                Text(rowTitle(meta))
                    .font(Theme.Fonts.headline())
                    .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.ink)
                    .lineLimit(2)
                if !folders.isEmpty {
                    // Text, not a Label: a list row gives a Label's icon a column of its own.
                    Text("\(Image(systemName: "folder")) \(folders.joined(separator: ", "))")
                        .font(Theme.Fonts.caption())
                        .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.8) : Theme.Colors.muted)
                        .lineLimit(1)
                }
                // An import has no length to show (Granola's export has none).
                if meta.importedFrom == nil, meta.durationSeconds >= 1 {
                    DurationChip(seconds: meta.durationSeconds).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder private var status: some View {
        switch meta.status {
        case .done: EmptyView()
        // The note being recorded now, as the Mac's list marks it; not "Processing".
        case .recording:
            Label("Recording", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(Theme.Fonts.caption())
                .foregroundStyle(prominence == .increased ? Theme.Colors.onAccent : Theme.Colors.recording)
                .imageScale(.small)
        case .failed where meta.waitsForService != nil: StatusChip(text: "Waiting", tone: .pending)
        case .failed:
            // Not record red: red means recording only.
            Text("Failed")
                .font(Theme.Fonts.caption())
                .foregroundStyle(Theme.Colors.pending)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Theme.Colors.pending.opacity(0.12)))
        default: StatusChip(text: "Processing", tone: .pending)
        }
    }

    /// The time (the day is the section's header), then where the note came from.
    private var metaLine: String {
        let time = meta.startedAt.formatted(date: .omitted, time: .shortened)
        return [time, source].compactMap { $0 }.joined(separator: " · ")
    }

    private var source: String? {
        if let app = meta.importedFrom { return app }
        switch meta.source {
        case .app(_, let name)?: return name
        case .browser(_, let host)?: return host
        case nil: return nil
        }
    }
}

private struct MeetingDetail: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Deleted on another device while open.
    @State private var gone = false
    /// The large title has scrolled under the bar, which then shows it instead.
    @State private var titleHidden = false
    @State private var confirmingSplit = false
    /// The page title's bottom in the scroll content.
    @State private var titleBottom: CGFloat = .infinity
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
                 name: meta.displayTitle(notes: notes) ?? "Notes")
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
                    // Above the notes too: a failed redo keeps the old notes (Neon).
                    // Not during a Retry: its spinner replaces the old error.
                    if step == nil, let failure { failureCard(failure) }
                    if meta.speakersUnsplit == true, meta.status == .done, step == nil, !gone {
                        Card {
                            Text("The speaker model failed on this note, so some people may be shown as one speaker.")
                                .font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.muted)
                            // A synced note has no recording to split; sync never carries audio (Neon on #133).
                            if audio.isAvailable {
                                Button("Split speakers again") { confirmingSplit = true }.buttonStyle(.primaryPill)
                                    .alert("Split speakers again?", isPresented: $confirmingSplit) {
                                        Button("Split") { model.meetings.retry(id: meta.id) }
                                        Button("Cancel", role: .cancel) {}
                                    } message: {
                                        Text("The notes are written again, and edits to the transcript are replaced.")
                                    }
                            } else {
                                Text("Open this note on the Mac that recorded it to split speakers again.")
                                    .font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
                            }
                        }
                    }
                    if let notes { notesContent(notes) }
                    else if failure == nil && step == nil && !gone { processingCard(.summarizing) }
                    if let chat { MeetingChatTurns(chat: chat, scroller: scroller) }
                    if !gone {
                        section("Audio") { RecordingAudioControls(audio: audio) }
                    }
                    if !transcript.isEmpty { transcriptContent }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, Theme.Spacing.l)
                .readableWidth()
                .coordinateSpace(.named("note"))
            }
            // Measured in the content, so the bar's height on each device or window doesn't matter (Neon).
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top >= titleBottom } action: { _, past in
                titleHidden = past
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let chat { MeetingChatInput(chat: chat, noun: notes?.type.flatMap(MeetingKind.init(rawValue:)) == nil ? "note" : "meeting") }
        }
        .themedBackground()
        // Not twice: the bar shows the title only once the page's own has scrolled away (Fable, M6).
        .navigationTitle(notes == nil || titleHidden ? meta.displayTitle(notes: notes) ?? "New note" : "")
        .navigationBarTitleDisplayMode(.inline)
        // The title has the bar to itself; folders, redo and export are one menu (Fable, M6).
        .toolbar {
            if !gone || !exports.isEmpty {
                Menu {
                    if !gone {
                        Menu {
                            MeetingFolderToggles(model: folders, meeting: meta.id)
                        } label: {
                            Label("Folders", systemImage: folders.names(of: meta.id).isEmpty ? "folder" : "folder.fill")
                        }
                    }
                    if failure != nil && !gone {
                        Button { model.meetings.retry(id: meta.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                            .disabled(model.meetings.isBusy(meta.id))
                    } else if meta.status == .done && !gone {
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
                } label: { Label("More", systemImage: "ellipsis") }
            }
        }
        // Text scrolled under the bar no longer shows through beside the title.
        .toolbarBackground(Theme.Colors.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .modifier(HardTopEdge())
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
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(meta.displayTitle(notes: notes) ?? notes.title).font(Theme.Fonts.title()).foregroundStyle(Theme.Colors.ink)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("note")).maxY } action: { titleBottom = $0 }
            // The kind sits on the date line, so the title has the full width.
            HStack(spacing: Theme.Spacing.s) {
                Text(meta.whenText).font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
                if let kind = notes.type.flatMap(MeetingKind.init(rawValue:)) {
                    StatusChip(text: kind.displayName, tone: .off)
                }
            }
            if !speakers.isEmpty { people }
        }
        section("Summary") { Text(notes.summary).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink) }
        ForEach(Array((notes.sections ?? []).enumerated()), id: \.offset) { _, section in
            if !section.items.isEmpty { bulletGroup(section.title, items: section.items) }
        }
        if !notes.decisions.isEmpty { bulletGroup("Decisions", items: notes.decisions) }
        if !notes.actions.isEmpty { actionItems(notes.actions) }
        if !notes.notes.isEmpty { bulletGroup("Notes", items: notes.notes) }
    }

    /// The note owner first, then the others; an import without speaker labels has none.
    private var speakers: [String] {
        let others = MeetingSpeaker.others(in: transcript).filter { $0 != GranolaImport.unlabeledSpeaker }
        return (transcript.contains { $0.speaker == MeetingSpeaker.you } ? [MeetingSpeaker.you] : []) + others
    }

    /// Everyone heard, in plain muted text; their colours stay in the transcript.
    private var people: some View {
        let names = speakers.map { meta.displayName($0, notes: notes) }
        return Text(names.joined(separator: ", "))
            .font(Theme.Fonts.footnote())
            .foregroundStyle(Theme.Colors.muted)
            .accessibilityLabel("With " + names.joined(separator: ", "))
    }

    private func bulletGroup(_ title: String, items: [String]) -> some View {
        section(title) {
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

    private func actionItems(_ actions: [ActionItem]) -> some View {
        section("Action items") {
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

    private var transcriptContent: some View {
        section("Transcript") {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                let others = MeetingSpeaker.others(in: transcript)
                ForEach(MeetingSpeaker.turns(in: transcript)) { turn in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack(spacing: Theme.Spacing.s) {
                            speakerMenu(turn.speaker)
                            if let start = turn.start {
                                Text(MeetingNotesPrompt.clock(start)).font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
                            }
                        }
                        ForEach(turn.lines) { line in
                            lineText(line, others: others)
                                .padding(.leading, line.aside ? 12 : 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .contextMenu {
                                    // A redo running now would write over the change.
                                    if !model.meetings.isBusy(meta.id) && !gone {
                                        // An aside has no heading to tap; its speaker is named from here.
                                        if line.aside {
                                            Button("Name \(meta.displayName(line.segment.speaker, notes: notes))…", systemImage: "person.crop.circle") {
                                                naming = line.segment.speaker
                                            }
                                        }
                                        Button("Edit", systemImage: "pencil") { editing = line.segment }
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            try? model.meetings.store.deleteTranscriptSegment(line.segment.id, meeting: meta.id)
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

    /// A caption over hairline content, with no card around it, as on a dictation's page.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(Theme.Fonts.caption())
                .foregroundStyle(Theme.Colors.muted)
            Divider().overlay(Theme.Colors.hairline)
            content()
        }
    }

    /// A line of the turn; someone else's short reply shows under their name in their colour.
    private func lineText(_ line: TranscriptTurn.Line, others: [String]) -> Text {
        guard line.aside else { return Text(line.segment.text).font(Theme.Fonts.body()).foregroundColor(Theme.Colors.ink) }
        let hex = MeetingSpeaker.colorHex(line.segment.speaker, others: others)
        return Text(meta.displayName(line.segment.speaker, notes: notes) + "  ")
            .font(Theme.Fonts.label()).foregroundColor(Theme.Colors.dynamic(light: hex.light, dark: hex.dark))
            + Text(line.segment.text).font(Theme.Fonts.body()).foregroundColor(Theme.Colors.muted)
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

    private var failure: String? {
        if case .failed(let reason) = meta.status { reason } else { nil }
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
        let title = (meta.displayTitle(notes: notes) ?? "Notes").replacingOccurrences(of: "/", with: "-")
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

/// iOS 26 fades scrolled text under a glass bar instead of drawing the bar's
/// background; a hard edge keeps it out from under the title.
private struct HardTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.scrollEdgeEffectStyle(.hard, for: .top) } else { content }
    }
}
