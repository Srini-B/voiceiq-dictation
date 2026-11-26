import AppKit
import VoiceIQCore
import SwiftUI

/// The transcript beside the notes: each speaker's name in their own colour,
/// the time on the right, with search, a way into Assign speakers, and
/// Edit and Delete on each line's right-click menu.
struct MeetingTranscriptColumn: View {
    static let width: CGFloat = 340
    static let inset = NSSize(width: 14, height: 4)
    /// Marks each line's text with its segment's id, for the right-click menu.
    private static let segmentKey = NSAttributedString.Key("VoiceIQTranscriptSegment")

    let meeting: MeetingMeta
    let notes: MeetingNotes?
    let transcript: [TranscriptSegment]
    let width: CGFloat
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
                    Text(MeetingNotesPrompt.clock(start)).font(VoiceIQUI.TypeScale.numeric()).foregroundStyle(.tertiary)
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

    private var shown: [TranscriptSegment] {
        guard !trimmedQuery.isEmpty else { return transcript }
        return transcript.filter {
            $0.text.localizedCaseInsensitiveContains(trimmedQuery)
                || meeting.displayName($0.speaker, notes: notes).localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private func openSearch() { searching = true; searchFocused = true }
    private func closeSearch() { searching = false; query = "" }

    private var text: NSAttributedString {
        let order = MeetingSpeaker.others(in: transcript)
        let nameFont = GTFont.nsFlex(12, weight: 600), body = GTFont.nsFlex(14, weight: 400)
        let time = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        // The time sits on a right tab at the column's text edge.
        let edge = width - 2 * Self.inset.width - 12
        let head = NSMutableParagraphStyle()
        head.tabStops = [NSTextTab(textAlignment: .right, location: edge)]
        head.paragraphSpacing = 3
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 14
        let out = NSMutableAttributedString()
        for segment in shown {
            let line = NSMutableAttributedString(string: meeting.displayName(segment.speaker, notes: notes), attributes: [
                .font: nameFont, .foregroundColor: SpeakerPalette.color(segment.speaker, order: order), .paragraphStyle: head,
                Self.segmentKey: segment.id,
            ])
            if let start = segment.start {
                line.append(NSAttributedString(string: "\t" + MeetingNotesPrompt.clock(start), attributes: [
                    .font: time, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: head, Self.segmentKey: segment.id,
                ]))
            }
            line.append(NSAttributedString(string: "\n", attributes: [.font: nameFont, .paragraphStyle: head, Self.segmentKey: segment.id]))
            let words = NSMutableAttributedString(string: segment.text + "\n", attributes: [
                .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph, Self.segmentKey: segment.id,
            ])
            highlight(words)
            out.append(line); out.append(words)
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
