import AppKit
import VoiceIQCore
import SwiftUI

/// The transcript beside the notes: one heading per turn with the speaker's
/// name in their own colour and the turn's start time, with search, a way into Assign speakers, and
/// Edit and Delete on each line's right-click menu.
struct MeetingTranscriptColumn: View {
    static let width: CGFloat = 340
    static let inset = NSSize(width: 14, height: 4)
    /// Marks each line's text with its segment's id, for the right-click menu.
    private static let segmentKey = NSAttributedString.Key("VoiceIQTranscriptSegment")

    let meeting: MeetingMeta
    let notes: MeetingNotes?
    let transcript: [TranscriptSegment]
    /// Nil while the meeting is recording or being redone, which would overwrite the change.
    let edit: ((TranscriptSegment.ID, String) -> Void)?
    let delete: ((TranscriptSegment.ID) -> Void)?
    let assign: () -> Void
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var editing: TranscriptSegment?
    @State private var draft = ""
    @FocusState private var editorFocused: Bool
    @State private var deleting: TranscriptSegment?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: VoiceIQUI.Spacing.xs) {
                if searching {
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .onExitCommand(perform: closeSearch)
                } else {
                    Spacer()
                }
                Button { searching ? closeSearch() : openSearch() } label: {
                    Image(systemName: searching ? "xmark.circle.fill" : "magnifyingglass")
                }
                .help(searching ? "Close search" : "Search transcript")
                Button(action: assign) { Image(systemName: "person.2") }
                    .help("Assign speakers")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(height: 28)
            .padding(.horizontal, VoiceIQUI.Spacing.s)
            .padding(.top, VoiceIQUI.Spacing.s)
            if let editing, edit != nil { editor(editing) }
            if shown.isEmpty {
                Text("No matches").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // One text view for the whole transcript. A SwiftUI Text per segment with
                // selection enabled froze the window on scroll at twenty minutes of speech.
                RichTextView(text: text, inset: Self.inset, menuItems: menuItems)
            }
        }
        .onChange(of: meeting.id) { _, _ in editing = nil }
        .confirmationDialog("Delete this line?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { segment in
            Button("Delete", role: .destructive) { delete?(segment.id) }
        }
    }

    private func menuItems(_ attributes: [NSAttributedString.Key: Any]) -> [RichTextView.MenuItem] {
        guard edit != nil, delete != nil, let id = attributes[Self.segmentKey] as? String,
              let segment = transcript.first(where: { $0.id == id }) else { return [] }
        return [
            .init(title: "Edit") { draft = segment.text; editing = segment },
            .init(title: "Delete…") { deleting = segment },
        ]
    }

    /// The line being edited, above the transcript, with its speaker and time as they are.
    private func editor(_ segment: TranscriptSegment) -> some View {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let save = {
            if !words.isEmpty, words != segment.text { edit?(segment.id, words) }
            editing = nil
        }
        return VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
            HStack {
                Text(meeting.displayName(segment.speaker, notes: notes))
                    .font(VoiceIQUI.TypeScale.label())
                    .foregroundStyle(Color(nsColor: SpeakerPalette.color(segment.speaker, order: MeetingSpeaker.others(in: transcript))))
                Spacer()
                if let start = segment.start {
                    Text(MeetingNotesPrompt.clock(start)).font(VoiceIQUI.TypeScale.numeric()).foregroundStyle(.secondary)
                }
            }
            TextField("Text", text: $draft, axis: .vertical)
                .font(VoiceIQUI.TypeScale.body())
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...10)
                .focused($editorFocused)
                .onAppear { editorFocused = true }
                .onSubmit(save)
                .onExitCommand { editing = nil }
            HStack(spacing: VoiceIQUI.Spacing.xs) {
                Spacer()
                Button("Cancel") { editing = nil }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(words.isEmpty)
            }
        }
        .padding(VoiceIQUI.Spacing.s)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.surface))
        .padding(.horizontal, VoiceIQUI.Spacing.s)
        .padding(.vertical, VoiceIQUI.Spacing.xs)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private func matches(_ segment: TranscriptSegment) -> Bool {
        trimmedQuery.isEmpty
            || segment.text.localizedCaseInsensitiveContains(trimmedQuery)
            || meeting.displayName(segment.speaker, notes: notes).localizedCaseInsensitiveContains(trimmedQuery)
    }

    private var shown: [TranscriptSegment] { transcript.filter(matches) }

    private func openSearch() { searching = true; searchFocused = true }
    private func closeSearch() { searching = false; query = "" }

    private var text: NSAttributedString {
        let order = MeetingSpeaker.others(in: transcript)
        let nameFont = GTFont.nsFlex(12, weight: 600), body = GTFont.nsFlex(14, weight: 400)
        let time = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let head = NSMutableParagraphStyle()
        head.paragraphSpacing = 3
        // Lines of one turn sit close; a new speaker starts after a gap.
        let line = NSMutableParagraphStyle()
        line.lineSpacing = 2
        line.paragraphSpacing = 6
        let last = line.mutableCopy() as! NSMutableParagraphStyle
        last.paragraphSpacing = 16
        // An aside is set in a little, so the run's own lines read on around it.
        let aside = line.mutableCopy() as! NSMutableParagraphStyle
        aside.firstLineHeadIndent = 12; aside.headIndent = 12
        let asideLast = last.mutableCopy() as! NSMutableParagraphStyle
        asideLast.firstLineHeadIndent = 12; asideLast.headIndent = 12
        let out = NSMutableAttributedString()
        // Grouped before the search filters, so turns apart stay apart.
        let turns = MeetingSpeaker.turns(in: transcript)
            .map { turn in var turn = turn; turn.lines = turn.lines.filter { matches($0.segment) }; return turn }
            .filter { !$0.lines.isEmpty }
        for turn in turns {
            let first = turn.lines[0].segment
            // The heading belongs to the turn's first line, for the right-click menu.
            out.append(NSAttributedString(string: meeting.displayName(first.speaker, notes: notes), attributes: [
                .font: nameFont, .foregroundColor: SpeakerPalette.color(first.speaker, order: order), .paragraphStyle: head,
                Self.segmentKey: first.id,
            ]))
            if let start = first.start {
                out.append(NSAttributedString(string: "  " + MeetingNotesPrompt.clock(start), attributes: [
                    .font: time, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: head, Self.segmentKey: first.id,
                ]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: nameFont, .paragraphStyle: head, Self.segmentKey: first.id]))
            for entry in turn.lines {
                let segment = entry.segment
                let isLast = entry.id == turn.lines.last?.id
                let style = entry.aside ? (isLast ? asideLast : aside) : (isLast ? last : line)
                let words = NSMutableAttributedString()
                // Someone else's short reply stays in the run, under their name in their colour.
                if entry.aside {
                    words.append(NSAttributedString(string: meeting.displayName(segment.speaker, notes: notes) + "  ", attributes: [
                        .font: nameFont, .foregroundColor: SpeakerPalette.color(segment.speaker, order: order),
                        .paragraphStyle: style, Self.segmentKey: segment.id,
                    ]))
                }
                words.append(NSAttributedString(string: segment.text + "\n", attributes: [
                    .font: body, .foregroundColor: entry.aside ? NSColor.secondaryLabelColor : NSColor.labelColor,
                    .paragraphStyle: style, Self.segmentKey: segment.id,
                ]))
                highlight(words)
                out.append(words)
            }
        }
        return out
    }

    private func highlight(_ text: NSMutableAttributedString) {
        guard !trimmedQuery.isEmpty else { return }
        let string = text.string as NSString
        var range = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive], range: range)
            guard found.location != NSNotFound else { break }
            text.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.5), range: found)
            range = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
        }
    }
}

/// A colour per speaker; see `MeetingSpeaker.colorHex`.
enum SpeakerPalette {
    static func color(_ speaker: String, order: [String]) -> NSColor {
        let pair = MeetingSpeaker.colorHex(speaker, others: order)
        return NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.dark : pair.light)
        }
    }
}
