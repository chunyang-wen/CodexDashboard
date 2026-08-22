import Charts
import CodexMetricsCore
import SwiftUI

enum DashboardPage: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case projects = "Projects"
    case models = "Models"
    case billing = "Usage & Billing"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .projects: "folder"
        case .models: "cpu"
        case .billing: "dollarsign.circle"
        }
    }
}

private struct ActivityIndicator: View {
    let size: CGFloat

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(size <= 16 ? .small : .regular)
            .frame(width: size, height: size)
            .accessibilityLabel("In progress")
    }
}

private struct MetricProgressBar: View {
    let value: Double
    var total: Double = 1

    private var fraction: Double {
        guard total > 0, value.isFinite, total.isFinite else { return 0 }
        return min(1, max(0, value / total))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var selection: DashboardPage? = .overview

    var body: some View {
        NavigationSplitView {
            List(DashboardPage.allCases, selection: $selection) { page in
                Label(page.rawValue, systemImage: page.icon).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 188, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("LOCAL DATA").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
                    Text(store.codexHomeDisplayPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } detail: {
            Group {
                if store.isLoading && store.sessions.isEmpty {
                    VStack(spacing: 10) {
                        ActivityIndicator(size: 32)
                        Text("Loading metrics…")
                    }
                } else if let error = store.errorMessage, store.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn’t load metrics", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { store.load() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    page
                }
            }
            .overlay(alignment: .topTrailing) {
                if store.isUpdatingAnalytics {
                    AnalyticsUpdateOverlay(label: store.analyticsUpdateLabel)
                        .padding(18)
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Picker("Aggregation", selection: Binding(
                        get: { store.range },
                        set: { store.updateRange($0) }
                    )) {
                        ForEach(DashboardStore.Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 245)
                    Button { store.load() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(store.isBusy ? "Restart metrics refresh now" : "Refresh metrics now")
                    .accessibilityLabel(store.isBusy ? "Restart metrics refresh" : "Refresh metrics")
                    if store.isEnriching && !store.isUpdatingAnalytics {
                        MetricProgressBar(value: store.enrichmentFraction)
                            .frame(width: 76)
                            .help(store.enrichmentLabel)
                        Text("\(store.enrichedSessions)/\(store.enrichmentTotal)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help(store.enrichmentLabel)
                    }
                }
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch selection ?? .overview {
        case .overview: OverviewView()
        case .projects: ProjectsView()
        case .models: ModelsView()
        case .billing: BillingView()
        }
    }
}

private struct AnalyticsUpdateOverlay: View {
    let label: String

    var body: some View {
        HStack(spacing: 9) {
            ActivityIndicator(size: 16)
            Text(label)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.55)))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: DashboardStore
    @AppStorage("overviewActivityMetric") private var activityMetric = "Tokens"
    @State private var selectedPeriodStart: Date?
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

    private var currentPeriodStart: Date {
        periodInterval(containing: .now).start
    }

    private var effectivePeriodStart: Date {
        selectedPeriodStart ?? currentPeriodStart
    }

    private var selectedPeriod: PeriodMetric? {
        store.trendPeriods.first { $0.start == effectivePeriodStart }
    }

    var body: some View {
        let periodDetails = store.periodAggregate(in: periodInterval(containing: effectivePeriodStart))
        let medianTurn = Analytics.percentile(periodDetails.turnDurations, 0.5)
        let p95Turn = Analytics.percentile(periodDetails.turnDurations, 0.95)
        let averageTTFT = periodDetails.firstTokenTimes.isEmpty
            ? nil
            : periodDetails.firstTokenTimes.reduce(0, +) / Double(periodDetails.firstTokenTimes.count)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    SectionHeader(
                        title: "Codex activity",
                        subtitle: "Summary for the selected \(store.range.rawValue.lowercased()). Click a chart bar to inspect another period."
                    )
                    selectedPeriodBadge
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard(title: "Sessions", value: (selectedPeriod?.sessions ?? 0).formatted(), detail: "Sessions active in this period", icon: "bubble.left.and.text.bubble.right.fill", tint: .blue)
                    MetricCard(title: "Tokens", value: MetricFormatters.compactNumber(selectedPeriod?.usage.total ?? 0), detail: "\(((selectedPeriod?.usage.cacheHitRate ?? 0) * 100).formatted(.number.precision(.fractionLength(1))))% cache hit", icon: "text.word.spacing", tint: .purple, definition: .totalTokens)
                    MetricCard(title: "Agent runtime", value: MetricFormatters.duration(selectedPeriod?.activeRuntime ?? 0), detail: "Completed turn wall time", icon: "clock.fill", tint: .orange, definition: .agentRuntime)
                    MetricCard(title: "Equivalent cost", value: MetricFormatters.currency(selectedPeriod?.estimatedCost ?? 0), detail: "Estimated from token usage", icon: "dollarsign", tint: .green, definition: .estimatedCost)
                    MetricCard(title: "Median turn", value: medianTurn.map(MetricFormatters.duration) ?? "—", detail: "P95 \(p95Turn.map(MetricFormatters.duration) ?? "—")", icon: "gauge.with.dots.needle.50percent", tint: .pink, definition: .turnPercentiles)
                    MetricCard(title: "First token", value: averageTTFT.map(MetricFormatters.duration) ?? "—", detail: "Average response startup", icon: "bolt.fill", tint: .yellow, definition: .firstTokenLatency)
                    MetricCard(title: "Active days", value: periodDetails.activeDays.formatted(), detail: "Distinct calendar days", icon: "calendar.badge.clock", tint: .teal, definition: .activeDays)
                    MetricCard(title: "Tool calls", value: periodDetails.toolCalls.formatted(.number.notation(.compactName)), detail: "Calls in this period", icon: "hammer.fill", tint: .indigo, definition: .toolAttribution)
                    MetricCard(title: "Skill activations", value: periodDetails.skillCalls.formatted(.number.notation(.compactName)), detail: "Activations in this period", icon: "sparkles", tint: .mint, definition: .skillAttribution)
                }
                ActivityChart(
                    periods: store.trendPeriods,
                    granularity: store.range.granularity,
                    metric: $activityMetric,
                    selectedPeriodStart: $selectedPeriodStart
                )
                HStack(alignment: .top, spacing: 16) {
                    TopProjectsView(projects: Array(store.projects.prefix(7)))
                    ModelMixView(models: Array(store.models.prefix(7)))
                }
                ToolOverviewView(tools: Array(store.tools.prefix(10)), totalCalls: store.toolCalls)
                SkillOverviewView(skills: Array(store.skills.prefix(10)), totalCalls: store.skillCalls)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 8)
        }
        .navigationTitle("Overview")
        .onAppear { selectCurrentPeriod() }
        .onChange(of: store.range) { _, _ in selectCurrentPeriod() }
    }

    private var selectedPeriodBadge: some View {
        HStack(spacing: 8) {
            if effectivePeriodStart == currentPeriodStart {
                Text("CURRENT")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.tint)
            }
            Text(periodDisplayLabel)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.tint.opacity(0.2)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected period: \(periodDisplayLabel)")
    }

    private var periodDisplayLabel: String {
        let interval = periodInterval(containing: effectivePeriodStart)
        switch store.range.granularity {
        case .day:
            return effectivePeriodStart.formatted(date: .long, time: .omitted)
        case .week:
            let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return "\(effectivePeriodStart.formatted(.dateTime.month(.abbreviated).day()))–\(lastDay.formatted(.dateTime.month(.abbreviated).day().year()))"
        case .month:
            return effectivePeriodStart.formatted(.dateTime.year().month(.wide))
        case .year:
            return effectivePeriodStart.formatted(.dateTime.year())
        }
    }

    private func selectCurrentPeriod() {
        selectedPeriodStart = currentPeriodStart
    }

    private func periodInterval(containing date: Date) -> DateInterval {
        let calendar = Calendar.current
        let component: Calendar.Component = switch store.range.granularity {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        return calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }
}

struct ActivityChart: View {
    private enum ScrollEdge {
        case older
        case newer
    }

    let periods: [PeriodMetric]
    let granularity: PeriodGranularity
    let title: String
    let subtitle: String?
    let showsMetricPicker: Bool
    let allowsPeriodSelection: Bool
    @Binding var selectedPeriodStart: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var metric: String
    @State private var hoveredPeriod: PeriodMetric?
    @State private var hoveredScrollEdge: ScrollEdge?
    @State private var scrollPosition = 0.0
    @State private var dragStartScrollPosition: Double?

    init(
        periods: [PeriodMetric],
        granularity: PeriodGranularity,
        title: String = "Activity trend",
        subtitle: String? = nil,
        initialMetric: String = "Tokens",
        showsMetricPicker: Bool = true,
        allowsPeriodSelection: Bool = true,
        metric: Binding<String>? = nil,
        selectedPeriodStart: Binding<Date?> = .constant(nil)
    ) {
        self.periods = periods
        self.granularity = granularity
        self.title = title
        self.subtitle = subtitle
        self.showsMetricPicker = showsMetricPicker
        self.allowsPeriodSelection = allowsPeriodSelection
        _metric = metric ?? .constant(initialMetric)
        _selectedPeriodStart = selectedPeriodStart
    }

    private var visiblePeriodCount: Double { Double(min(30, max(1, periods.count))) }
    private var latestScrollPosition: Double { max(0, Double(periods.count) - visiblePeriodCount) }
    private var canScroll: Bool { Double(periods.count) > visiblePeriodCount }
    private var axisPositions: [Double] {
        let step = max(1, Int(ceil(visiblePeriodCount / 8)))
        var positions = stride(from: 0, to: periods.count, by: step).map { Double($0) + 0.5 }
        if !periods.isEmpty {
            positions.append(Double(periods.count) - 0.5)
        }
        return Array(Set(positions)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeader(
                    title: title,
                    subtitle: subtitle ?? "\(granularityLabel) totals across available history. Drag, swipe, or use the edge arrows to move through time.",
                    definition: .periodUsage
                )
                if showsMetricPicker {
                    Picker("Chart metric", selection: $metric) {
                        Label("Tokens", systemImage: "text.word.spacing")
                            .labelStyle(.iconOnly)
                            .tag("Tokens")
                            .help("Tokens")
                        Label("Runtime", systemImage: "clock.fill")
                            .labelStyle(.iconOnly)
                            .tag("Runtime")
                            .help("Runtime")
                        Label("Cost", systemImage: "dollarsign")
                            .labelStyle(.iconOnly)
                            .tag("Cost")
                            .help("Cost")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 138)
                    .accessibilityLabel("Chart metric")
                }
            }
            Chart(Array(periods.enumerated()), id: \.offset) { item in
                RectangleMark(
                    xStart: .value("Period start", Double(item.offset) + 0.06),
                    xEnd: .value("Period end", Double(item.offset) + 0.94),
                    yStart: .value("Baseline", 0),
                    yEnd: .value(metric, metricValue(item.element))
                )
                .foregroundStyle(metricColor.gradient)
                .cornerRadius(3)
                if metricValue(item.element) == 0 && hasActivity(item.element) {
                    PointMark(
                        x: .value("Period with activity", Double(item.offset) + 0.5),
                        y: .value("Zero value", 0)
                    )
                    .symbol {
                        Capsule()
                            .fill(metricColor.opacity(0.78))
                            .frame(width: 22, height: 5)
                    }
                    .accessibilityLabel("Activity recorded, but \(metric.lowercased()) is zero")
                }
                if hoveredPeriod?.id == item.element.id || selectedPeriodStart == item.element.start {
                    RuleMark(x: .value("Selected period", Double(item.offset) + 0.5))
                        .lineStyle(.init(lineWidth: selectedPeriodStart == item.element.start ? 1.5 : 1, dash: [4, 4]))
                        .foregroundStyle(selectedPeriodStart == item.element.start ? metricColor.opacity(0.8) : .secondary.opacity(0.7))
                    PointMark(x: .value("Selected period", Double(item.offset) + 0.5), y: .value("Selected value", metricValue(item.element)))
                        .symbolSize(70)
                        .foregroundStyle(metricColor)
                    PointMark(x: .value("Selected period", Double(item.offset) + 0.5), y: .value("Selected value", metricValue(item.element)))
                        .symbolSize(22)
                        .foregroundStyle(.background)
                        .annotation(
                            position: .top,
                            alignment: annotationAlignment(for: item.offset),
                            spacing: 10,
                            overflowResolution: .init(
                                x: .fit(to: .chart),
                                y: .fit(to: .chart)
                            )
                        ) {
                            if hoveredPeriod?.id == item.element.id { hoverCard(item.element) }
                        }
                }
            }
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: visiblePeriodCount)
            .chartScrollPosition(x: $scrollPosition)
            .chartXScale(range: .plotDimension(startPadding: 30, endPadding: 34))
            .chartXAxis {
                AxisMarks(values: axisPositions) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let position = value.as(Double.self) {
                            let index = Int(floor(position))
                            if periods.indices.contains(index) {
                                Text(axisPeriodLabel(periods[index].start))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(axisLabel(number)).monospacedDigit()
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame else { return }
                                let frame = geometry[plotFrame]
                                let x = location.x - frame.minX
                                guard x >= 0, x <= frame.width,
                                      let rawIndex: Double = proxy.value(atX: x) else {
                                    hoveredPeriod = nil
                                    return
                                }
                                let index = Int(floor(rawIndex))
                                let nearest = periods.indices.contains(index) ? periods[index] : nil
                                if hoveredPeriod?.id != nearest?.id { hoveredPeriod = nearest }
                            case .ended:
                                hoveredPeriod = nil
                            }
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    guard canScroll, let plotFrame = proxy.plotFrame else { return }
                                    let frame = geometry[plotFrame]
                                    guard frame.width > 0 else { return }
                                    if dragStartScrollPosition == nil {
                                        dragStartScrollPosition = scrollPosition
                                    }
                                    let translatedPeriods = Double(value.translation.width / frame.width) * visiblePeriodCount
                                    let proposed = (dragStartScrollPosition ?? scrollPosition) - translatedPeriods
                                    scrollPosition = min(latestScrollPosition, max(0, proposed))
                                    hoveredPeriod = nil
                                }
                                .onEnded { _ in
                                    dragStartScrollPosition = nil
                                }
                        )
                        .simultaneousGesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    guard allowsPeriodSelection else { return }
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let frame = geometry[plotFrame]
                                    let x = value.location.x - frame.minX
                                    guard x >= 0, x <= frame.width,
                                          let rawIndex: Double = proxy.value(atX: x) else { return }
                                    let index = Int(floor(rawIndex))
                                    guard periods.indices.contains(index) else { return }
                                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                                        selectedPeriodStart = periods[index].start
                                    }
                                }
                        )
                }
            }
            .frame(height: 220)
            .overlay {
                if canScroll {
                    HStack(spacing: 0) {
                        edgeScrollControl(.older)
                        Spacer(minLength: 0)
                        edgeScrollControl(.newer)
                    }
                }
            }
            .onAppear { scrollPosition = latestScrollPosition }
            .onChange(of: periods.map(\.id)) { _, _ in
                hoveredPeriod = nil
                scrollPosition = latestScrollPosition
            }
            .accessibilityHint(allowsPeriodSelection
                ? "Click a bar to show that period in the activity cards"
                : "Drag, swipe, or use the edge arrows to move through time")
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func scroll(by amount: Double) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            scrollPosition = min(latestScrollPosition, max(0, scrollPosition + amount))
        }
    }

    @ViewBuilder private func edgeScrollControl(_ edge: ScrollEdge) -> some View {
        let canMove = edge == .older
            ? scrollPosition > 0
            : scrollPosition < latestScrollPosition

        if canMove {
            Button { scroll(by: edge == .older ? -15 : 15) } label: {
                Image(systemName: edge == .older ? "chevron.left" : "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 44)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(.separator.opacity(0.6), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
            }
            .buttonStyle(.plain)
            .help(edge == .older ? "Show older activity" : "Show newer activity")
            .accessibilityLabel(edge == .older ? "Show older activity" : "Show newer activity")
            .opacity(hoveredScrollEdge == edge ? 1 : 0.48)
            .scaleEffect(hoveredScrollEdge == edge ? 1 : 0.9)
            .offset(x: hoveredScrollEdge == edge ? 0 : (edge == .older ? -8 : 8))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: hoveredScrollEdge)
            .onHover { isHovering in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    if isHovering {
                        hoveredScrollEdge = edge
                    } else if hoveredScrollEdge == edge {
                        hoveredScrollEdge = nil
                    }
                }
            }
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private var granularityLabel: String {
        switch granularity {
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        case .year: "Yearly"
        }
    }

    private func annotationAlignment(for index: Int) -> Alignment {
        let positionInViewport = Double(index) - scrollPosition
        if positionInViewport < 3 { return .leading }
        if positionInViewport > visiblePeriodCount - 4 { return .trailing }
        return .center
    }

    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case "Runtime": return value.formatted(.number.precision(.fractionLength(0...1))) + "h"
        case "Cost": return Decimal(value).formatted(.currency(code: "USD").precision(.fractionLength(0...1)))
        default: return MetricFormatters.compactNumber(Int64(max(0, value)))
        }
    }

    private var metricColor: Color {
        switch metric {
        case "Runtime": .orange
        case "Cost": .green
        default: .blue
        }
    }

    private func metricValue(_ period: PeriodMetric) -> Double {
        switch metric {
        case "Runtime": period.activeRuntime / 3_600
        case "Cost": period.estimatedCost.doubleValue
        default: Double(period.usage.total)
        }
    }

    private func hasActivity(_ period: PeriodMetric) -> Bool {
        period.sessions > 0 || period.usage.total > 0 || period.activeRuntime > 0 || period.estimatedCost > 0
    }

    private func hoverCard(_ period: PeriodMetric) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(periodLabel(period.start)).font(.caption.weight(.semibold))
            HStack(spacing: 14) {
                hoverMetric(
                    MetricFormatters.compactNumber(period.usage.total),
                    icon: "text.word.spacing",
                    accessibilityLabel: "Tokens"
                )
                hoverMetric(
                    preciseDuration(period.activeRuntime),
                    icon: "clock",
                    accessibilityLabel: "Runtime"
                )
                Text(MetricFormatters.currency(period.estimatedCost))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Estimated cost \(MetricFormatters.currency(period.estimatedCost))")
            }
            .font(.caption2.monospacedDigit())
            .fixedSize(horizontal: true, vertical: false)
            Text("\(period.sessions) session\(period.sessions == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 230, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.55)))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }

    private func hoverMetric(_ value: String, icon: String, accessibilityLabel: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .frame(width: 13)
            Text(value)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityLabel) \(value)")
    }

    private func periodLabel(_ date: Date) -> String {
        switch granularity {
        case .day: date.formatted(date: .abbreviated, time: .omitted)
        case .week: "Week of \(date.formatted(date: .abbreviated, time: .omitted))"
        case .month: date.formatted(.dateTime.year().month(.wide))
        case .year: date.formatted(.dateTime.year())
        }
    }

    private func axisPeriodLabel(_ date: Date) -> String {
        switch granularity {
        case .day, .week: date.formatted(.dateTime.month(.abbreviated).day())
        case .month: date.formatted(.dateTime.year().month(.abbreviated))
        case .year: date.formatted(.dateTime.year())
        }
    }

    private func preciseDuration(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "0s" }
        let seconds = Int(interval.rounded())
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if days > 0 { return String(format: "%dd %02dh %02dm", days, hours, minutes) }
        if hours > 0 { return String(format: "%dh %02dm %02ds", hours, minutes, remainder) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, remainder) }
        return "\(remainder)s"
    }
}

