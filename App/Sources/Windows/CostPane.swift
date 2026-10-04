import SwiftUI
import VoiceIQCore

/// Cost Analysis: what the model calls behind each action cost, for one
/// source at a time (Gemini, OpenAI, ElevenLabs, MAI or Sarvam). It opens on
/// the provider selected in Settings; the toggle shows the others' calls.
/// Period totals up top, then a breakdown by action and by model for the
/// chosen period, then the most recent calls. Shown in dollars or rupees:
/// every row carries the ECB rate of its day, so either is a sum of rows.
struct CostPane: View {
    let store: UsageStore

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
            case .week: return "This week"
            case .month: return "This month"
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

    @State private var period: Period = .month
    @State private var source = CostSource(SettingsStore().preferredProvider)
    /// Simple view: period totals and cost per action. Detailed adds tokens,
    /// the per-model table, and the recent-call list.
    @AppStorage("costPaneDetailed") private var detailed = false
    @AppStorage("costPaneCurrency") private var currency: Currency = .usd
    @State private var totals: [Period: UsageStore.Total] = [:]
    @State private var byActivity: [(key: String, total: UsageStore.Total)] = []
    @State private var byModel: [(key: String, total: UsageStore.Total)] = []
    @State private var recent: [UsageRecord] = []
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.l) {
                // Its own row: beside the totals, four sources squeezed them
                // into "$0.01…".
                HStack {
                    Picker("Source", selection: $source) {
                        ForEach(CostSource.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: source) { _, _ in reload() }
                    Spacer()
                    Picker("Currency", selection: $currency) {
                        ForEach(Currency.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                summary
                HStack(spacing: VoiceIQUI.Spacing.m) {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: period) { _, _ in reloadBreakdown() }
                    Toggle("Detailed", isOn: $detailed)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(VoiceIQUI.TypeScale.body(grad: grad))
                }
                breakdown("By action", rows: byActivity.map { (UsageActivity(rawValue: $0.key)?.displayName ?? $0.key, $0.total) })
                if detailed {
                    breakdown("By model", rows: byModel.map { ($0.key, $0.total) })
                    recentCalls
                }
                Text(footer)
                    .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                    .foregroundStyle(.secondary)
            }
            .padding(VoiceIQUI.Spacing.l)
        }
        .onAppear {
            reload()
            Task { await store.backfillFX() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .gtUsageDidChange)
                .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        ) { _ in reload() }
    }

    // MARK: - Sections

    /// Names where the shown source's prices come from, and the rate behind
    /// the other currency.
    private var footer: String {
        var note = source.pricingNote(activeRoute: SettingsStore().activeRoute)
        // The Sarvam note already names the rate: its prices start in rupees.
        if currency == .inr, source != .sarvam {
            note += " Rupees at the European Central Bank rate of each call's day (Frankfurter)."
        }
        return detailed ? note + " ≈ marks estimated tokens, an unpriced model or a missing rate." : note
    }

    private var summary: some View {
        HStack(spacing: VoiceIQUI.Spacing.l) {
            ForEach(Period.allCases) { p in
                let total = totals[p] ?? .zero
                VStack(alignment: .leading, spacing: 1) {
                    Text(money(total))
                        .font(VoiceIQUI.TypeScale.title(grad: grad))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(p.title)
                        .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func breakdown(_ title: String, rows: [(String, UsageStore.Total)]) -> some View {
        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
            Text(title).font(VoiceIQUI.TypeScale.title(grad: grad))
            if rows.isEmpty {
                Text("No calls in this period")
                    .font(VoiceIQUI.TypeScale.body(grad: grad))
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: VoiceIQUI.Spacing.l, verticalSpacing: 6) {
                    GridRow {
                        header(""); header("Calls")
                        if detailed { header("Tokens in"); header("Tokens out"); header("Audio") }
                        header("Cost")
                    }
                    ForEach(rows, id: \.0) { name, total in
                        GridRow {
                            Text(name).font(VoiceIQUI.TypeScale.body(grad: grad))
                            cell("\(total.calls)")
                            if detailed {
                                cell(total.tokensIn > 0 ? UsageFormat.tokens(total.tokensIn) : "—")
                                cell(total.tokensOut > 0 ? UsageFormat.tokens(total.tokensOut) : "—")
                                cell(total.audioSeconds > 0 ? UsageFormat.audio(total.audioSeconds) : "—")
                            }
                            cell(money(total))
                        }
                    }
                }
            }
        }
        .padding(VoiceIQUI.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(.quaternary.opacity(0.4)))
    }

    private var recentCalls: some View {
        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
            Text("Recent calls").font(VoiceIQUI.TypeScale.title(grad: grad))
            if recent.isEmpty {
                Text("Nothing recorded yet")
                    .font(VoiceIQUI.TypeScale.body(grad: grad))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recent) { record in
                    HStack(spacing: VoiceIQUI.Spacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(record.activityValue.displayName) · \(record.stageValue?.displayName ?? record.stage)")
                                .font(VoiceIQUI.TypeScale.body(grad: grad))
                            Text("\(record.model) · \(UsageFormat.measure(record)) · \(record.at.formatted(date: .abbreviated, time: .shortened))")
                                .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(record))
                            .font(VoiceIQUI.TypeScale.body(grad: grad))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(VoiceIQUI.TypeScale.labelSmall(grad: grad)).foregroundStyle(.secondary)
    }

    private func cell(_ text: String) -> some View {
        Text(text).font(VoiceIQUI.TypeScale.body(grad: grad)).monospacedDigit()
    }

    // MARK: - Data

    private func reload() {
        var next: [Period: UsageStore.Total] = [:]
        for p in Period.allCases { next[p] = store.total(since: p.start, source: source) }
        totals = next
        recent = store.recent(limit: 30, source: source)
        reloadBreakdown()
    }

    private func reloadBreakdown() {
        byActivity = store.totalsByActivity(since: period.start, source: source)
        byModel = store.totalsByModel(since: period.start, source: source)
    }

    // MARK: - Formatting

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
