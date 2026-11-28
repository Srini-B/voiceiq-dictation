import SwiftUI

/// The first thing a new user sees: three short slides on what VoiceiQ does,
/// each with a small animated scene, then setup.
struct IntroSlides: View {
    let onFinished: () -> Void
    @State private var page = 0

    private struct Slide {
        let title: String
        let detail: String
    }

    private let slides = [
        Slide(title: "Talk.\nVoiceiQ types.",
              detail: "Dictate in any app. Punctuation, lists and second thoughts come out right."),
        Slide(title: "A keyboard\nthat listens",
              detail: "Switch to the VoiceiQ keyboard and tap the mic, wherever you type."),
        Slide(title: "Notes from\nevery meeting",
              detail: "Record a meeting or a passing thought. Get the transcript, a summary and the action items."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Wordmark(height: 24)
                Spacer()
                Button("Skip", action: onFinished)
                    .buttonStyle(.compactSecondary)
                    .opacity(page < slides.count - 1 ? 1 : 0)
                    .disabled(page == slides.count - 1)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.top, Theme.Spacing.s)

            TabView(selection: $page) {
                ForEach(slides.indices, id: \.self) { index in
                    slide(index).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: Theme.Spacing.l) {
                PageDots(count: slides.count, current: page)
                Button(page == slides.count - 1 ? "Get started" : "Continue") {
                    if page == slides.count - 1 {
                        onFinished()
                    } else {
                        withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
                    }
                }
                .buttonStyle(.primaryPill)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, Theme.Spacing.s)
        }
        .readableWidth(560)
    }

    private func slide(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ZStack {
                RadialGradient(colors: [Theme.Colors.accent.opacity(0.16), .clear],
                               center: .center, startRadius: 10, endRadius: 220)
                Group {
                    switch index {
                    case 0: DictateAnywhereScene()
                    case 1: KeyboardScene()
                    default: MeetingScene()
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text(slides[index].title)
                    .font(Theme.Fonts.display())
                    .foregroundStyle(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(slides[index].detail)
                    .font(Theme.Fonts.callout())
                    .foregroundStyle(Theme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, Theme.Spacing.l)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Theme.Colors.accent : Theme.Colors.hairline)
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

// MARK: - Scenes

/// A message being written by voice: an empty field, then listening, then the
/// finished sentence.
private struct DictateAnywhereScene: View {
    @State private var phase = Phase.empty

    enum Phase: Int, CaseIterable, LoopPhase {
        case empty, listening, typed
        var hold: Double { [0.9, 1.8, 2.6][rawValue] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                AppGlyph(symbol: "message.fill", tint: .green)
                AppGlyph(symbol: "envelope.fill", tint: .blue)
                AppGlyph(symbol: "note.text", tint: .orange)
                AppGlyph(symbol: "bubble.left.and.text.bubble.right.fill", tint: .purple)
            }
            SceneCard {
                Text("Sam")
                    .font(Theme.Fonts.label())
                    .foregroundStyle(Theme.Colors.muted)
                Text("Are you on your way?")
                    .font(Theme.Fonts.subheadline())
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Colors.porcelain))
                HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
                    Group {
                        switch phase {
                        case .empty:
                            Text("Message").foregroundStyle(Theme.Colors.muted)
                        case .listening:
                            WaveBars(active: true, color: Theme.Colors.recording).frame(height: 18)
                        case .typed:
                            Text("Running ten minutes late. Start without me, I’ll catch up!")
                                .foregroundStyle(Theme.Colors.ink)
                        }
                    }
                    .font(Theme.Fonts.subheadline())
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .transition(.opacity)
                    MicBadge(listening: phase == .listening)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.Colors.hairline))
            }
        }
        .loopingPhases($phase, still: .typed)
    }
}

/// The VoiceiQ keyboard under a field, listening, then the text it typed.
private struct KeyboardScene: View {
    @State private var phase = Phase.idle

    enum Phase: Int, CaseIterable, LoopPhase {
        case idle, listening, typed
        var hold: Double { [1.0, 1.8, 2.4][rawValue] }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            SceneCard {
                Text(phase == .typed ? "Dinner at seven? I’ll bring dessert." : " ")
                    .font(Theme.Fonts.subheadline())
                    .foregroundStyle(Theme.Colors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
            }
            MiniKeyboard(style: .voiceIQ(listening: phase == .listening))
        }
        .loopingPhases($phase, still: .listening)
    }
}

/// A meeting recording, its transcript filling in, then its action items.
private struct MeetingScene: View {
    @State private var phase = Phase.first

    enum Phase: Int, CaseIterable, LoopPhase {
        case first, second, third, notes
        var hold: Double { [0.9, 0.9, 1.0, 2.8][rawValue] }
    }

    private let lines = [
        ("Priya", "Can we ship the beta on Friday?"),
        ("You", "Yes, if the review is done Thursday."),
        ("Sam", "I’ll send the mockups tomorrow."),
    ]

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            SceneCard {
                HStack {
                    Text("Beta planning").font(Theme.Fonts.headline()).foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(Theme.Colors.recording).frame(width: 7, height: 7)
                        Text("12:04").font(Theme.Fonts.numeric(12, weight: 500)).foregroundStyle(Theme.Colors.muted)
                    }
                }
                ForEach(lines.indices, id: \.self) { index in
                    if index <= phase.rawValue {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                            Text(lines[index].0).font(Theme.Fonts.label()).foregroundStyle(Theme.Colors.accent)
                                .frame(width: 40, alignment: .leading)
                            Text(lines[index].1).font(Theme.Fonts.subheadline()).foregroundStyle(Theme.Colors.inkSecondary)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            if phase == .notes {
                SceneCard {
                    Text("ACTION ITEMS").font(Theme.Fonts.caption()).tracking(0.6).foregroundStyle(Theme.Colors.muted)
                    Label { Text("**Sam:** send the mockups") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.success) }
                    Label { Text("**You:** finish the review by Thursday") } icon: { Image(systemName: "circle").foregroundStyle(Theme.Colors.muted) }
                }
                .font(Theme.Fonts.subheadline())
                .foregroundStyle(Theme.Colors.ink)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .loopingPhases($phase, still: .notes)
    }
}

// MARK: - Scene parts

private struct SceneCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) { content }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.Colors.surface)
                .shadow(color: .black.opacity(0.08), radius: 18, y: 8))
    }
}

private struct AppGlyph: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
    }
}

private struct MicBadge: View {
    let listening: Bool

    var body: some View {
        Image(systemName: listening ? "waveform" : "mic.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(listening ? Theme.Colors.recording : Theme.Colors.accent))
    }
}

/// Bars that move like a voice level while `active`.
struct WaveBars: View {
    let active: Bool
    var color: Color = Theme.Colors.accent
    var count = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    let wave = (sin(t * 7 + Double(index) * 0.7) + sin(t * 3.1 + Double(index) * 1.3)) / 4 + 0.5
                    Capsule()
                        .fill(color)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: active ? 0.25 + 0.75 * wave : 0.2, anchor: .center)
                }
            }
        }
    }
}
