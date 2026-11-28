import SwiftUI

/// The first thing a new user sees: three short slides, one benefit each,
/// with a small animated drawing, then setup.
struct IntroSlides: View {
    let onFinished: () -> Void
    @State private var page = 0

    private struct Slide {
        let title: String
        let detail: String
    }

    private let slides = [
        Slide(title: "Talk.\nVoiceiQ types.",
              detail: "Dictate in any app, with the punctuation done."),
        Slide(title: "A keyboard\nthat listens",
              detail: "Tap the Talk key wherever you type."),
        Slide(title: "Notes from\nevery meeting",
              detail: "A transcript, a summary and the action items."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Wordmark(height: 22)
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

            VStack(spacing: Theme.Spacing.xl) {
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
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
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

            Group {
                switch index {
                case 0: DictateAnywhereScene()
                case 1: KeyboardScene()
                default: MeetingScene()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.xxl)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Theme.Colors.ink : Theme.Colors.hairline)
                    .frame(width: index == current ? 20 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

// MARK: - Scenes

/// A reply being written by voice: empty, listening, then the finished
/// sentence, under a row of the apps it works in.
private struct DictateAnywhereScene: View {
    @State private var phase = Phase.empty

    enum Phase: Int, CaseIterable, LoopPhase {
        case empty, listening, typed
        var hold: Double { [0.9, 1.8, 2.6][rawValue] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(["Messages", "Mail", "Notes", "Slack"], id: \.self) { app in
                    Text(app)
                        .font(Theme.Fonts.footnote())
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.Colors.porcelain))
                }
            }
            SceneCard {
                Text("Are you on your way?")
                    .font(Theme.Fonts.callout())
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Colors.porcelain))
                HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
                    Group {
                        switch phase {
                        case .empty:
                            Text("Message").foregroundStyle(Theme.Colors.faint)
                        case .listening:
                            WaveBars(active: true, color: Theme.Colors.inkSecondary).frame(height: 18)
                        case .typed:
                            Text("Running ten minutes late. Start without me, I’ll catch up!")
                                .foregroundStyle(Theme.Colors.ink)
                        }
                    }
                    .font(Theme.Fonts.callout())
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .transition(.opacity)
                    TalkKeyGlyph(size: 32, recording: phase == .listening)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 1))
            }
        }
        .loopingPhases($phase, still: .typed)
    }
}

/// A field above a drawn keyboard with the Talk key: idle, recording, then
/// the text it typed.
private struct KeyboardScene: View {
    @State private var phase = Phase.idle

    enum Phase: Int, CaseIterable, LoopPhase {
        case idle, listening, typed
        var hold: Double { [1.0, 1.8, 2.4][rawValue] }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            SceneCard {
                Text(phase == .typed ? "Dinner at seven? I’ll bring dessert." : "Reply")
                    .font(Theme.Fonts.callout())
                    .foregroundStyle(phase == .typed ? Theme.Colors.ink : Theme.Colors.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
            }
            DrawnKeyboard(listening: phase == .listening)
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
                        Text("12:04").font(Theme.Fonts.numeric(13, weight: 400)).foregroundStyle(Theme.Colors.muted)
                    }
                }
                ForEach(lines.indices, id: \.self) { index in
                    if index <= phase.rawValue {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                            Text(lines[index].0).font(Theme.Fonts.label()).foregroundStyle(Theme.Colors.muted)
                                .frame(width: 44, alignment: .leading)
                            Text(lines[index].1).font(Theme.Fonts.callout()).foregroundStyle(Theme.Colors.ink)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            if phase == .notes {
                SceneCard {
                    Text("Action items").font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
                    Label { Text("Sam sends the mockups") } icon: { Image(systemName: "circle").foregroundStyle(Theme.Colors.inkSecondary) }
                    Label { Text("You finish the review by Thursday") } icon: { Image(systemName: "circle").foregroundStyle(Theme.Colors.inkSecondary) }
                }
                .font(Theme.Fonts.callout())
                .foregroundStyle(Theme.Colors.ink)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .loopingPhases($phase, still: .notes)
    }
}

// MARK: - Scene parts

/// A flat card with a hairline ring.
private struct SceneCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) { content }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }
}

/// Rows of blank keys under a bar with the Talk key. A drawing, not the
/// keyboard's real layout.
private struct DrawnKeyboard: View {
    let listening: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                if listening {
                    WaveBars(active: true, color: Theme.Colors.inkSecondary, count: 14)
                        .frame(width: 90, height: 18)
                        .transition(.opacity)
                }
                Spacer()
                TalkKeyGlyph(size: 36, recording: listening)
            }
            .frame(height: 40)
            ForEach([10, 9, 7], id: \.self) { count in
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.Colors.surface)
                            .frame(height: 30)
                    }
                }
                .padding(.horizontal, CGFloat(10 - count) * 10)
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.Colors.surface)
                .frame(height: 30)
                .padding(.horizontal, 50)
        }
        .padding(Theme.Spacing.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.porcelain))
        .animation(.easeInOut(duration: 0.25), value: listening)
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
