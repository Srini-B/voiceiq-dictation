import SwiftUI
import VoiceIQCore

/// The Mac History's stats on a page of their own, with its period menu.
/// `HistoryStore.stats(period:)` counts dictations since deleted from History,
/// and streaks and active days always span all time.
struct StatsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("historyStatsPeriod") private var period = HistoryStore.StatsPeriod.allTime
    @State private var stats = HistoryStore.Stats(totalWords: 0, totalDictations: 0, averageWPM: 0)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                // The titles are too long for a segmented control on a phone.
                SearchablePicker("Period", selection: $period,
                                 options: HistoryStore.StatsPeriod.allCases.map { SearchOption(value: $0, name: $0.title) },
                                 hidesTitle: true)
                Grid(horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.m) {
                    GridRow {
                        StatTile(value: stats.totalWords.formatted(), label: "Words")
                        StatTile(value: stats.totalDictations.formatted(), label: "Dictations")
                    }
                    GridRow {
                        StatTile(value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "–", label: "Words / min")
                        StatTile(value: stats.audioLabel, label: "Audio")
                    }
                    GridRow {
                        StatTile(value: stats.savedLabel, label: "Time saved")
                        StatTile(value: stats.currentStreak > 0 ? "\(stats.currentStreak)" : "–", label: "Day streak")
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    if stats.activeDays > 0 {
                        Text("Longest streak ^[\(stats.longestStreak) day](inflect: true) · active on ^[\(stats.activeDays) day](inflect: true)")
                    }
                    Text("Counts every dictation, including ones deleted from History. Time saved compares with typing at \(Int(HistoryStore.Stats.typingWPM)) words per minute.")
                }
                .font(Theme.Fonts.footnote())
                .foregroundStyle(Theme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.l)
            .readableWidth()
        }
        .themedBackground()
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: period) { _, _ in reload() }
        // A new day can start or end a streak.
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .gtHistoryDidChange).receive(on: RunLoop.main)) { _ in reload() }
    }

    private func reload() {
        stats = model.historyStore?.stats(period: period) ?? stats
    }
}

/// One figure on a tile, as on Home.
struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
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
        .accessibilityElement(children: .combine)
    }
}
