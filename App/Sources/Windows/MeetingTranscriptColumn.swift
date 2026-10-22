import AppKit
import VoiceIQCore
import SwiftUI

/// The transcript beside the notes: each speaker's name in their own colour,
/// the time on the right, with search and a way into Assign speakers.
struct MeetingTranscriptColumn: View {
    static let width: CGFloat = 340
    static let inset = NSSize(width: 14, height: 4)

    let meeting: MeetingMeta
    let notes: MeetingNotes?
    let transcript: [TranscriptSegment]
    let width: CGFloat
    let assign: () -> Void
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

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
                Button(action: searching ? closeSearch : openSearch) {
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
            if shown.isEmpty {
                Text("No matches").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // One text view for the whole transcript. A SwiftUI Text per segment with
                // selection enabled froze the window on scroll at twenty minutes of speech.
                RichTextView(text: text, inset: Self.inset)
            }
        }
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
            ])
            if let start = segment.start {
                line.append(NSAttributedString(string: "\t" + MeetingNotesPrompt.clock(start), attributes: [
                    .font: time, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: head,
                ]))
            }
            line.append(NSAttributedString(string: "\n", attributes: [.font: nameFont, .paragraphStyle: head]))
            let words = NSMutableAttributedString(string: segment.text + "\n", attributes: [
                .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
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