struct TopProjectsView: View {
    let projects: [ProjectMetric]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Top projects", subtitle: "By token volume")
            ForEach(projects.sorted { $0.usage.total > $1.usage.total }) { project in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(project.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text("\(project.sessionCount) sessions · \(MetricFormatters.duration(project.activeRuntime))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(MetricFormatters.compactNumber(project.usage.total)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ModelMixView: View {
    let models: [ModelMetric]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Model mix", subtitle: "Tokens by model")
            Chart(models) { model in
                BarMark(x: .value("Tokens", model.usage.total), y: .value("Model", model.model))
                    .foregroundStyle(by: .value("Model", model.model))
            }
            .chartLegend(.hidden)
            .frame(height: 250)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ToolOverviewView: View {
    let tools: [ToolMetric]
    let totalCalls: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Tool economics",
                subtitle: "Most-used tools with frequency and attributed model-token cost.",
                definition: .toolAttribution
            )
            if tools.isEmpty {
                Text(totalCalls > 0 ? "Tool names will appear as sessions are re-enriched." : "No tool calls in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        Text("TOOL")
                        Text("CALLS").gridColumnAlignment(.trailing)
                        Text("FREQUENCY").gridColumnAlignment(.leading)
                        Text("ATTRIBUTED COST").gridColumnAlignment(.trailing)
                    }
                    .font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
                    ForEach(tools) { tool in
                        GridRow {
                            Text(tool.tool).font(.subheadline.monospaced()).lineLimit(1)
                            Text(tool.calls.formatted()).monospacedDigit()
                            MetricProgressBar(value: Double(tool.calls), total: Double(max(1, totalCalls)))
                                .frame(minWidth: 120)
                            Text(MetricFormatters.preciseCurrency(tool.estimatedCost)).monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct SkillOverviewView: View {
    let skills: [SkillMetric]
    let totalCalls: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Skill economics",
                subtitle: "Explicit skill activations with frequency and attributed model-token cost.",
                definition: .skillAttribution
            )
            if skills.isEmpty {
                Text("No explicit SKILL.md reads were detected in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        Text("SKILL")
                        Text("ACTIVATIONS").gridColumnAlignment(.trailing)
                        Text("FREQUENCY").gridColumnAlignment(.leading)
                        Text("ATTRIBUTED COST").gridColumnAlignment(.trailing)
                    }
                    .font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
                    ForEach(skills) { skill in
                        GridRow {
                            Text(skill.skill).font(.subheadline.monospaced()).lineLimit(1)
                            Text(skill.calls.formatted()).monospacedDigit()
                            MetricProgressBar(value: Double(skill.calls), total: Double(max(1, totalCalls)))
                                .frame(minWidth: 120)
                            Text(MetricFormatters.preciseCurrency(skill.estimatedCost)).monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private enum ProjectTreeSelection: Hashable {
    case project(String)
    case session(String)
}

struct ProjectsView: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("projectActivityMetric") private var activityMetric = "Tokens"
    @State private var expandedProjects = Set<String>()
    @State private var selection: ProjectTreeSelection?
    @State private var searchText = ""

    private var visibleProjects: [ProjectMetric] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.allProjects }
        return store.allProjects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HSplitView {
            projectTree
                .frame(minWidth: 310, idealWidth: 390, maxWidth: 500)
            selectedDetail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Projects")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search projects")
        .onAppear { selectInitialProject() }
        .onChange(of: store.allProjects.map(\.id)) { _, _ in selectInitialProject() }
    }

    private var projectTree: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(visibleProjects) { project in
                    VStack(spacing: 3) {
                        HStack(spacing: 7) {
                            Button { toggle(project.id) } label: {
                                Image(systemName: expandedProjects.contains(project.id) ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 16, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(expandedProjects.contains(project.id) ? "Collapse \(project.name)" : "Expand \(project.name)")

                            Button { selection = .project(project.id) } label: {
                                ProjectTreeRow(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(selection == .project(project.id) ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 9))

                        if expandedProjects.contains(project.id) {
                            LazyVStack(spacing: 2) {
                                ForEach(project.sessions.sorted { $0.updatedAt > $1.updatedAt }) { session in
                                    Button { selection = .session(session.id) } label: {
                                        SessionTreeRow(session: session)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.leading, 31)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 3)
                                    .background(selection == .session(session.id) ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(.background.secondary)
        .overlay(alignment: .top) {
            if store.allProjects.isEmpty {
                ContentUnavailableView(
                    "No projects",
                    systemImage: "folder",
                    description: Text("No Codex projects or sessions are available yet.")
                )
            } else if visibleProjects.isEmpty {
                ContentUnavailableView(
                    "No matching projects",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different project name.")
                )
            }
        }
    }

    @ViewBuilder private var selectedDetail: some View {
        switch selection {
        case .project(let path):
            if let project = store.allProjects.first(where: { $0.path == path }) {
                let rangedSessions = store.filteredSessions.filter { $0.projectPath == path }
                ProjectDetailView(
                    project: project,
                    rangedSessions: rangedSessions,
                    rangeLabel: "All time",
                    granularity: store.range.granularity,
                    pricing: store.pricing,
                    indexed: store.projectAggregate(path: path),
                    periods: store.projectPeriods(path: path, granularity: store.range.granularity),
                    activityMetric: $activityMetric,
                    sessionIndexes: Dictionary(uniqueKeysWithValues: project.sessions.compactMap { session in
                        store.indexedSession(session.id).map { (session.id, $0) }
                    })
                ) { session in
                    expandedProjects.insert(project.id)
                    selection = .session(session.id)
                }
            } else { selectionPlaceholder }
        case .session(let id):
            SessionDetailLoaderView(sessionID: id)
        case nil:
            selectionPlaceholder
        }
    }

    private var selectionPlaceholder: some View {
        ContentUnavailableView("Select a project", systemImage: "folder", description: Text("Expand a project to browse the sessions that belong to it."))
    }

    private func toggle(_ projectID: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            if expandedProjects.contains(projectID) { expandedProjects.remove(projectID) }
            else { expandedProjects.insert(projectID) }
        }
    }

    private func selectInitialProject() {
        guard selection == nil, let first = store.allProjects.first else { return }
        selection = .project(first.id)
        expandedProjects.insert(first.id)
    }
}

private struct SessionDetailLoaderView: View {
    @EnvironmentObject private var store: DashboardStore
    let sessionID: String
    @State private var session: SessionMetric?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let session {
                SessionDetailView(session: session, pricing: store.pricing)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading session…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Session Not Found", systemImage: "bubble.left.and.text.bubble.right", description: Text("The selected session could not be retrieved from history."))
            }
        }
        .task(id: sessionID) {
            isLoading = true
            session = try? await store.sessionMetric(withID: sessionID)
            isLoading = false
        }
    }
}

private struct ProjectTreeRow: View {
    let project: ProjectMetric
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(project.sessionCount) sessions · \(MetricFormatters.compactNumber(project.usage.total)) tokens · \((project.usage.cacheHitRate * 100).formatted(.number.precision(.fractionLength(1))))% cache hit")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(project.lastActivity, style: .relative).font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct SessionTreeRow: View {
    let session: SessionSummary
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle).font(.subheadline).lineLimit(1)
                Text("\(session.model ?? "Unknown") · \(MetricFormatters.compactNumber(session.usage.total)) tokens · \((session.usage.cacheHitRate * 100).formatted(.number.precision(.fractionLength(1))))% cache hit")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(session.updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct ProjectDetailView: View {
    let project: ProjectMetric
    let rangedSessions: [SessionSummary]
    let rangeLabel: String
    let granularity: PeriodGranularity
    let pricing: PricingHistory
    let indexed: MetricsIndexAggregate
    let periods: [PeriodMetric]
    @Binding var activityMetric: String
    let sessionIndexes: [String: IndexedSessionMetrics]
    let onSelectSession: (SessionSummary) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(project.name, systemImage: "folder.fill").font(.largeTitle.weight(.semibold))
                    Text(project.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    MetricCard(title: "Sessions", value: project.sessionCount.formatted(), detail: "\(rangedSessions.count) in \(rangeLabel)", icon: "bubble.left.and.text.bubble.right.fill", tint: .blue)
                    MetricCard(title: "Tokens", value: MetricFormatters.compactNumber(indexed.usage.total), detail: "\((indexed.usage.cacheHitRate * 100).formatted(.number.precision(.fractionLength(1))))% cached · \(rangeLabel)", icon: "text.word.spacing", tint: .purple, definition: .totalTokens)
                    MetricCard(title: "Cache hit rate", value: indexed.usage.cacheHitRate.formatted(.percent.precision(.fractionLength(1))), detail: "Cached input / total input · \(rangeLabel)", icon: "arrow.triangle.2.circlepath", tint: .teal, definition: .cacheHitRate)
                    MetricCard(title: "Agent runtime", value: MetricFormatters.duration(indexed.activeRuntime), detail: "Completed turns · \(rangeLabel)", icon: "clock.fill", tint: .orange, definition: .agentRuntime)
                    MetricCard(title: "Equivalent cost", value: indexed.costCoverage > 0 ? MetricFormatters.currency(indexed.estimatedCost) : "—", detail: "\((indexed.costCoverage * 100).formatted(.number.precision(.fractionLength(0))))% coverage · \(rangeLabel)", icon: "dollarsign", tint: .green, definition: .estimatedCost)
                    ToolCallsMetricCard(calls: indexed.toolCalls, tools: indexed.tools, detail: "\(indexed.tools.count) tools · \(rangeLabel)")
                    SkillCallsMetricCard(calls: indexed.skillCalls, skills: indexed.skills, detail: "\(indexed.skills.count) skills · \(rangeLabel)")
                }
                ActivityChart(periods: periods, granularity: granularity, metric: $activityMetric)
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Recent sessions", subtitle: "Sessions stay scoped to this project.")
                    ForEach(project.sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(8)) { session in
                        Button { onSelectSession(session) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(session.model ?? "Unknown") · \(session.completedTurns) turns · \(MetricFormatters.duration(session.activeRuntime))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(MetricFormatters.compactNumber(session.usage.total)).monospacedDigit()
                                    Text(session.usage.cacheHitRate.formatted(.percent.precision(.fractionLength(1))) + " cache hit")
                                        .font(.caption).foregroundStyle(.teal).monospacedDigit()
                                    let sessionCost = sessionIndexes[session.id]?.estimatedCost
                                        ?? (pricing.estimate(usage: session.usage, model: session.model, on: session.updatedAt) ?? 0)
                                    let sessionCoverage = sessionIndexes[session.id].map { indexed in
                                        indexed.usage.total > 0 ? Double(indexed.coveredTokens) / Double(indexed.usage.total) : 0
                                    } ?? (pricing.price(for: session.model, on: session.updatedAt) != nil ? 1.0 : 0.0)
                                    Text(sessionCoverage > 0 ? MetricFormatters.preciseCurrency(sessionCost) : "Cost —")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(11).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(26)
        }
    }
}

private struct SessionDetailView: View {
    let session: SessionMetric
    let pricing: PricingHistory
    @Environment(\.openWindow) private var openWindow
    private var cost: Decimal { Analytics.totalEstimatedCost([session], pricing: pricing) }
    private var coverage: Double { Analytics.costCoverage([session], pricing: pricing) }
    private var tools: [ToolMetric] { Analytics.tools(from: [session], pricing: pricing) }
    private var skills: [SkillMetric] { Analytics.skills(from: [session], pricing: pricing) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(session.displayTitle, systemImage: "bubble.left.and.text.bubble.right.fill")
                            .font(.title.weight(.semibold)).lineLimit(2)
                        Label(session.projectName, systemImage: "folder.fill").font(.subheadline.weight(.medium)).foregroundStyle(.blue)
                        Text(session.projectPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        openWindow(value: ConversationWindowRequest(
                            rolloutPath: session.rolloutPath,
                            sessionTitle: session.displayTitle,
                            projectName: session.projectName
                        ))
                    } label: {
                        Label("Debug Conversation", systemImage: "waveform.path.ecg.text")
                    }
                    .buttonStyle(.bordered)
                    .help("Open sent and received conversation events in a separate window")
                    .disabled(session.rolloutPath.isEmpty)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    MetricCard(title: "Tokens", value: MetricFormatters.compactNumber(session.usage.total), detail: "\(MetricFormatters.compactNumber(session.usage.output)) output", icon: "text.word.spacing", tint: .purple, definition: .totalTokens)
                    MetricCard(title: "Agent runtime", value: MetricFormatters.duration(session.activeRuntime), detail: "\(session.completedTurns) completed turns", icon: "clock.fill", tint: .orange, definition: .agentRuntime)
                    MetricCard(title: "Session span", value: MetricFormatters.duration(session.sessionSpan), detail: "Includes idle gaps", icon: "calendar.badge.clock", tint: .blue, definition: .sessionSpan)
                    MetricCard(title: "First token", value: session.averageTTFT.map(MetricFormatters.duration) ?? "—", detail: "Average startup latency", icon: "bolt.fill", tint: .yellow, definition: .firstTokenLatency)
                    MetricCard(title: "Equivalent cost", value: coverage > 0 ? MetricFormatters.preciseCurrency(cost) : "—", detail: "\((coverage * 100).formatted(.number.precision(.fractionLength(0))))% token coverage", icon: "dollarsign", tint: .green, definition: .estimatedCost)
                    ToolCallsMetricCard(calls: session.toolCalls, tools: tools, detail: "\(tools.count) tools · click for cost")
                    SkillCallsMetricCard(calls: session.skillCallEvents?.count ?? 0, skills: skills, detail: "\(skills.count) skills · click for cost")
                }
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Token composition", subtitle: "Input is split into uncached, cached, and cache-write tokens; reasoning is a subset of output.", definition: .tokenComposition)
                    TokenCompositionView(usage: session.usage)
                }
                .padding(18).background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 11) {
                    metadata("Model", session.model ?? "Unknown")
                    metadata("Reasoning effort", session.reasoningEffort ?? "Unknown")
                    metadata("Source", session.displaySource)
                    metadata("Git branch", session.gitBranch ?? "—")
                    metadata("Aborted turns", session.abortedTurns.formatted())
                    metadata("Created", session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    metadata("Updated", session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .padding(26)
        }
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

}

private struct TokenCompositionSegment: Identifiable {
    let id: String
    let title: String
    let value: Int64
    let color: Color
}

private struct TokenCompositionView: View {
    let usage: TokenUsage

    private var inputSegments: [TokenCompositionSegment] {
        [
            .init(id: "uncached", title: "Uncached", value: usage.uncachedInput, color: .blue),
            .init(id: "cached", title: "Cached", value: usage.cachedInput, color: .cyan),
            .init(id: "cache-write", title: "Cache write", value: usage.cacheWriteInput, color: .orange)
        ]
    }

    private var outputSegments: [TokenCompositionSegment] {
        [
            .init(id: "output", title: "Output", value: usage.output, color: .purple),
            .init(id: "reasoning", title: "Reasoning", value: usage.reasoningOutput, color: .pink)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TokenCompositionGroup(
                title: "INPUT",
                total: usage.input,
                grandTotal: usage.total,
                segments: inputSegments,
                showsNestedLegend: false
            )
            TokenCompositionGroup(
                title: "OUTPUT",
                total: usage.output,
                grandTotal: usage.total,
                segments: outputSegments,
                showsNestedLegend: true
            )
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TokenCompositionGroup: View {
    let title: String
    let total: Int64
    let grandTotal: Int64
    let segments: [TokenCompositionSegment]
    let showsNestedLegend: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(MetricFormatters.compactNumber(total)) tokens · \(percentage(total, of: grandTotal)) of total")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if showsNestedLegend {
                NestedTokenBar(total: total, nested: segments.last?.value ?? 0, baseColor: segments.first?.color ?? .purple, nestedColor: segments.last?.color ?? .pink)
                TokenNestedLegend(segment: segments.last ?? .init(id: "reasoning", title: "Reasoning", value: 0, color: .pink), percentage: fraction(segments.last?.value ?? 0, of: total))
            } else {
                SegmentedTokenBar(segments: segments, total: total)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: segments.count),
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(segments) { segment in
                        TokenCompositionLegend(segment: segment, percentage: fraction(segment.value, of: total))
                    }
                }
            }
        }
    }

    private func percentage(_ value: Int64, of denominator: Int64) -> String {
        guard denominator > 0 else { return "—" }
        return (Double(value) / Double(denominator)).formatted(.percent.precision(.fractionLength(1)))
    }

    private func fraction(_ value: Int64, of denominator: Int64) -> Double {
        guard denominator > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(denominator)))
    }
}

private struct SegmentedTokenBar: View {
    let segments: [TokenCompositionSegment]
    let total: Int64

    var body: some View {
        GeometryReader { proxy in
            let gap = CGFloat(max(0, segments.count - 1))
            let availableWidth = max(0, proxy.size.width - gap)
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(segment.color.gradient)
                        .frame(width: availableWidth * fraction(segment.value), height: 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 28)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.separator.opacity(0.38)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Segmented token bar")
        .accessibilityValue(segments.map { "\($0.title) \($0.value)" }.joined(separator: ", "))
    }

    private func fraction(_ value: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(total)))
    }
}

private struct NestedTokenBar: View {
    let total: Int64
    let nested: Int64
    let baseColor: Color
    let nestedColor: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(baseColor.gradient)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(nestedColor.gradient)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 28)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.separator.opacity(0.38)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Output bar with reasoning subset")
        .accessibilityValue("Output \(total) tokens, reasoning \(nested) tokens")
    }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(nested) / Double(total)))
    }
}

private struct TokenNestedLegend: View {
    let segment: TokenCompositionSegment
    let percentage: Double

    var body: some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(segment.color.opacity(0.55))
                .frame(width: 18, height: 1)
            Circle()
                .fill(segment.color)
                .frame(width: 7, height: 7)
            Text("\(segment.title): \(MetricFormatters.compactNumber(segment.value)) · \(percentage.formatted(.percent.precision(.fractionLength(1)))) output")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle()
                .fill(segment.color.opacity(0.55))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TokenCompositionLegend: View {
    let segment: TokenCompositionSegment
    let percentage: Double

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(segment.color)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(MetricFormatters.compactNumber(segment.value)) · \(percentage.formatted(.percent.precision(.fractionLength(1))))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ModelTrendChartData {
    struct Sample: Identifiable {
        let id: String
        let index: Int
        let model: String
        let modelIndex: Int
        let tokens: Double
        let cacheRate: Double
        let cacheHitRate: Double
        let tokenSeries: String
        let cacheSeries: String
    }

    let dates: [Date]
    let samples: [Sample]
    let maximumTokens: Double
    let identity: String

    init(points: [ModelPeriodMetric], models: [ModelMetric]) {
        let preparedDates = Array(Set(points.map(\.start))).sorted()
        let pointsByModel = Dictionary(grouping: points, by: \.model).mapValues { values in
            Dictionary(uniqueKeysWithValues: values.map { ($0.start, $0) })
        }
        let preparedMaximumTokens = max(1, points
            .filter { point in models.contains { $0.model == point.model } }
            .map { max(0, Double($0.usage.total)) }
            .max() ?? 1)
        let preparedSamples = preparedDates.enumerated().flatMap { dateItem in
            models.enumerated().map { modelItem in
                let point = pointsByModel[modelItem.element.model]?[dateItem.element]
                let usage = point?.usage ?? .zero
                let cacheHitRate = min(1, max(0, usage.cacheHitRate))
                return Sample(
                    id: "\(modelItem.element.model)-\(dateItem.offset)",
                    index: dateItem.offset,
                    model: modelItem.element.model,
                    modelIndex: modelItem.offset,
                    tokens: max(0, Double(usage.total)),
                    cacheRate: cacheHitRate * preparedMaximumTokens,
                    cacheHitRate: cacheHitRate,
                    tokenSeries: "\(modelItem.element.model) · tokens",
                    cacheSeries: "\(modelItem.element.model) · cache"
                )
            }
        }
        dates = preparedDates
        samples = preparedSamples
        maximumTokens = preparedMaximumTokens
        identity = models.map(\.model).joined(separator: "|") + "#" + preparedDates.map(String.init(describing:)).joined(separator: "|")
    }
}

private struct ModelTrendChart: View {
    private enum ScrollEdge {
        case older
        case newer
    }

    let data: ModelTrendChartData
    let models: [ModelMetric]
    let granularity: PeriodGranularity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredScrollEdge: ScrollEdge?
    @State private var hoveredIndex: Int?
    @State private var hoverLocation: CGPoint?
    @State private var scrollPosition = 0.0
    @State private var dragStartScrollPosition: Double?

    private var dates: [Date] {
        data.dates
    }

    private var visiblePeriodCount: Double { Double(min(30, max(1, dates.count))) }
    private var latestScrollPosition: Double { max(0, Double(dates.count) - visiblePeriodCount) }
    private var canScroll: Bool { Double(dates.count) > visiblePeriodCount }
    private var axisPositions: [Double] {
        let step = max(1, Int(ceil(visiblePeriodCount / 8)))
        var positions = stride(from: 0, to: dates.count, by: step).map { Double($0) + 0.5 }
        if !dates.isEmpty { positions.append(Double(dates.count) - 0.5) }
        return Array(Set(positions)).sorted()
    }

    private var samples: [ModelTrendChartData.Sample] {
        data.samples
    }

    private var maximumTokens: Double {
        data.maximumTokens
    }

    private var cacheAxisPositions: [Double] {
        stride(from: 0, through: 1, by: 0.25).map { $0 * maximumTokens }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Model trend",
                subtitle: "Same models as the summary table. Drag, swipe, or use the edge arrows to move through " + granularityLabel.lowercased() + " history.",
                definition: .periodUsage
            )

            if dates.isEmpty || models.isEmpty {
                Text("No model trend data is available yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                legend
                Chart {
                    ForEach(samples) { sample in
                        tokenMark(for: sample)
                        cacheMark(for: sample)
                        tokenPointMark(for: sample)
                        cachePointMark(for: sample)
                    }
                    if let hoveredIndex, dates.indices.contains(hoveredIndex) {
                        RuleMark(x: .value("Hovered period", Double(hoveredIndex)))
                            .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary.opacity(0.72))
                    }
                }
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visiblePeriodCount)
                .chartScrollPosition(x: $scrollPosition)
                .chartXScale(range: .plotDimension(startPadding: 20, endPadding: 24))
                .chartYScale(domain: 0...maximumTokens)
                .chartXAxis {
                    AxisMarks(values: axisPositions) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                        AxisValueLabel {
                            if let position = value.as(Double.self), let label = axisLabel(at: position) {
                                Text(label)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(MetricFormatters.compactNumber(Int64(max(0, number))))
                                    .monospacedDigit()
                            }
                        }
                    }
                    AxisMarks(position: .trailing, values: cacheAxisPositions) { value in
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(cacheAxisLabel(number))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let frame = geometry[plotFrame]
                                        let x = location.x - frame.minX
                                        guard x >= 0, x <= frame.width,
                                              let rawIndex: Double = proxy.value(atX: x) else {
                                            hoveredIndex = nil
                                            hoverLocation = nil
                                            return
                                        }
                                        let index = min(max(0, Int(rawIndex.rounded())), dates.count - 1)
                                        hoveredIndex = index
                                        hoverLocation = location
                                    case .ended:
                                        hoveredIndex = nil
                                        hoverLocation = nil
                                    }
                                }
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 2)
                                        .onChanged { value in
                                            guard canScroll, let plotFrame = proxy.plotFrame else { return }
                                            let frame = geometry[plotFrame]
                                            guard frame.width > 0 else { return }
                                            if dragStartScrollPosition == nil {
                                                dragStartScrollPosition = scrollPosition
                                            }
                                            let translatedPeriods = Double(value.translation.width / frame.width) * visiblePeriodCount
                                            let proposed = (dragStartScrollPosition ?? scrollPosition) - translatedPeriods
                                            scrollPosition = min(latestScrollPosition, max(0, proposed))
                                            hoveredIndex = nil
                                            hoverLocation = nil
                                        }
                                        .onEnded { _ in
                                            dragStartScrollPosition = nil
                                        }
                                )

                            if let hoveredIndex, let hoverLocation {
                                hoverCard(for: hoveredIndex)
                                    .position(hoverCardPosition(for: hoverLocation, in: geometry.size))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: 320)
                .overlay {
                    if canScroll {
                        HStack(spacing: 0) {
                            edgeScrollControl(.older)
                            Spacer(minLength: 0)
                            edgeScrollControl(.newer)
                        }
                    }
                }
                .onAppear {
                    scrollPosition = latestScrollPosition
                }
                .onChange(of: data.identity) { _, _ in
                    hoveredIndex = nil
                    hoverLocation = nil
                    scrollPosition = latestScrollPosition
                }
                .onChange(of: granularity) { _, _ in
                    hoveredIndex = nil
                    hoverLocation = nil
                    scrollPosition = latestScrollPosition
                }
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    HStack(spacing: 6) {
                        Circle().fill(seriesColor(index)).frame(width: 7, height: 7)
                        Text(model.model)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 6) {
                Capsule().fill(.primary.opacity(0.72)).frame(width: 18, height: 2)
                Text("Tokens").font(.caption2).foregroundStyle(.secondary)
                Capsule().fill(.secondary.opacity(0.72)).frame(width: 18, height: 2)
                Text("Cache hit").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scroll(by amount: Double) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            scrollPosition = min(latestScrollPosition, max(0, scrollPosition + amount))
        }
    }

    @ViewBuilder private func edgeScrollControl(_ edge: ScrollEdge) -> some View {
        let canMove = edge == .older
            ? scrollPosition > 0
            : scrollPosition < latestScrollPosition

        if canMove {
            Button { scroll(by: edge == .older ? -15 : 15) } label: {
                Image(systemName: edge == .older ? "chevron.left" : "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 44)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(.separator.opacity(0.6), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
            }
            .buttonStyle(.plain)
            .help(edge == .older ? "Show older model trend" : "Show newer model trend")
            .accessibilityLabel(edge == .older ? "Show older model trend" : "Show newer model trend")
            .opacity(hoveredScrollEdge == edge ? 1 : 0.48)
            .scaleEffect(hoveredScrollEdge == edge ? 1 : 0.9)
            .offset(x: hoveredScrollEdge == edge ? 0 : (edge == .older ? -8 : 8))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: hoveredScrollEdge)
            .onHover { isHovering in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    if isHovering {
                        hoveredScrollEdge = edge
                    } else if hoveredScrollEdge == edge {
                        hoveredScrollEdge = nil
                    }
                }
            }
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private func tokenMark(for sample: ModelTrendChartData.Sample) -> some ChartContent {
        LineMark(
            x: .value("Period", Double(sample.index)),
            y: .value("Tokens", sample.tokens),
            series: .value("Series", sample.tokenSeries)
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(seriesColor(sample.modelIndex))
        .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func cacheMark(for sample: ModelTrendChartData.Sample) -> some ChartContent {
        LineMark(
            x: .value("Period", Double(sample.index)),
            y: .value("Cache hit rate", sample.cacheRate),
            series: .value("Series", sample.cacheSeries)
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(seriesColor(sample.modelIndex).opacity(0.52))
        .lineStyle(.init(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 4], dashPhase: 0))
    }

    private func tokenPointMark(for sample: ModelTrendChartData.Sample) -> some ChartContent {
        PointMark(
            x: .value("Period", Double(sample.index)),
            y: .value("Tokens", sample.tokens)
        )
        .foregroundStyle(seriesColor(sample.modelIndex))
        .symbolSize(34)
    }

    private func cachePointMark(for sample: ModelTrendChartData.Sample) -> some ChartContent {
        PointMark(
            x: .value("Period", Double(sample.index)),
            y: .value("Cache hit rate", sample.cacheRate)
        )
        .foregroundStyle(seriesColor(sample.modelIndex).opacity(0.68))
        .symbolSize(24)
    }

    private func hoverCard(for index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(axisPeriodLabel(dates[index]))
                .font(.caption.weight(.semibold))
            ForEach(samples.filter { $0.index == index }) { sample in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(seriesColor(sample.modelIndex))
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sample.model)
                            .font(.caption2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(MetricFormatters.compactNumber(Int64(max(0, sample.tokens)))) tokens · \(sample.cacheHitRate.formatted(.percent.precision(.fractionLength(1)))) cache")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 270, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.55)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private func hoverCardPosition(for location: CGPoint, in size: CGSize) -> CGPoint {
        let horizontalOffset: CGFloat = location.x < size.width / 2 ? 165 : -165
        let verticalOffset: CGFloat = location.y < size.height / 2 ? 122 : -122
        return CGPoint(
            x: min(max(140, location.x + horizontalOffset), max(140, size.width - 140)),
            y: min(max(122, location.y + verticalOffset), max(122, size.height - 122))
        )
    }

    private func seriesColor(_ index: Int) -> Color {
        [.blue, .purple, .teal, .orange, .pink, .indigo][index % 6]
    }

    private func axisLabel(at position: Double) -> String? {
        let index = Int(floor(position))
        guard dates.indices.contains(index) else { return nil }
        return axisPeriodLabel(dates[index])
    }

    private func cacheAxisLabel(_ value: Double) -> String {
        let cachePercent = value / maximumTokens
        return cachePercent.formatted(.percent.precision(.fractionLength(0)))
    }

    private var granularityLabel: String {
        switch granularity {
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        case .year: "Yearly"
        }
    }

    private func axisPeriodLabel(_ date: Date) -> String {
        switch granularity {
        case .day, .week: date.formatted(.dateTime.month(.abbreviated).day())
        case .month: date.formatted(.dateTime.year().month(.abbreviated))
        case .year: date.formatted(.dateTime.year())
        }
    }
}

struct ModelsView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var modelPage = 0
    private let modelPageSize = 4

    private var modelPageCount: Int {
        max(1, Int(ceil(Double(store.allTimeModels.count) / Double(modelPageSize))))
    }

    private var visibleModels: [ModelMetric] {
        let safePage = min(modelPage, modelPageCount - 1)
        return Array(store.allTimeModels.dropFirst(safePage * modelPageSize).prefix(modelPageSize))
    }

    private var modelPageSummary: String {
        guard !store.allTimeModels.isEmpty else { return "0 models" }
        let safePage = min(modelPage, modelPageCount - 1)
        let start = safePage * modelPageSize
        let end = min(start + modelPageSize, store.allTimeModels.count)
        return "Models \(start + 1)–\(end) of \(store.allTimeModels.count)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ModelTrendChart(
                    data: ModelTrendChartData(points: store.modelTrendPeriods, models: visibleModels),
                    models: visibleModels,
                    granularity: store.range.granularity
                )
                SectionHeader(
                    title: "Model portfolio",
                    subtitle: "All-time aggregated totals for the same models shown in the trend above."
                )
                modelPager
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow {
                        Text("Model")
                        Text("Sessions")
                        MetricHelpLabel(title: "Tokens", definition: .totalTokens)
                        MetricHelpLabel(title: "Cache hit", definition: .cacheHitRate)
                        MetricHelpLabel(title: "Runtime", definition: .agentRuntime)
                        MetricHelpLabel(title: "Est. cost", definition: .estimatedCost)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellColumns(6)
                    ForEach(visibleModels) { model in
                        GridRow {
                            Text(model.model)
                                .fontWeight(.medium)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.sessions.formatted()).monospacedDigit()
                            Text(MetricFormatters.compactNumber(model.usage.total)).monospacedDigit()
                            Text((model.usage.cacheHitRate * 100).formatted(.percent.scale(1).precision(.fractionLength(1)))).monospacedDigit()
                            Text(MetricFormatters.duration(model.activeRuntime)).monospacedDigit()
                            Text(MetricFormatters.currency(model.estimatedCost)).monospacedDigit()
                        }
                    }

                    Divider().gridCellColumns(6)
                }
            }.padding(28)
        }
        .navigationTitle("Models")
        .onChange(of: store.allTimeModels.map(\.id)) { _, _ in
            modelPage = min(modelPage, modelPageCount - 1)
        }
    }

