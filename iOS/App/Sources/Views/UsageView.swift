import SwiftUI
import VoiceIQCore

/// Cost, as on the Mac: one source at a time (Gemini, OpenAI, ElevenLabs,
/// MAI or Sarvam), opening on the selected provider, in dollars or rupees.
/// Period totals, cost per action, and in Detailed the per-model table and
/// the most recent calls.
struct UsageView: View {
    enum Currency: String, CaseIterable, Identifiable {
        case usd, inr
        var id: String { rawValue }
        var title: String { self == .usd ? "USD" : "INR" }
    }

    enum Period: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return "Today"
            case .week: return "Week"
            case .month: return "Month"
            case .all: return "All time"
            }
        }
        var start: Date? {
            let calendar = Calendar.current
            let now = Date()
            switch self {
            case .today: return calendar.startOfDay(for: now)
            case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.start
            case .month: return calendar.dateInterval(of: .month, for: now)?.start
            case .all: return nil
            }
        }
    }

    @State private var source = CostSource(SettingsStore().preferredProvider)
    @State private var period: Period = .month
    @AppStorage("costPaneDetailed") private var detailed = false
    @AppStorage("costPaneCurrency") private var currency: Currency = .usd
    @State private var total = UsageStore.Total.zero
    @State private var byActivity: [(key: String, total: UsageStore.Total)] = []
    @State private var byModel: [(key: String, total: UsageStore.Total)] = []
    @State private var recent: [UsageRecord] = []

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Picker("Source", selection: $source) {
                        ForEach(CostSource.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Currency", selection: $currency) {
                        ForEach(Currency.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Card {
                        Text(money(total))
                            .font(Theme.Fonts.numeric(40, weight: 250)).foregroundStyle(Theme.Colors.ink)
                        Text("\(total.calls.formatted()) requests")
                            .font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                if byActivity.isEmpty {
                    Text("No calls in this period").foregroundStyle(Theme.Colors.muted)
                }
                ForEach(byActivity, id: \.key) { item in
                    row(UsageActivity(rawValue: item.key)?.displayName ?? item.key, item.total)
                }
            } header: { SettingsSectionHeader("By action") }
            Section {
                Toggle("Detailed", isOn: $detailed)
            }
            if detailed {
                Section {
                    ForEach(byModel, id: \.key) { item in row(item.key, item.total) }
                } header: { SettingsSectionHeader("By model") }
                Section {
                    if recent.isEmpty {
                        Text("Nothing recorded yet").foregroundStyle(Theme.Colors.muted)
                    }
                    ForEach(recent) { record in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text("\(record.activityValue.displayName) · \(record.stageValue?.displayName ?? record.stage)")
                                    .font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink)
                                Text("\(record.model) · \(UsageFormat.measure(record)) · \(record.at.formatted(date: .abbreviated, time: .shortened))")
                                    .font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
                            }
                            Spacer()
                            Text(money(record))
                                .font(Theme.Fonts.body()).monospacedDigit().foregroundStyle(Theme.Colors.ink)
                        }
                    }
                } header: { SettingsSectionHeader("Recent calls") }
            }
            Section {
                Text(footer)
                    .font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
            }
        }
        .settingsPage(title: "Cost")
        .onAppear {
            reload()
            if let store = UsageMeter.store { Task { await store.backfillFX() } }
        }
        .onChange(of: source) { _, _ in reload() }
        .onChange(of: period) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .gtUsageDidChange)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in reload() }
    }

    /// Where the shown source's prices come from, and the rate behind the
    /// other currency.
    private var footer: String {
        var note = source.pricingNote(activeRoute: SettingsStore().activeRoute)
        // The Sarvam note already names the rate: its prices start in rupees.
        if currency == .inr, source != .sarvam {
            note += " Rupees at the European Central Bank rate of each call's day (Frankfurter)."
        }
        return detailed ? note + " ≈ marks estimated tokens, an unpriced model or a missing rate." : note
    }

    private func row(_ name: String, _ total: UsageStore.Total) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(name).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink)
                Text(detailed
                     ? (["\(total.calls) calls"] + [UsageFormat.measure(total)].compactMap { $0 }).joined(separator: " · ")
                     : "\(total.calls) calls")
                    .font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
            }
            Spacer()
            Text(money(total))
                .font(Theme.Fonts.body()).monospacedDigit().foregroundStyle(Theme.Colors.ink)
        }
    }

    private func reload() {
        guard let store = UsageMeter.store else { return }
        total = store.total(since: period.start, source: source)
        byActivity = store.totalsByActivity(since: period.start, source: source)
        byModel = store.totalsByModel(since: period.start, source: source)
        recent = store.recent(limit: 30, source: source)
    }

    private func money(_ total: UsageStore.Total) -> String {
        switch currency {
        case .usd: return Self.money(total.costUSD, approximate: total.isApproximate)
        case .inr: return Self.money(total.costINR, currency: .inr, approximate: total.isApproximate || total.fxMissing)
        }
    }

    private func money(_ record: UsageRecord) -> String {
        let value = currency == .usd ? record.costUSD : record.costINR
        return Self.money(value, currency: currency, approximate: record.isEstimated || value == nil)
    }

    /// Costs are fractions of a cent per dictation, so four decimals until a
    /// whole unit, two after.
    static func money(_ value: Double?, currency: Currency = .usd, approximate: Bool = false) -> String {
        guard let value else { return "—" }
        let symbol = currency == .usd ? "$" : "₹"
        let text = value >= 1 ? String(format: "%@%.2f", symbol, value) : String(format: "%@%.4f", symbol, value)
        return approximate ? "≈" + text : text
    }
}
