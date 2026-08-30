import Charts
import CodexMetricsCore
import SwiftUI

struct BillingView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var historyPage = 0

    private let historyPageSize = 20

    private var currentPeriod: PeriodMetric? {
        guard let interval = currentPeriodInterval else { return nil }
        return store.trendPeriods.first { $0.start == interval.start }
    }

    private var currentPeriodInterval: DateInterval? {
        let component: Calendar.Component = switch store.range {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        return store.analyticsCalendar.dateInterval(of: component, for: .now)
    }

    private var currentPeriodTitle: String {
        switch store.range {
        case .day: "Today"
        case .week: "This week"
        case .month: "This month"
        case .year: "This year"
        }
    }

    private var currentPeriodDetail: String {
        guard let interval = currentPeriodInterval else { return "Current calendar period" }
        let start = interval.start
        let through = Date.now
        let dateRange: String = switch store.range {
        case .day:
            through.formatted(date: .abbreviated, time: .omitted)
        case .week, .month:
            "\(start.formatted(.dateTime.month(.abbreviated).day()))–\(through.formatted(.dateTime.month(.abbreviated).day()))"
        case .year:
            through.formatted(.dateTime.year())
        }
        return "\(dateRange) · API-equivalent estimate"
    }

    private var historyTitle: String {
        switch store.range {
        case .day: "Daily history"
        case .week: "Weekly history"
        case .month: "Monthly history"
        case .year: "Yearly history"
        }
    }

    private var historySubtitle: String {
        let unit = store.range.rawValue.lowercased()
        return "A \(unit)-by-\(unit) comparison across all retained usage."
    }

    private var historyPageCount: Int {
        max(1, (store.trendPeriods.count + historyPageSize - 1) / historyPageSize)
    }

    private var historyPageData: (periods: [PeriodMetric], summary: String, pageCount: Int) {
        let periods = store.trendPeriods
        let pageCount = max(1, (periods.count + historyPageSize - 1) / historyPageSize)
        guard !periods.isEmpty else { return ([], "0 periods", pageCount) }

        let safePage = min(historyPage, pageCount - 1)
        let offset = safePage * historyPageSize
        let end = periods.count - offset
        let start = max(0, end - historyPageSize)
        let visiblePeriods = Array(periods[start..<end].reversed())
        let summary = "\(offset + 1)–\(offset + visiblePeriods.count) of \(periods.count) periods"
        return (visiblePeriods, summary, pageCount)
    }

    private func historyPeriodLabel(_ start: Date) -> String {
        switch store.range {
        case .day:
            return start.formatted(date: .abbreviated, time: .omitted)
        case .week:
            if let interval = store.analyticsCalendar.dateInterval(of: .weekOfYear, for: start) {
                let end = store.analyticsCalendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
                return "\(start.formatted(.dateTime.month(.abbreviated).day()))–\(end.formatted(.dateTime.month(.abbreviated).day().year()))"
            }
            return start.formatted(date: .abbreviated, time: .omitted)
        case .month:
            return start.formatted(.dateTime.year().month(.wide))
        case .year:
            return start.formatted(.dateTime.year())
        }
    }

    var body: some View {
        let historyPageData = self.historyPageData

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                SubscriptionUsageView(snapshot: store.subscription)
                Divider()
                SectionHeader(
                    title: "API-equivalent cost",
                    subtitle: "The highlighted estimate covers the current \(store.range.rawValue.lowercased()) to date. It is separate from your ChatGPT subscription and is not an invoice.",
                    definition: .estimatedCost
                )
                HStack(spacing: 12) {
                    MetricCard(title: currentPeriodTitle, value: MetricFormatters.currency(currentPeriod?.estimatedCost ?? 0), detail: currentPeriodDetail, icon: "dollarsign.circle.fill", tint: .green, definition: .estimatedCost)
                    MetricCard(title: "All-history coverage", value: (store.costCoverage * 100).formatted(.number.precision(.fractionLength(1))) + "%", detail: "Priced tokens in retained history", icon: "checkmark.seal.fill", tint: .blue, definition: .costCoverage)
                    MetricCard(title: "Latest rate card", value: store.pricingEffectiveDate, detail: store.pricingSource, icon: "calendar", tint: .purple)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("This is not an invoice", systemImage: "info.circle.fill").font(.headline).foregroundStyle(.orange)
                    Text("Codex sessions authenticated through a ChatGPT plan are governed by that plan, not charged as per-token API calls. These estimates answer “what would this workload cost at API list price?” Actual API invoices require the OpenAI Organization Costs endpoint and cannot be reconstructed reliably from local session files.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(
                        title: "Historical data",
                        subtitle: "Durable token events and effective-dated prices, stored separately from the parser cache."
                    )
                    HStack(spacing: 10) {
                        Button("Scan All History", systemImage: "externaldrive.badge.plus") { store.preserveAllHistory() }
                            .disabled(store.isBusy)
                        Button("Refresh Prices", systemImage: "arrow.triangle.2.circlepath") { store.refreshPricing(force: true) }
                            .disabled(store.isRefreshingPricing)
                        Button("Export History…", systemImage: "square.and.arrow.up") { store.exportHistory() }
                        Button("Import History…", systemImage: "square.and.arrow.down") { store.importHistory() }
                        Spacer()
                        Text("\(store.historySessionCount.formatted()) preserved sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        if store.isRefreshingPricing {
                            ActivityIndicator(size: 12)
                        }
                        Text("Pricing: \(store.pricingSource)")
                        if let updatedAt = store.pricingUpdatedAt {
                            Text("· updated \(updatedAt, style: .relative)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let message = store.historyMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(18)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                ModelPricingView(pricing: store.pricing)
                ActivityChart(
                    periods: store.trendPeriods,
                    granularity: store.range.granularity,
                    title: historyTitle,
                    subtitle: "\(historySubtitle) Showing up to 30 periods at once; drag, swipe, or use the edge arrows to move through time.",
                    initialMetric: "Cost",
                    showsMetricPicker: false,
                    allowsPeriodSelection: false
                )
                Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 12) {
                    GridRow {
                        Text(store.range.rawValue)
                        Text("Sessions")
                        MetricHelpLabel(title: "Tokens", definition: .totalTokens)
                        MetricHelpLabel(title: "Agent runtime", definition: .agentRuntime)
                        MetricHelpLabel(title: "Estimated cost", definition: .estimatedCost)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellColumns(5)
                    ForEach(historyPageData.periods) { period in
                        GridRow {
                            Text(historyPeriodLabel(period.start)).fontWeight(.medium)
                            Text(period.sessions.formatted()).monospacedDigit()
                            Text(MetricFormatters.compactNumber(period.usage.total)).monospacedDigit()
                            Text(MetricFormatters.duration(period.activeRuntime)).monospacedDigit()
                            Text(MetricFormatters.currency(period.estimatedCost)).monospacedDigit()
                        }
                    }

                    Divider().gridCellColumns(5)
                    GridRow {
                        HStack(spacing: 12) {
                            Text(historyPageData.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                historyPage = max(0, historyPage - 1)
                            } label: {
                                Label("Previous page", systemImage: "chevron.left")
                                    .labelStyle(.iconOnly)
                            }
                            .disabled(historyPage == 0)
                            .help("Previous page")
                            Text("Page \(min(historyPage + 1, historyPageData.pageCount)) of \(historyPageData.pageCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button {
                                historyPage = min(historyPageData.pageCount - 1, historyPage + 1)
                            } label: {
                                Label("Next page", systemImage: "chevron.right")
                                    .labelStyle(.iconOnly)
                            }
                            .disabled(historyPage >= historyPageData.pageCount - 1)
                            .help("Next page")
                        }
                        .frame(maxWidth: .infinity)
                        .gridCellColumns(5)
                    }
                }
            }.padding(28)
        }
        .navigationTitle("Usage & Billing")
        .onChange(of: store.range) { _, _ in historyPage = 0 }
        .onChange(of: store.trendPeriods.map(\.id)) { _, _ in
            historyPage = min(historyPage, historyPageCount - 1)
        }
    }
}

private struct SubscriptionUsageView: View {
    let snapshot: SubscriptionSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Subscription usage", subtitle: "Latest quota snapshot reported by the selected provider; no token-to-quota conversion is inferred locally.", definition: .subscriptionQuota)
            if let snapshot {
                HStack(spacing: 12) {
                    MetricCard(
                        title: "Current plan",
                        value: snapshot.displayPlan,
                        detail: snapshot.limitName ?? snapshot.limitID.capitalized,
                        icon: "person.crop.circle.badge.checkmark",
                        tint: .blue
                    )
                    MetricCard(
                        title: "Credits",
                        value: creditsValue(snapshot.credits),
                        detail: creditsDetail(snapshot.credits),
                        icon: "creditcard.fill",
                        tint: .purple
                    )
                    MetricCard(
                        title: "Limit status",
                        value: snapshot.rateLimitReachedType == nil ? "Available" : "Reached",
                        detail: snapshot.rateLimitReachedType ?? "No active limit reported",
                        icon: snapshot.rateLimitReachedType == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        tint: snapshot.rateLimitReachedType == nil ? .green : .red
                    )
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(snapshot.windows) { window in QuotaWindowCard(window: window) }
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark")
                    Text("Observed \(snapshot.observedAt.formatted(date: .abbreviated, time: .standard)). Only windows present in the current Codex response are shown.")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "No quota snapshot yet",
                    systemImage: "gauge.with.dots.needle.33percent",
                    description: Text("Complete a Codex turn, then refresh. Subscription details are read from recent local quota events.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
    }

    private func creditsValue(_ credits: SubscriptionCredits?) -> String {
        guard let credits else { return "Not reported" }
        if credits.unlimited { return "Unlimited" }
        if let balance = credits.balance, credits.hasCredits { return balance }
        return "None"
    }

    private func creditsDetail(_ credits: SubscriptionCredits?) -> String {
        guard let credits else { return "No credit field in snapshot" }
        if credits.unlimited { return "Account reports unlimited credits" }
        return credits.hasCredits ? "Available balance" : "No add-on credits reported"
    }
}

private struct QuotaWindowCard: View {
    let window: UsageQuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(window.displayName).font(.headline)
                Spacer()
                Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))% remaining")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            MetricProgressBar(value: window.remainingPercent, total: 100)
                .tint(quotaColor)
            HStack {
                Text("Quota available")
                Spacer()
                if window.resetsAt > .now {
                    Text("Resets ") + Text(window.resetsAt, style: .relative)
                } else {
                    Text("Reset due")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(window.resetsAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.separator.opacity(0.45)))
    }

    private var quotaColor: Color {
        switch window.remainingPercent {
        case ...10: .red
        case ...25: .orange
        default: .teal
        }
    }
}
