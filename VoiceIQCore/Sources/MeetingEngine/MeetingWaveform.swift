import SwiftUI

/// Colours and type for the meeting waveforms. Each app passes its own, so
/// the Mac and iPhone draw the same waveform in their own look.
public struct WaveformStyle: Sendable {
    /// Your side, above the line, and the text.
    public var you: Color
    /// The call's side, below the line, and the quieter text.
    public var call: Color
    /// The playback bar's background.
    public var fill: Color
    /// The live waveform's "now" dot.
    public var accent: Color
    public var label: Font
    public var time: Font

    public init(you: Color, call: Color, fill: Color, accent: Color, label: Font, time: Font) {
        self.you = you; self.call = call; self.fill = fill; self.accent = accent; self.label = label; self.time = time
    }
}

/// How loud each side of a recorded meeting is, one value per 100 ms, 0 to 1.
public struct MeetingLoudness: Sendable, Equatable {
    public var you: [Float]
    /// Nil when the meeting has no call side: iPhone records the room on the mic track alone.
    public var call: [Float]?
    public var duration: TimeInterval

    /// Reads both tracks; seconds for a long meeting, so call it off the main actor.
    public static func read(folder: URL) throws -> MeetingLoudness {
        let mic = try TrackAudio(url: folder.appendingPathComponent("mic.caf"))
        let system = try TrackAudio(url: folder.appendingPathComponent("system.caf"))
        return MeetingLoudness(you: heights(mic), call: system.frames > 0 ? heights(system) : nil,
                               duration: max(mic.duration, system.duration))
    }

    /// Each track levelled the way the transcriber hears it (`TrackAudio.gain`),
    /// so a quiet call side draws as tall as a loud mic.
    private static func heights(_ track: TrackAudio) -> [Float] {
        let boost = 20 * log10(track.gain)
        return track.levels.map { height(dB: $0 + boost, floor: -50, full: -10) }
    }

    /// `floor` and quieter is flat; `full` and louder fills the side.
    static func height(dB: Double, floor: Double, full: Double) -> Float {
        Float(min(max((dB - floor) / (full - floor), 0), 1))
    }
}

/// One bar: your side and the call's, 0 to 1.
struct WaveBar {
    /// Nil while your mic was muted.
    var you: Float?
    /// Nil when there is no call side; your side is then drawn both ways from the line.
    var call: Float?
}

/// Bars around a centre line; the first `played` bars are solid and the rest faded.
private struct WaveBars: View {
    let bars: [WaveBar]
    let style: WaveformStyle
    var played: Int?
    /// Live: the newest bar sits at the right edge and older ones scroll off to the left.
    var trailing = false

    static let width: CGFloat = 3
    static let pitch: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2, half = mid - 1
            context.fill(Path(CGRect(x: 0, y: mid - 0.25, width: size.width, height: 0.5)),
                         with: .color(style.call.opacity(0.35)))
            let first = trailing ? CGFloat(bars.count) * Self.pitch - size.width : 0
            for (index, bar) in bars.enumerated() {
                let x = CGFloat(index) * Self.pitch - first
                guard x > -Self.width, x < size.width else { continue }
                let faded = played.map { index >= $0 } ?? false
                func draw(_ y: CGFloat, _ height: CGFloat, _ color: Color) {
                    let rect = CGRect(x: x, y: y, width: Self.width, height: max(height, Self.width))
                    context.fill(Path(roundedRect: rect, cornerRadius: Self.width / 2),
                                 with: .color(faded ? color.opacity(0.3) : color))
                }
                guard let you = bar.you else {
                    // Muted: a dot on the line where your side would be.
                    draw(mid - Self.width, Self.width, style.call.opacity(0.6))
                    if let call = bar.call { draw(mid + 1, CGFloat(call) * half, style.call) }
                    continue
                }
                let up = CGFloat(you) * half
                if let call = bar.call {
                    draw(mid - 1 - max(up, Self.width), up, style.you)
                    draw(mid + 1, CGFloat(call) * half, style.call)
                } else {
                    draw(mid - max(up, Self.width / 2), up * 2, style.you)
                }
            }
        }
    }
}

/// The recording card's waveform: you above the line, the call below, newest
/// at the right with a dot for now, scrolling left as the meeting goes on.
public struct LiveMeetingWaveform: View {
    @ObservedObject var engine: MeetingEngine
    let style: WaveformStyle
    /// iPhone hears the room on one track, so its waveform has no call side.
    let hearsCall: Bool
    @State private var history: [WaveBar] = []

    public init(engine: MeetingEngine, style: WaveformStyle, hearsCall: Bool) {
        self.engine = engine; self.style = style; self.hearsCall = hearsCall
    }

