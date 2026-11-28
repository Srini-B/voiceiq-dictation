import AppKit
import VoiceIQCore
import SwiftUI

struct MeetingsPane: View {
    @ObservedObject var engine: MeetingEngine
    let store: MeetingStore
    @State private var meetings: [MeetingMeta] = []
    @State private var selection: MeetingID?
    @State private var notes: MeetingNotes?
    @State private var transcript: [TranscriptSegment] = []
    /// Side by side: the transcript column is shown. Narrow: the transcript replaces the notes.
    @State private var hidesTranscript = false
    @State private var narrowShowsTranscript = false
    @State private var assigning = false
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false
    @State private var confirmingSplit = false
    @State private var renaming = false
    @State private var titleDraft = ""
    /// The selected meeting is a call whose other side was never heard (`SilentSystemAudio`).
    @State private var unheardCall: (id: MeetingID, why: SilentSystemAudio.Unheard)?
    @State private var exported: ExportResult?
    @StateObject private var folders = MeetingFolderModel()
    /// The row under the pointer, which shows its folder button.
    @State private var hovered: MeetingID?
    @StateObject private var nextMeeting = NextMeetingModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            // Same as the main sidebar: Divider() stops below the transparent
            // titlebar, a rectangle reaches the top edge.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .top)
            Group {
                if let meeting = selected {
                    GeometryReader { geometry in detail(meeting, width: geometry.size.width) }
                } else {
                    ContentUnavailableView {
                        Label("No Meeting Selected", systemImage: "person.2")
                    } description: {
                        Text("Pick a meeting on the left, or record one. A call you join is offered on the pill.")
                    } actions: {
                        if !engine.isRecording {
                            Button("Record") { engine.toggleRecording() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let exported { ExportToast(result: exported) { self.exported = nil }.padding(.bottom, VoiceIQUI.Spacing.l) }
        }
        .animation(.easeOut(duration: 0.2), value: exported)
        .onAppear { reload() }
        // A dialog about one meeting never acts on another (a recording that starts selects itself).
        .onChange(of: selection) { _, _ in assigning = false; confirmingDelete = false; renaming = false; loadSelection() }
        .onChange(of: engine.phase) { _, phase in
            // A new recording opens, so its live card and Discard are in view.
            if case let .recording(id, _) = phase { selection = id } else { confirmingDiscard = false }
            reload()
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { engine.discardRecording() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("Its audio is deleted and no notes are made.")
        }
        .onChange(of: engine.processing) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .gtMeetingsDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == "sync" { reload() }
        }
        .onChange(of: folders.filter) { _, _ in showFirstIfHidden() }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: remove)
        }
        .alert("Rename Meeting", isPresented: $renaming) {
            TextField("Title", text: $titleDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename", action: renameMeeting)
        } message: {
            Text("Leave it empty to use the title from the notes.")
        }
        .task(id: selected.map { "\($0.id.uuid.uuidString) \($0.status)" }) { await checkSystemAudio() }
        .meetingFolderEditing(folders, noun: "meetings")
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("Meetings")
                .font(VoiceIQUI.TypeScale.display())
                .foregroundStyle(VQ.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VQ.Spacing.page)
                .padding(.top, VoiceIQUI.Spacing.l)
            if let next = nextMeeting.next {
                NextMeetingCard(meeting: next, now: nextMeeting.now, engine: engine)
                    .padding(.horizontal, VoiceIQUI.Spacing.s)
                    .padding(.top, VoiceIQUI.Spacing.l)
            }
            Button {
                // As Option-M: a call already detected becomes the meeting's source.
                engine.toggleRecording()
            } label: {
                Label(recording ? "Stop recording" : "Record", systemImage: recording ? "stop.fill" : "record.circle")
                    // White on the pale dark-mode accent read at 2.8:1; Stop
                    // sits on the darker error fill so white stays readable.
                    .foregroundStyle(recording ? Color.white : VQ.Colors.onAccent)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(recording ? VoiceIQUI.Colors.errorFill : VQ.Colors.accent)
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, VoiceIQUI.Spacing.s)
            .padding(.top, nextMeeting.next == nil ? VoiceIQUI.Spacing.l : VoiceIQUI.Spacing.s)
            .padding(.bottom, VoiceIQUI.Spacing.xs)
            if recording {
                HStack(spacing: VoiceIQUI.Spacing.xs) {
                    Button {
                        engine.setMicMuted(!engine.micMuted)
                    } label: {
                        Label(engine.micMuted ? "Unmute my mic" : "Mute my mic",
                              systemImage: engine.micMuted ? "mic.slash.fill" : "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    // `error`, not gRed: red text on its own tint read at 4.1:1 (Fable, M6).
                    .tint(engine.micMuted ? VoiceIQUI.Colors.error : nil)
                    .help(engine.micMuted ? "Record your voice again" : "Stop recording your voice; the other side keeps recording")
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .padding(.horizontal, VoiceIQUI.Spacing.s)
                .padding(.bottom, VoiceIQUI.Spacing.xs)
            }
            folderFilter
            List(selection: $selection) {
                // Day headings are rows, not Sections: macOS pins the top
                // Section's header and draws a rule under it, so only "Today"
                // had one (Fable, M6), whatever `listSectionSeparator` said.
                ForEach(Self.days(listed), id: \.start) { day in
                    Text(day.label)
                        .font(GTFont.flex(11, weight: 600))
                        .foregroundStyle(.secondary)
                        .padding(.top, VoiceIQUI.Spacing.xs)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.meetings) { meeting in
                        // The heading already sets the day off; no rule above its first row.
                        row(meeting).listRowSeparator(meeting.id == day.meetings.first?.id ? .hidden : .automatic, edges: .top)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if meetings.isEmpty {
                    Text("No meetings yet").foregroundStyle(.secondary)
                } else if listed.isEmpty {
                    Text("No meetings in this folder").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ meeting: MeetingMeta) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title(meeting)).font(VoiceIQUI.TypeScale.body()).lineLimit(1)
            if case let .recording(id, since) = engine.phase, id == meeting.id {
                // The length ticks while it records; the stored one is written at Stop.
                TimelineView(.periodic(from: since, by: 1)) { context in
                    // Only the dot is red; red text on the selected row read at 3:1 (Fable).
                    (Text(Image(systemName: "circle.fill")).foregroundColor(VQ.Colors.record)
                        + Text(" \(meeting.startedAt.formatted(date: .omitted, time: .shortened)) · \(MeetingRecordingStatus.clock(context.date.timeIntervalSince(since))) · Recording"))
                        .font(VoiceIQUI.TypeScale.labelSmall().monospacedDigit())
                        // Secondary on the selection read at 4.2:1 (Fable, M6).
                        .foregroundStyle(selection == meeting.id ? HierarchicalShapeStyle.primary : .secondary)
                        .lineLimit(1)
                }
            } else {
                Text(timeLine(meeting)).font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(selection == meeting.id ? HierarchicalShapeStyle.primary : .secondary)
                    .lineLimit(1)
            }
            let names = folders.names(of: meeting.id)
            if !names.isEmpty {
                // Text, not a Label: a list row gives a Label's icon a column of its own.
                Text("\(Image(systemName: "folder")) \(names.joined(separator: ", "))")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(selection == meeting.id ? HierarchicalShapeStyle.primary : .secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if hovered == meeting.id {
                Menu {
                    MeetingFolderToggles(model: folders, meeting: meeting.id)
                } label: {
                    Image(systemName: "folder.badge.plus").accessibilityLabel("Folders")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(6)
                // Over the row's text, which runs to its edge.
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium))
                .help("Put this meeting in folders")
            }
        }
        .onHover { inside in
            if inside { hovered = meeting.id } else if hovered == meeting.id { hovered = nil }
        }
        .tag(meeting.id)
        .contextMenu { Menu("Folders") { MeetingFolderToggles(model: folders, meeting: meeting.id) } }
    }

    /// Which meetings the list shows: all, or one folder's.
    private var folderFilter: some View {
        Menu {
            MeetingFolderFilterItems(model: folders, allTitle: "All meetings")
        } label: {
            Label(folders.filterFolder?.name ?? "All meetings", systemImage: folders.filter == nil ? "tray.full" : "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Show one folder's meetings, or make, rename and delete folders")
        .padding(.horizontal, VoiceIQUI.Spacing.s)
        .padding(.vertical, VoiceIQUI.Spacing.xs)
    }

    /// Below this the notes and the transcript take turns.
    static let wideWidth: CGFloat = 680

    private func detail(_ meeting: MeetingMeta, width paneWidth: CGFloat) -> some View {
        let wide = paneWidth >= Self.wideWidth
        let transcriptShown = !transcript.isEmpty && (wide ? !hidesTranscript : narrowShowsTranscript)
        let filedIn = folders.names(of: meeting.id)
        return VStack(spacing: 0) {
            // With the transcript alone the title takes the folder menu's place; the notes view has it.
            header(meeting, wide: wide, transcriptShown: transcriptShown, filedIn: filedIn)
            Divider()
            if case .failed(let reason) = meeting.status {
                // Waiting for AssemblyAI is not an error: it goes again by itself.
                let waiting = meeting.waitsForService != nil
                let tint = waiting ? Color.secondary : VoiceIQUI.Colors.error
                Label(reason, systemImage: waiting ? "clock" : "exclamationmark.triangle.fill")
                    .font(VoiceIQUI.TypeScale.body())
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(VoiceIQUI.Spacing.m)
                    .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(tint.opacity(0.1)))
                    .padding([.horizontal, .top], VoiceIQUI.Spacing.l)
            }
            if let unheardCall, unheardCall.id == meeting.id { unheardWarning(unheardCall.why) }
            if meeting.speakersUnsplit == true, meeting.status == .done, !engine.isBusy(meeting.id) { unsplitWarning(meeting) }
            HStack(spacing: 0) {
                if wide || !transcriptShown {
                    MeetingNotesColumn(meeting: meeting, notes: notes, transcript: transcript, step: step(meeting), chat: chat(meeting),
                                       live: recordingSince(meeting).map { since in
                                           MeetingRecordingStatus(engine: engine, since: since) { confirmingDiscard = true }
                                       })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(meeting.id)
                }
                if transcriptShown {
                    if wide { Divider() }
                    let width = wide ? MeetingTranscriptColumn.width : paneWidth
                    Group {
                        if assigning {
                            AssignSpeakersView(meeting: meeting, notes: notes, transcript: transcript,
                                               folder: store.folder(for: meeting.id),
                                               rename: { speaker, name in rename(meeting, speaker, name) },
                                               back: { assigning = false })
                        } else {
                            let editable = !engine.isBusy(meeting.id)
                            MeetingTranscriptColumn(meeting: meeting, notes: notes, transcript: transcript,
                                                    edit: editable ? { segment, text in
                                                        try? store.editTranscriptSegment(segment, text: text, meeting: meeting.id)
                                                        loadSelection()
                                                    } : nil,
                                                    delete: editable ? { segment in
                                                        try? store.deleteTranscriptSegment(segment, meeting: meeting.id)
                                                        loadSelection()
                                                    } : nil) { assigning = true }
                        }
                    }
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(wide ? VoiceIQUI.Colors.surfaceContainer.opacity(0.35) : .clear)
                }
            }
            if let chat = chat(meeting) {
                // Under both columns, so a question can be asked while the
                // transcript is open; narrow, the answer shows in the notes.
                MeetingChatInput(chat: chat) { if !wide { narrowShowsTranscript = false } }
                    .id(meeting.id)
            }
        }
    }

    /// Nil until the meeting has a transcript to ask about.
    private func chat(_ meeting: MeetingMeta) -> MeetingChatModel? {
        transcript.isEmpty ? nil : MeetingChatModel.shared(meeting.id, store: store)
    }

    /// The meeting's folders, and the menu that changes them.
    private func folderMenu(_ meeting: MeetingMeta, filedIn: [String]) -> some View {
        Menu {
            MeetingFolderToggles(model: folders, meeting: meeting.id)
        } label: {
            Label(filedIn.isEmpty ? "Add to folder" : filedIn.joined(separator: ", "), systemImage: "folder")
                .font(VoiceIQUI.TypeScale.labelSmall())
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        // Shares the header row with the toolbar: long folder names truncate, the buttons stay.
        .layoutPriority(-1)
        .help("Put this meeting in folders")
    }

    private func header(_ meeting: MeetingMeta, wide: Bool, transcriptShown: Bool, filedIn: [String]) -> some View {
        let busy = engine.isBusy(meeting.id)
        let audio = RecordedAudio.meeting(folder: meeting.status == .recording ? nil : store.folder(for: meeting.id),
                                          name: title(meeting))
        return HStack(spacing: VoiceIQUI.Spacing.xs) {
            // The notes open with the title; only the transcript alone needs it here.
            if !wide && transcriptShown {
                Text(title(meeting)).font(VoiceIQUI.TypeScale.title()).lineLimit(1)
            } else {
                folderMenu(meeting, filedIn: filedIn)
            }
            Spacer(minLength: VoiceIQUI.Spacing.s)
            if notes != nil, let step = step(meeting) {
                ProgressView().controlSize(.small)
                Text(step).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .padding(.trailing, VoiceIQUI.Spacing.xs)
            }
            if notes != nil, meeting.status == .done, meeting.namesChangedSinceNotes {
                Button {
                    engine.regenerateNotes(id: meeting.id)
                } label: {
                    Label("Update notes", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(busy)
                .help("Write the notes again with the speaker names you set")
            }
            RecordingAudioButtons(audio: audio) { exported = $0 }
                .buttonStyle(CircleButtonStyle())
            // Icon-only when narrow, so the folder menu keeps its words.
            if wide {
                exportMenu(meeting)
                    .fixedSize()
                    .disabled(notes == nil && transcript.isEmpty)
            } else {
                exportMenu(meeting)
                    .menuStyle(.button)
                    .buttonStyle(CircleButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Export")
                    .disabled(notes == nil && transcript.isEmpty)
            }
            Menu {
                Button("Rename…") { titleDraft = title(meeting); renaming = true }
                Divider()
                if case .failed = meeting.status {
                    Button("Retry") { engine.retry(id: meeting.id) }
                } else {
                    Button("Redo notes") { engine.regenerateNotes(id: meeting.id) }.disabled(transcript.isEmpty)
                    Button("Redo transcript and notes") { engine.retry(id: meeting.id, fresh: true) }
                        .disabled(!audio.isAvailable)
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            } label: {
                // MEASURED 2026-10-29. macOS 26 sizes a menu bezel from its
                // label's text: as text the symbol gets Export's height, and
                // an image or a frame gets a shorter bezel. macOS 27 drew
                // Text(Image(...)) here as an empty bezel, and gives a framed
                // icon-only Label Export's height.
                if #available(macOS 27, *) {
                    Label("More", systemImage: "ellipsis").labelStyle(.iconOnly).frame(minHeight: 16)
                } else {
                    Text(Image(systemName: "ellipsis")).accessibilityLabel("More")
                }
            }
            .menuStyle(.button)
            .buttonStyle(CircleButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy)
            Button {
                if wide { hidesTranscript.toggle() } else { narrowShowsTranscript.toggle() }
            } label: {
                Image(systemName: wide ? "sidebar.right" : transcriptShown ? "doc.text" : "text.bubble")
            }
            .buttonStyle(CircleButtonStyle())
            .help(transcriptShown ? (wide ? "Hide transcript" : "Show notes") : "Show transcript")
            .disabled(transcript.isEmpty)
        }
        .padding(.horizontal, VoiceIQUI.Spacing.l)
        .padding(.top, VoiceIQUI.Spacing.l)
        .padding(.bottom, VoiceIQUI.Spacing.s)
    }

    private func exportMenu(_ meeting: MeetingMeta) -> some View {
        Menu {
            Section("Save to Downloads") { exportItems { export(meeting, $0) } }
            Section("Copy") { exportItems { copy(meeting, $0) } }
            if SettingsStore().agentAccessEnabled {
                Divider()
                Button("Copy prompt for an AI agent") { copyAgentPrompt(meeting) }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    /// What the meeting is doing in the background, in words; nil when idle.
    private func step(_ meeting: MeetingMeta) -> String? {
        if case .recording(meeting.id, _) = engine.phase { return "Recording" }
        switch engine.processing[meeting.id] {
        case .summarizing?: return "Making notes"
        case nil: return nil
        default: return "Transcribing"
        }
    }

    /// When this meeting started recording, while it records.
    private func recordingSince(_ meeting: MeetingMeta) -> Date? {
        if case let .recording(id, since) = engine.phase, id == meeting.id { return since }
        return nil
    }

    private var selected: MeetingMeta? { meetings.first { $0.id == selection } }
    private var recording: Bool { if case .recording = engine.phase { return true }; return false }
    private func reload() {
        meetings = store.list()
        folders.reload(meetings)
        // A meeting deleted on another device leaves the list.
        showFirstIfHidden()
        loadSelection()
    }
    /// The folder filter's meetings, plus the one recording or being processed
    /// and the one open, whatever their folders, in the list's order.
    private var listed: [MeetingMeta] {
        var keep = Set(folders.shown(meetings).map(\.id)).union(engine.processing.keys)
        if case let .recording(id, _) = engine.phase { keep.insert(id) }
        if let selection, engine.isBusy(selection) { keep.insert(selection) }
        return meetings.filter { keep.contains($0.id) }
    }
    private func showFirstIfHidden() {
        let shown = listed
        if !shown.contains(where: { $0.id == selection }) { selection = shown.first?.id }
    }
    private func loadSelection() {
        guard let id = selection else { notes = nil; transcript = []; return }
        notes = try? store.loadNotes(id: id); transcript = (try? store.loadTranscript(id: id)) ?? []
    }
    private func remove() {
        guard let id = selection, !engine.isBusy(id) else { return }
        try? store.delete(id: id); selection = nil; reload()
    }
    private func renameMeeting() {
        guard let meeting = selected,
              titleDraft.trimmingCharacters(in: .whitespacesAndNewlines) != title(meeting) else { return }
        try? store.renameMeeting(id: meeting.id, title: titleDraft)
        meetings = store.list()
    }
    private func rename(_ meeting: MeetingMeta, _ speaker: String, _ name: String) {
        try? store.renameSpeaker(id: meeting.id, label: speaker, name: name)
        meetings = store.list()
    }

    @ViewBuilder
    private func exportItems(_ action: @escaping (MeetingStore.ExportParts) -> Void) -> some View {
        Button("Notes") { action(.notes) }.disabled(notes == nil)
        Button("Transcript") { action(.transcript) }.disabled(transcript.isEmpty)
        Button("Notes and transcript") { action(.both) }.disabled(notes == nil || transcript.isEmpty)
    }

    /// A prompt that sends a coding agent to this meeting through agent access.
    private func copyAgentPrompt(_ meeting: MeetingMeta) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(AgentAPI.meetingPrompt(id: meeting.id, title: title(meeting)), forType: .string) else {
            exported = .failed("the clipboard didn't accept the text")
            return
        }
        exported = .copied("prompt for an AI agent", UUID())
    }

    /// The speaker model failed, so two people on the call may share a voice.
    private func unsplitWarning(_ meeting: MeetingMeta) -> some View {
        let audio = RecordedAudio.meeting(folder: store.folder(for: meeting.id), name: title(meeting))
        return HStack(spacing: VoiceIQUI.Spacing.s) {
            Label("The speaker model failed on this meeting, so some people on the call may be shown as one speaker.",
                  systemImage: "person.2.slash")
                .font(VoiceIQUI.TypeScale.body())
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Split Speakers Again") { confirmingSplit = true }
                // A meeting synced from the iPhone has no recording here (Codex on #133).
                .disabled(!audio.isAvailable)
                .help("Tells the voices apart again and rewrites the notes. Edits to the transcript are replaced.")
                // Asks first, as the iPhone does: the run replaces transcript edits (Neon on #133).
                .confirmationDialog("Split speakers again?", isPresented: $confirmingSplit) {
                    Button("Split") { assigning = false; engine.retry(id: meeting.id) }
                } message: {
                    Text("The notes are written again, and edits to the transcript are replaced.")
                }
        }
        .padding(VoiceIQUI.Spacing.m)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.surfaceContainer))
        .padding([.horizontal, .top], VoiceIQUI.Spacing.l)
    }

    /// Only an all-zero track points to the permission: a quiet one was
    /// recorded with it (the live-call probe's m2 and m3).
    private func unheardWarning(_ why: SilentSystemAudio.Unheard) -> some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            Label(why == .zeros
                  ? "VoiceiQ couldn't hear the other people on this call. Check System Settings > Privacy & Security > Screen & System Audio Recording."
                  : "VoiceiQ couldn't hear the other people on this call. They may have been muted the whole time, or the call's volume was too low to record.",
                  systemImage: "speaker.slash")
                .font(VoiceIQUI.TypeScale.body())
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if why == .zeros {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
        .padding(VoiceIQUI.Spacing.m)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.surfaceContainer))
        .padding([.horizontal, .top], VoiceIQUI.Spacing.l)
    }

    /// Off the main thread: a silent track is read to its end.
    private func checkSystemAudio() async {
        unheardCall = nil
        guard let meeting = selected, let folder = store.folder(for: meeting.id) else { return }
        let unheard = await Task.detached(priority: .utility) { SilentSystemAudio.check(meeting, folder: folder) }.value
        if !Task.isCancelled, let unheard { unheardCall = (meeting.id, unheard) }
    }

    /// The same Markdown as the saved file, on the clipboard.
    private func copy(_ meeting: MeetingMeta, _ parts: MeetingStore.ExportParts) {
        do {
            let markdown = try store.markdown(id: meeting.id, parts: parts)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(markdown, forType: .string) else {
                exported = .failed("the clipboard didn't accept the text")
                return
            }
            exported = .copied(parts == .notes ? "notes" : parts == .transcript ? "transcript" : "notes and transcript", UUID())
        } catch {
            exported = .failed(error.localizedDescription)
        }
    }

    /// One Markdown file in Downloads, named after the meeting.
    private func export(_ meeting: MeetingMeta, _ parts: MeetingStore.ExportParts) {
        do {
            let markdown = try store.markdown(id: meeting.id, parts: parts)
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let suffix = parts == .notes ? " notes" : parts == .transcript ? " transcript" : ""
            let base = title(meeting).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + suffix
            var url = downloads.appendingPathComponent(base + ".md"), copy = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = downloads.appendingPathComponent("\(base) \(copy).md"); copy += 1
            }
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            exported = .saved(url)
        } catch {
            exported = .failed(error.localizedDescription)
        }
    }

    private func title(_ meeting: MeetingMeta) -> String {
        // As the notes pane names it; the time is on the row's second line.
        meeting.displayTitle() ?? "Meeting"
    }
    /// The list's sections: one per day the meetings started on, in the list's newest-first order.
    private static func days(_ meetings: [MeetingMeta]) -> [(start: Date, label: String, meetings: [MeetingMeta])] {
        let calendar = Calendar.current
        var days: [(start: Date, label: String, meetings: [MeetingMeta])] = []
        for meeting in meetings {
            let start = calendar.startOfDay(for: meeting.startedAt)
            if days.last?.start == start { days[days.count - 1].meetings.append(meeting); continue }
            let label = calendar.isDateInToday(start) ? "Today"
                : calendar.isDateInYesterday(start) ? "Yesterday"
                : calendar.isDate(start, equalTo: .now, toGranularity: .year)
                    ? start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
                    : start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
            days.append((start, label, [meeting]))
        }
        return days
    }
    /// "11:50 PM · 17 min · Zoom": the day is the section's. An import has no
    /// length (Granola's export has none); anything in flight or failed says so.
    private func timeLine(_ meeting: MeetingMeta) -> String {
        let time = meeting.startedAt.formatted(date: .omitted, time: .shortened)
        if let app = meeting.importedFrom { return "\(time) · \(app)" }
        let line = "\(time) · \(durationLine(meeting))"
        return meeting.source.map { "\(line) · \(MeetingEngine.name($0))" } ?? line
    }
    /// A finished meeting shows only its length; anything still in flight or failed says so.
    private func durationLine(_ meeting: MeetingMeta) -> String {
        let length = meeting.lengthText
        switch meeting.status {
        case .done: return length
        case .recording: return "\(length) · Recording"
        case .transcribing: return "\(length) · Transcribing"
        case .summarizing: return "\(length) · Making notes"
        case .failed: return "\(length) · " + (meeting.waitsForService != nil ? "Waiting for AssemblyAI" : "Failed")
        }
    }
}

enum ExportResult: Equatable {
    case saved(URL)
    /// The UUID makes a repeat copy a new value, so the toast's dismiss timer restarts.
    case copied(String, UUID)
    case failed(String)
}

struct ExportToast: View {
    let result: ExportResult
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: VoiceIQUI.Spacing.xs) {
            switch result {
            case .saved(let url):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(VoiceIQUI.Colors.success)
                Text("Saved to \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .lineLimit(1).truncationMode(.middle)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]); dismiss() }
                    .buttonStyle(.link)
            case .copied(let what, _):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(VoiceIQUI.Colors.success)
                Text("Copied \(what)")
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VoiceIQUI.Colors.error)
                Text("Couldn't export: \(reason)").lineLimit(2)
            }
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .font(VoiceIQUI.TypeScale.body())
        .padding(.horizontal, VoiceIQUI.Spacing.m)
        .padding(.vertical, VoiceIQUI.Spacing.xs)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .frame(maxWidth: 560)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: result) {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { dismiss() }
        }
    }
}
