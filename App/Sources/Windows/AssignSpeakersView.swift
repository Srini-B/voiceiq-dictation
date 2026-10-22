import AVFoundation
import VoiceIQCore
import SwiftUI

/// One card per speaker with a line they said, to hear and name them.
struct AssignSpeakersView: View {
    let meeting: MeetingMeta
    let notes: MeetingNotes?
    let transcript: [TranscriptSegment]
    let folder: URL?
    /// Speaker id and the name to give it; an empty name clears the typed one.
    let rename: (String, String) -> Void
    let back: () -> Void
    @StateObject private var player = TurnPlayer()
    @State private var sample: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: VoiceIQUI.Spacing.xs) {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Back to transcript")
                Text("Assign speakers").font(VoiceIQUI.TypeScale.title())
                Spacer()
            }
            .frame(height: 28)
            .padding(.horizontal, VoiceIQUI.Spacing.s)
            .padding(.top, VoiceIQUI.Spacing.s)
            ScrollView {
                VStack(spacing: VoiceIQUI.Spacing.xs) {
                    ForEach(speakers, id: \.self, content: card)
                }
                .padding(VoiceIQUI.Spacing.s)
            }
        }
        .onDisappear(perform: player.stop)
    }

    /// The note owner first, then everyone else in order of first turn.
    private var speakers: [String] {
        let others = SpeakerPalette.order(transcript)
        return transcript.contains { $0.speaker == MeetingSpeaker.you } ? [MeetingSpeaker.you] + others : others
    }

    private func card(_ speaker: String) -> some View {
        let color = Color(nsColor: SpeakerPalette.color(speaker, order: SpeakerPalette.order(transcript)))
        let turns = samples(speaker)
        let turn = turns[(sample[speaker] ?? 0) % turns.count]
        let key = "\(speaker)-\(turn.start ?? 0)"
        return VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xxs) {
            HStack(spacing: VoiceIQUI.Spacing.xs) {
                SpeakerNamePicker(speaker: speaker, name: meeting.displayName(speaker, notes: notes),
                                  typed: !(meeting.speakerNames[speaker] ?? "").isEmpty,
                                  known: meeting.knownNames(notes), color: color) { rename(speaker, $0) }
                Spacer()
                Button { sample[speaker] = (sample[speaker] ?? 0) + 1; player.stop() } label: {
                    Image(systemName: "shuffle")
                }
                .foregroundStyle(.secondary)
                .disabled(turns.count < 2)
                .help("Another line")
                Button {
                    if let audio = audio(speaker), let start = turn.start, let end = turn.end {
                        player.toggle(key, url: audio, from: start, to: end)
                    }
                } label: {
                    Image(systemName: player.playing == key ? "stop.fill" : "play.fill")
                }
                .foregroundStyle(color)
                .disabled(audio(speaker) == nil || turn.start == nil || turn.end == nil)
                .help(player.playing == key ? "Stop" : "Play this line")
            }
            .buttonStyle(.borderless)
            Text(turn.text)
                .font(VoiceIQUI.TypeScale.body())
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(VoiceIQUI.Spacing.s)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(color.opacity(0.12)))
    }

    /// The speaker's longer lines first: a few words are rarely enough to know a voice.
    private func samples(_ speaker: String) -> [TranscriptSegment] {
        let turns = transcript.filter { $0.speaker == speaker }
        let words = { (turn: TranscriptSegment) in turn.text.split(whereSeparator: \.isWhitespace).count }
        let long = turns.filter { words($0) >= 6 }.sorted { words($0) > words($1) }
        return Array((long.isEmpty ? turns : long).prefix(12))
    }

    /// The note owner is on the microphone track, everyone else on the system track.
    private func audio(_ speaker: String) -> URL? {
        guard let folder else { return nil }
        let names = speaker == MeetingSpeaker.you ? ["mic-aec.caf", "mic.caf"] : ["system.caf", "mic.caf"]
        return names.map { folder.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// The speaker's name; clicking it offers the names this meeting knows and a field for another.
private struct SpeakerNamePicker: View {
    let speaker: String, name: String
    /// The user typed this name, so it can be reset to the suggestion.
    let typed: Bool
    let known: [String]
    let color: Color
    let save: (String) -> Void
    @State private var open = false
    @State private var draft = ""

    var body: some View {
        Button { draft = ""; open = true } label: {
            HStack(spacing: 3) {
                Text(name).font(GTFont.flex(12, weight: 600)).foregroundStyle(color)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(known, id: \.self) { candidate in
                    Button { choose(candidate) } label: {
                        HStack {
                            Text(candidate)
                            Spacer()
                            if candidate == name { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, VoiceIQUI.Spacing.xs)
                        .padding(.vertical, VoiceIQUI.Spacing.xxs)
                    }
                    .buttonStyle(.plain)
                }
                if !known.isEmpty { Divider().padding(.vertical, VoiceIQUI.Spacing.xxs) }
                TextField("Other name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !draft.trimmingCharacters(in: .whitespaces).isEmpty { choose(draft) } }
                if typed {
                    Button("Reset") { choose("") }
                        .buttonStyle(.link)
                        .padding(.top, VoiceIQUI.Spacing.xxs)
                }
            }
            .padding(VoiceIQUI.Spacing.s)
            .frame(width: 220)
        }
    }

    private func choose(_ value: String) { save(value); open = false }
}

/// Plays one turn of a recording.
@MainActor private final class TurnPlayer: ObservableObject {
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?
    private var stopper: Task<Void, Never>?

    func toggle(_ key: String, url: URL, from start: Double, to end: Double) {
        let again = playing == key
        stop()
        guard !again, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.currentTime = max(0, start - 0.2)
        player.play()
        self.player = player; playing = key
        stopper = Task { [weak self] in
            try? await Task.sleep(for: .seconds(end - start + 0.4))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopper?.cancel(); stopper = nil
        player?.stop(); player = nil
        playing = nil
    }
}