    private var modelPager: some View {
        HStack(spacing: 12) {
            Text(modelPageSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                modelPage = max(0, modelPage - 1)
            } label: {
                Label("Previous model page", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .disabled(modelPage == 0)
            .help("Show previous models")
            Text("Page \(min(modelPage + 1, modelPageCount)) of \(modelPageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 86)
            Button {
                modelPage = min(modelPageCount - 1, modelPage + 1)
            } label: {
                Label("Next model page", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .disabled(modelPage >= modelPageCount - 1)
            .help("Show next models")
        }
        .frame(maxWidth: .infinity)
    }
}

private enum PriceSeries: String, CaseIterable, Identifiable {
    case input = "Input"
    case cachedInput = "Cached input"
    case output = "Output"

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .input: .blue
        case .cachedInput: .teal
        case .output: .orange
        }
    }
}

private struct PriceObservation: Identifiable {
    let date: Date
    let price: ModelPrice
    let source: String

    var id: Date { date }

    func value(for series: PriceSeries) -> Double {
        switch series {
        case .input: price.inputPerMillion.doubleValue
        case .cachedInput: price.cachedInputPerMillion.doubleValue
        case .output: price.outputPerMillion.doubleValue
        }
    }
}

private struct ModelPricingView: View {
    let pricing: PricingHistory
    @State private var selectedModel = ""

    private var models: [String] {
        Array(pricing.schedules.last?.prices.keys ?? Dictionary<String, ModelPrice>().keys).sorted()
    }

    private var defaultModel: String {
        models.contains("gpt-5.6-sol") ? "gpt-5.6-sol" : (models.first ?? "")
    }

    private var model: String { models.contains(selectedModel) ? selectedModel : defaultModel }

    private var observations: [PriceObservation] {
        var result: [PriceObservation] = []
        var previous: ModelPrice?
        for schedule in pricing.schedules {
            guard let price = schedule.prices[model], price != previous else { continue }
            result.append(PriceObservation(
                date: schedule.effectiveAt,
                price: price,
                source: schedule.source ?? "Imported history"
            ))
            previous = price
        }
        return result
    }

    private var currentPrice: ModelPrice? { observations.last?.price }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                SectionHeader(
                    title: "Model prices",
                    subtitle: "USD per 1 million tokens. Price changes are saved locally when a new models.dev rate card is observed."
                )
                if models.isEmpty {
                    Text("No models")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: Binding(
                        get: { model },
                        set: { selectedModel = $0 }
                    )) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
            }

            if let currentPrice {
                HStack(spacing: 12) {
                    priceCard("Input", currentPrice.inputPerMillion, tint: .blue)
                    priceCard("Cached input", currentPrice.cachedInputPerMillion, tint: .teal)
                    priceCard("Output", currentPrice.outputPerMillion, tint: .orange)
                }

                Chart {
                    ForEach(PriceSeries.allCases) { series in
                        ForEach(observations) { observation in
                            LineMark(
                                x: .value("Observed", observation.date),
                                y: .value("USD per million", observation.value(for: series)),
                                series: .value("Rate", series.rawValue)
                            )
                            .interpolationMethod(.stepEnd)
                            .lineStyle(.init(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(by: .value("Rate", series.rawValue))
                            PointMark(
                                x: .value("Observed", observation.date),
                                y: .value("USD per million", observation.value(for: series))
                            )
                            .foregroundStyle(by: .value("Rate", series.rawValue))
                            .symbolSize(32)
                        }
                    }
                }
                .chartForegroundStyleScale([
                    PriceSeries.input.rawValue: PriceSeries.input.color,
                    PriceSeries.cachedInput.rawValue: PriceSeries.cachedInput.color,
                    PriceSeries.output.rawValue: PriceSeries.output.color
                ])
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.currency(code: "USD").precision(.fractionLength(0...3))))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .frame(height: 260)

                HStack {
                    Label(
                        "\(observations.count) saved rate card\(observations.count == 1 ? "" : "s") for \(model)",
                        systemImage: "clock.arrow.circlepath"
                    )
                    Spacer()
                    if let latest = observations.last {
                        Text("Latest: \(latest.source) · \(latest.date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                EmptyState(title: "No price data", message: "Refresh prices to save the first models.dev rate card.")
                    .frame(height: 220)
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.separator.opacity(0.45)))
    }

    private func priceCard(_ title: String, _ price: Decimal, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(price.formatted(.currency(code: "USD").precision(.fractionLength(0...4))))
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

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
        return Calendar.current.dateInterval(of: component, for: .now)
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

    private var reversedHistoryPeriods: [PeriodMetric] {
        Array(store.trendPeriods.reversed())
    }

    private var historyPageCount: Int {
        max(1, Int(ceil(Double(reversedHistoryPeriods.count) / Double(historyPageSize))))
    }

    private var visibleHistoryPeriods: [PeriodMetric] {
        let safePage = min(historyPage, historyPageCount - 1)
        return Array(reversedHistoryPeriods.dropFirst(safePage * historyPageSize).prefix(historyPageSize))
    }

    private var historyPageSummary: String {
        guard !reversedHistoryPeriods.isEmpty else { return "0 periods" }
        let start = min(historyPage, historyPageCount - 1) * historyPageSize
        let end = min(start + historyPageSize, reversedHistoryPeriods.count)
        return "\(start + 1)–\(end) of \(reversedHistoryPeriods.count) periods"
    }

    private func historyPeriodLabel(_ start: Date) -> String {
        switch store.range {
        case .day:
            return start.formatted(date: .abbreviated, time: .omitted)
        case .week:
            if let interval = Calendar.current.dateInterval(of: .weekOfYear, for: start) {
                let end = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
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
                    ForEach(visibleHistoryPeriods) { period in
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
                            Text(historyPageSummary)
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
                            Text("Page \(min(historyPage + 1, historyPageCount)) of \(historyPageCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button {
                                historyPage = min(historyPageCount - 1, historyPage + 1)
                            } label: {
                                Label("Next page", systemImage: "chevron.right")
                                    .labelStyle(.iconOnly)
                            }
                            .disabled(historyPage >= historyPageCount - 1)
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
            SectionHeader(title: "Subscription usage", subtitle: "Latest quota snapshot reported by Codex; no token-to-quota conversion is inferred locally.", definition: .subscriptionQuota)
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
