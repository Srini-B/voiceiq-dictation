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
    @State private var exported: ExportResult?

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
                    ContentUnavailableView("No Meeting Selected", systemImage: "person.2")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let exported { ExportToast(result: exported) { self.exported = nil }.padding(.bottom, VoiceIQUI.Spacing.l) }
        }
        .animation(.easeOut(duration: 0.2), value: exported)
        .onAppear(perform: reload)
        .onChange(of: selection) { _, _ in assigning = false; loadSelection() }
        .onChange(of: engine.phase) { _, _ in reload() }
        .onChange(of: engine.processing) { _, _ in reload() }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: remove)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Button {
                recording ? engine.stopRecording() : engine.startRecording()
            } label: {
                Label(recording ? "Stop recording" : "Record", systemImage: recording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(recording ? VoiceIQUI.Colors.gRed : nil)
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, VoiceIQUI.Spacing.s)
            .padding(.top, VoiceIQUI.Spacing.l)
            .padding(.bottom, VoiceIQUI.Spacing.xs)
            List(meetings, selection: $selection) { meeting in
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(meeting)).font(VoiceIQUI.TypeScale.body()).lineLimit(1)
                    Text(timeRange(meeting)).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
                    Text(durationLine(meeting)).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
                }.tag(meeting.id)
            }
            .overlay { if meetings.isEmpty { Text("No meetings yet").foregroundStyle(.secondary) } }
        }
    }

    /// Below this the notes and the transcript take turns.
    static let wideWidth: CGFloat = 680

    private func detail(_ meeting: MeetingMeta, width paneWidth: CGFloat) -> some View {
        let wide = paneWidth >= Self.wideWidth
        let transcriptShown = !transcript.isEmpty && (wide ? !hidesTranscript : narrowShowsTranscript)
        return VStack(spacing: 0) {
            header(meeting, wide: wide, transcriptShown: transcriptShown)
            Divider()
            if case .failed(let reason) = meeting.status {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(VoiceIQUI.TypeScale.body())
                    .foregroundStyle(VoiceIQUI.Colors.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(VoiceIQUI.Spacing.m)
                    .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.error.opacity(0.1)))
                    .padding([.horizontal, .top], VoiceIQUI.Spacing.l)
            }
            HStack(spacing: 0) {
                if wide || !transcriptShown {
                    MeetingNotesColumn(meeting: meeting, notes: notes, busy: engine.isBusy(meeting.id))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            MeetingTranscriptColumn(meeting: meeting, notes: notes, transcript: transcript,
                                                    width: width) { assigning = true }
                        }
                    }
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(wide ? VoiceIQUI.Colors.surfaceContainer.opacity(0.35) : .clear)
                }
            }
        }
    }

    private func header(_ meeting: MeetingMeta, wide: Bool, transcriptShown: Bool) -> some View {
        let busy = engine.isBusy(meeting.id)
        return HStack(spacing: VoiceIQUI.Spacing.xs) {
            Text(title(meeting)).font(VoiceIQUI.TypeScale.title()).lineLimit(1)
            Spacer(minLength: VoiceIQUI.Spacing.s)
            Menu {
                Button("Notes") { export(meeting, .notes) }.disabled(notes == nil)
                Button("Transcript") { export(meeting, .transcript) }.disabled(transcript.isEmpty)
                Button("Notes and transcript") { export(meeting, .both) }.disabled(notes == nil || transcript.isEmpty)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(notes == nil && transcript.isEmpty)
            Menu {
                if case .failed = meeting.status {
                    Button("Retry") { engine.retry(id: meeting.id) }
                } else {
                    Button("Redo notes") { engine.regenerateNotes(id: meeting.id) }.disabled(transcript.isEmpty)
                    Button("Redo transcript and notes") { engine.retry(id: meeting.id) }
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy)
            Button {
                if wide { hidesTranscript.toggle() } else { narrowShowsTranscript.toggle() }
            } label: {
                Image(systemName: wide ? "sidebar.right" : transcriptShown ? "doc.text" : "text.bubble")
            }
            .help(transcriptShown ? (wide ? "Hide transcript" : "Show notes") : "Show transcript")
            .disabled(transcript.isEmpty)
        }
        .padding(.horizontal, VoiceIQUI.Spacing.l)
        .padding(.top, VoiceIQUI.Spacing.l)
        .padding(.bottom, VoiceIQUI.Spacing.s)
    }

    private var selected: MeetingMeta? { meetings.first { $0.id == selection } }
    private var recording: Bool { if case .recording = engine.phase { return true }; return false }
    private func reload() { meetings = store.list(); if selection == nil { selection = meetings.first?.id }; loadSelection() }
    private func loadSelection() {
        guard let id = selection else { notes = nil; transcript = []; return }
        notes = try? store.loadNotes(id: id); transcript = (try? store.loadTranscript(id: id)) ?? []
    }
    private func remove() { guard let id = selection else { return }; try? store.delete(id: id); selection = nil; reload() }
    private func rename(_ meeting: MeetingMeta, _ speaker: String, _ name: String) {
        try? store.renameSpeaker(id: meeting.id, label: speaker, name: name)
        meetings = store.list()
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
        if let title = meeting.title, !title.isEmpty { return title }
        return meeting.startedAt.formatted(date: .abbreviated, time: .shortened)
    }
    /// "26 Sep 2026, 2:23 – 2:24 PM", the same shape as a dictation's timestamp
    /// plus the end time; a recording still in progress shows only its start.
    private func timeRange(_ meeting: MeetingMeta) -> String {
        let start = meeting.startedAt.formatted(date: .abbreviated, time: .shortened)
        guard let end = meeting.endedAt else { return start }
        let sameDay = Calendar.current.isDate(meeting.startedAt, inSameDayAs: end)
        return "\(start) – \(end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened))"
    }
    private func duration(_ seconds: Double) -> String { seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m" }
    /// A finished meeting shows only its length; anything still in flight or failed says so.
    private func durationLine(_ meeting: MeetingMeta) -> String {
        let length = duration(meeting.durationSeconds)
        switch meeting.status {
        case .done: return length
        case .recording: return "\(length) · Recording"
        case .transcribing: return "\(length) · Transcribing"
        case .summarizing: return "\(length) · Making notes"
        case .failed: return "\(length) · Failed"
        }
    }
}

enum ExportResult: Equatable {
    case saved(URL)
    case failed(String)
}

private struct ExportToast: View {
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