    public var body: some View {
        HStack(spacing: 10) {
            if hearsCall {
                VStack(alignment: .leading, spacing: 0) {
                    Label(muted ? "Muted" : "You", systemImage: muted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(muted ? style.call : style.you)
                    Spacer(minLength: 0)
                    Label("Call", systemImage: "speaker.wave.2.fill").foregroundStyle(style.call)
                }
                .labelStyle(WaveLegendLabelStyle())
                .font(style.label)
                .fixedSize()
                .padding(.vertical, 4)
            }
            WaveBars(bars: history, style: style, trailing: true)
                .padding(.trailing, 14)
                .overlay(alignment: .trailing) {
                    Circle().fill(style.accent).frame(width: 8, height: 8)
                }
        }
        .frame(height: 56)
        .task {
            while !Task.isCancelled {
                sample()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live sound")
        .accessibilityValue(accessibilityValue)
    }

    /// Only the Mac can mute the mic mid-meeting.
    private var muted: Bool {
        #if os(macOS)
        engine.micMuted
        #else
        false
        #endif
    }

    private func sample() {
        let levels = engine.liveLevels ?? (0, 0)
        // Live RMS is not levelled: speech at a laptop mic sits near −30 dBFS,
        // a quiet call side near −50, so the scale starts lower than playback's.
        func height(_ rms: Float) -> Float {
            MeetingLoudness.height(dB: 20 * log10(Double(max(rms, 0.000_001))), floor: -60, full: -15)
        }
        history.append(WaveBar(you: muted ? nil : height(levels.mic),
                               call: hearsCall ? height(levels.call) : nil))
        if history.count > 400 { history.removeFirst(history.count - 400) }
    }

    private var accessibilityValue: String {
        let recent = history.suffix(10)
        func hearing(_ side: (WaveBar) -> Float?) -> String {
            recent.contains { (side($0) ?? 0) > 0.3 } ? "hearing sound" : "quiet"
        }
        let you = muted ? "Your mic is muted" : "You: \(hearing(\.you))"
        return hearsCall ? "\(you). Call: \(hearing { $0.call })" : hearing(\.you)
    }
}

/// Icon and word, the icon small enough to sit in a caption line.
private struct WaveLegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A recorded meeting's playback bar: play and pause, back 15 seconds, the
/// time, the waveform of both sides to tap or drag to a moment, the length,
/// and the speed.
public struct MeetingPlaybackBar: View {
    let audio: RecordedAudio
    let style: WaveformStyle
    @StateObject private var player = RecordingPlayer()
    @State private var loudness: MeetingLoudness?
    /// Where the pointer is while dragging along the waveform, 0 to 1.
    @State private var scrub: Double?

    static let rates: [Float] = [1, 1.5, 2]

    public init(audio: RecordedAudio, style: WaveformStyle) {
        self.audio = audio; self.style = style
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: player.state == .playing ? 0.1 : 60)) { _ in
            let duration = loudness?.duration ?? 0
            let position = scrub.map { $0 * duration } ?? min(player.position, duration)
            HStack(spacing: 10) {
                playButton
                Button { player.seek(to: player.position - 15) } label: {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(.plain)
                .foregroundStyle(style.you)
                .accessibilityLabel("Back 15 seconds")
                .help("Back 15 seconds")
                Text(Self.clock(position)).font(style.time).foregroundStyle(style.you)
                waveform(progress: duration > 0 ? position / duration : 0, duration: duration)
                Text(Self.clock(duration)).font(style.time).foregroundStyle(style.call)
                speedButton
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(Capsule().fill(style.fill))
        .task(id: audio.source) {
            loudness = nil
            guard case .meeting(let folder) = audio.source else { return }
            let read = try? await Task.detached(priority: .userInitiated) { try MeetingLoudness.read(folder: folder) }.value
            // Another meeting was chosen while this one read: its own task sets the waveform.
            guard !Task.isCancelled else { return }
            loudness = read
        }
        .onChange(of: audio.source) { _, _ in player.stop() }
        .onDisappear { player.stop() }
    }

    private var playButton: some View {
        Button { player.playPause(audio) } label: {
            ZStack {
                if player.state == .preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(style.fill)
                }
            }
            .frame(width: 30, height: 30)
            .background(Circle().fill(style.you))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.state == .playing ? "Pause" : player.state == .preparing ? "Cancel" : "Play")
        .help(player.state == .preparing ? "Getting the audio ready" : player.state == .playing ? "Pause" : "Play")
    }

    private func waveform(progress: Double, duration: TimeInterval) -> some View {
        GeometryReader { geometry in
            let count = max(1, Int(geometry.size.width / 5))
            WaveBars(bars: bars(count), style: style, played: Int((progress * Double(count)).rounded()))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { scrub = min(max($0.location.x / geometry.size.width, 0), 1) }
                    .onEnded { _ in
                        if let scrub { player.seek(to: scrub * duration) }
                        scrub = nil
                    })
        }
        .frame(height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.clock(progress * duration)) of \(Self.clock(duration))")
        .accessibilityAdjustableAction { direction in
            player.seek(to: player.position + (direction == .increment ? 15 : -15))
        }
    }

    private var speedButton: some View {
        Button {
            let next = (Self.rates.firstIndex(of: player.rate) ?? 0) + 1
            player.rate = Self.rates[next % Self.rates.count]
        } label: {
            Text(player.rate.formatted(.number.precision(.fractionLength(0...1))) + "×")
                .font(style.time)
                .foregroundStyle(style.you)
                .frame(minWidth: 36, minHeight: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speed")
        .accessibilityValue("\(player.rate.formatted()) times")
        .help("Playback speed")
    }

    /// Each bar the loudest moment in its stretch of the meeting.
    private func bars(_ count: Int) -> [WaveBar] {
        guard let loudness, !loudness.you.isEmpty || !(loudness.call ?? []).isEmpty else {
            return Array(repeating: WaveBar(you: 0, call: loudness?.call == nil ? nil : 0), count: count)
        }
        let length = max(loudness.you.count, loudness.call?.count ?? 0)
        func peak(_ values: [Float], _ index: Int) -> Float {
            let start = index * length / count, end = max(start + 1, (index + 1) * length / count)
            guard start < values.count else { return 0 }
            return values[start..<min(end, values.count)].max() ?? 0
        }
        return (0..<count).map { index in
            WaveBar(you: peak(loudness.you, index), call: loudness.call.map { peak($0, index) })
        }
    }

    /// "0:07", "12:40", "1:02:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
