import SwiftUI
import VoiceIQCore

struct HomeView: View {
    @Binding var tab: RootView.Tab
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: VoiceSession
    @EnvironmentObject private var setup: SetupMonitor
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var stats: HistoryStore.Stats?
    @State private var recent: [DictationRecord] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    header
                    if sizeClass == .regular {
                        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xl) { primary }
                            VStack(alignment: .leading, spacing: Theme.Spacing.xl) { secondary }
                        }
                    } else {
                        primary
                        secondary
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.bottom, Theme.Spacing.xxl)
                .readableWidth(1080)
            }
            .keyboardDismissable()
            .themedBackground()
            .onTapGesture { UIApplication.shared.endEditing() }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .gtHistoryDidChange).receive(on: RunLoop.main)) { _ in refresh() }
        }
    }

    @ViewBuilder private var primary: some View {
        SessionCard()
        if !setup.status.isComplete { SetupCard() }
        if UIDevice.isPad {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                GroupLabel(text: "Hardware keyboard")
                Card { HardwareKeyboardSteps() }
            }
        }
    }

    @ViewBuilder private var secondary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            GroupLabel(text: "Try it")
            TryItCard()
        }
        if let stats, stats.totalDictations > 0 {
            StatsRow(stats: stats)
        }
        if !recent.isEmpty {
            RecentList(records: recent) { tab = .history }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            Wordmark(height: 28)
            Spacer()
            StatusChip(text: session.isActive ? "On" : "Off", tone: session.isActive ? .live : .off)
        }
        .padding(.top, Theme.Spacing.m)
    }

    private func refresh() {
        setup.refresh()
        stats = model.historyStore?.stats()
        recent = Array((model.historyStore?.records(matching: nil) ?? []).prefix(3))
    }
}

/// The session: while a keeper holds it, the keyboard's mic starts in place
/// instead of switching to VoiceiQ.
private struct SessionCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        Card(padding: Theme.Spacing.xl) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.isActive ? "Skips app switching" : "Needs app switching")
                        .font(Theme.Fonts.title2())
                        .foregroundStyle(Theme.Colors.ink)
                    subtitle
                        .font(Theme.Fonts.subheadline())
                        .foregroundStyle(Theme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.m)
                SessionGlyph(active: session.isActive)
            }
            if session.isActive {
                Button("Turn off now", action: model.endSession)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
    }

    @ViewBuilder private var subtitle: some View {
        if let until = session.warmUntil {
            HStack(spacing: 4) {
                Text("Turns off in")
                Text(timerInterval: Date()...until, countsDown: true).monospacedDigit()
            }
        } else if let keeper = session.keeper {
            switch keeper {
            case .openMic: Text("Mic is on")
            case .backgroundAudio: Text("Ready in the background")
            }
        } else if UIDevice.isPad {
            if #available(iOS 18.0, *) {
                Text("Tap the mic on the VoiceiQ keyboard, or use VoiceiQ Dictate.")
            } else {
                Text("Disconnect any hardware keyboard, then tap the mic on the VoiceiQ keyboard.")
            }
        } else {
            Text("Tap the mic on the VoiceiQ keyboard, or press the Action button.")
        }
    }
}

/// A mic in a ring that breathes while the session is on.
private struct SessionGlyph: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.Colors.accent.opacity(active ? 0.14 : 0.06))
                .frame(width: 56, height: 56)
                .scaleEffect(active && pulse ? 1.12 : 1)
            Image(systemName: active ? "waveform" : "mic.slash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(active ? Theme.Colors.accent : Theme.Colors.muted)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever()) { pulse = true } }
        .accessibilityHidden(true)
    }
}

private struct SetupCard: View {
    @EnvironmentObject private var setup: SetupMonitor

    var body: some View {
        let status = setup.status
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            GroupLabel(text: "Finish setup")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink { KeysView() } label: {
                        SetupLine(title: "API key", done: status.hasKey)
                    }
                    Divider().padding(.leading, 52)
                    NavigationLink { KeyboardSetupView() } label: {
                        SetupLine(title: "Microphone", done: status.micGranted)
                    }
                    Divider().padding(.leading, 52)
                    NavigationLink { KeyboardSetupView() } label: {
                        SetupLine(title: "Keyboard and Full Access", done: status.keyboardReady,
                                  waiting: status.keyboardAdded && !status.fullAccess)
                    }
                }
            }
        }
    }
}

private struct SetupLine: View {
    let title: String
    let done: Bool
    var waiting = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: done ? "checkmark.circle.fill" : waiting ? "clock" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(done ? Theme.Colors.success : waiting ? Theme.Colors.pending : Theme.Colors.muted.opacity(0.6))
                .frame(width: 24)
            Text(title).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Colors.muted)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

private struct StatsRow: View {
    let stats: HistoryStore.Stats

    var body: some View {
        Grid(horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.m) {
            GridRow {
                tile(stats.totalWords.formatted(.number.notation(.compactName)), "Words")
                tile(stats.totalDictations.formatted(), "Dictations")
            }
            GridRow {
                tile(stats.averageWPM > 0 ? "\(stats.averageWPM)" : "–", "Words / min")
                tile(stats.audioLabel, "Audio")
            }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.Fonts.numeric(26, weight: 300))
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
    }
}

private struct RecentList: View {
    let records: [DictationRecord]
    let seeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                GroupLabel(text: "Recent")
                Spacer()
                Button("See all", action: seeAll).font(Theme.Fonts.label()).foregroundStyle(Theme.Colors.accent)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider().padding(.leading, Theme.Spacing.l) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.displayText.isEmpty ? "No text" : record.displayText)
                                .font(Theme.Fonts.callout())
                                .foregroundStyle(Theme.Colors.ink)
                                .lineLimit(2)
                            Text(meta(record)).font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, Theme.Spacing.m)
                    }
                }
            }
        }
    }

    private func meta(_ record: DictationRecord) -> String {
        let when = record.startedAt.formatted(.relative(presentation: .named))
        return [when, AppNames.name(for: record)].compactMap { $0 }.joined(separator: " · ")
    }
}
