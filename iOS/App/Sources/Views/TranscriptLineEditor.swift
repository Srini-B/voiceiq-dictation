import SwiftUI
import VoiceIQCore

/// One transcript line's words, with its speaker and time as they are.
struct TranscriptLineEditor: View {
    let segment: TranscriptSegment
    let speaker: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(segment: TranscriptSegment, speaker: String, save: @escaping (String) -> Void) {
        self.segment = segment; self.speaker = speaker; self.save = save
        _text = State(initialValue: segment.text)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text", text: $text, axis: .vertical)
                        .font(Theme.Fonts.body())
                        .focused($focused)
                } header: {
                    HStack {
                        Text(speaker)
                        Spacer()
                        if let start = segment.start { Text(MeetingNotesPrompt.clock(start)) }
                    }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if trimmed != segment.text { save(trimmed) }
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
