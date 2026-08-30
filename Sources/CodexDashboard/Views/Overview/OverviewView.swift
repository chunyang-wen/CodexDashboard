import Charts
import CodexMetricsCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: DashboardStore
    @AppStorage(DashboardPreferences.overviewActivityMetricKey, store: DashboardPreferences.sharedDefaults()) private var activityMetric = "Tokens"
    @State private var selectedPeriodStart: Date?
    @State private var periodDetails = SQLProjectAggregate.empty
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
        let medianTurn = periodDetails.medianTurnDuration
        let p95Turn = periodDetails.p95TurnDuration
        let averageTTFT = periodDetails.averageFirstTokenTime

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
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
                    TopProjectsView(projects: Array(store.topProjects.prefix(7)))
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
        .task(id: "\(store.range.rawValue)-\(effectivePeriodStart.timeIntervalSinceReferenceDate)") {
            periodDetails = .empty
            let details = await store.periodAggregate(in: periodInterval(containing: effectivePeriodStart))
            guard !Task.isCancelled else { return }
            periodDetails = details
        }
        .onDisappear {
            periodDetails = .empty
            selectedPeriodStart = nil
        }
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
            let lastDay = store.analyticsCalendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
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
        let calendar = store.analyticsCalendar
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

private struct ActivityChartPoint: Identifiable {
    let id: Date
    let period: PeriodMetric
    let index: Int
    let value: Double
    let hasActivity: Bool
    let axisLabel: String
}

struct ChartHoverOverlay<Selection: Equatable, Card: View>: View {
    let proxy: ChartProxy
    let selectionAtX: (ChartProxy, CGFloat) -> Selection?
    @Binding var selection: Selection?
    @State private var hoverLocation: CGPoint?
    let card: (Selection) -> Card
    let cardPosition: (CGPoint, CGSize) -> CGPoint
    let onDragChanged: (CGSize, CGRect) -> Void
    let onDragEnded: () -> Void
    let onTap: (CGPoint, CGRect) -> Void

    var body: some View {
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
                                  let nextSelection = selectionAtX(proxy, x) else {
                                clearHover()
                                return
                            }
                            if selection != nextSelection {
                                selection = nextSelection
                            }
                            hoverLocation = location
                        case .ended:
                            clearHover()
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                onDragChanged(value.translation, geometry[plotFrame])
                            }
                            .onEnded { _ in
                                onDragEnded()
                            }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                onTap(value.location, geometry[plotFrame])
                            }
                    )

                if let selection, let hoverLocation {
                    card(selection)
                        .position(cardPosition(hoverLocation, geometry.size))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func clearHover() {
        if selection != nil {
            selection = nil
        }
        hoverLocation = nil
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
    private var visiblePeriods: [PeriodMetric] {
        guard !periods.isEmpty else { return [] }
        let start = min(max(0, Int(scrollPosition.rounded())), max(0, periods.count - Int(visiblePeriodCount)))
        let end = min(periods.count, start + Int(visiblePeriodCount))
        var visible: [PeriodMetric] = []
        visible.reserveCapacity(30)
        visible.append(contentsOf: periods[start..<end])
        return visible
    }
    private var visibleChartPoints: [ActivityChartPoint] {
        visiblePeriods.enumerated().map { index, period in
            ActivityChartPoint(
                id: period.id,
                period: period,
                index: index,
                value: metricValue(period),
                hasActivity: hasActivity(period),
                axisLabel: axisPeriodLabel(period.start)
            )
        }
    }

    private func axisPositions(for count: Int) -> [Double] {
        let step = max(1, Int(ceil(visiblePeriodCount / 8)))
        var positions = stride(from: 0, to: count, by: step).map { Double($0) + 0.5 }
        if count > 0 {
            let finalPosition = Double(count) - 0.5
            if finalPosition - (positions.last ?? finalPosition) < Double(step) {
                positions[positions.count - 1] = finalPosition
            } else {
                positions.append(finalPosition)
            }
        }
        return Array(Set(positions)).sorted()
    }

    var body: some View {
        let chartPoints = visibleChartPoints
        let axisPositions = axisPositions(for: chartPoints.count)

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
            // Charts keeps mark and interaction state for every input element.
            // Keep the history in the store, but render only the visible window.
            Chart(chartPoints) { point in
                RectangleMark(
                    xStart: .value("Period start", Double(point.index) + 0.06),
                    xEnd: .value("Period end", Double(point.index) + 0.94),
                    yStart: .value("Baseline", 0),
                    yEnd: .value(metric, point.value)
                )
                .foregroundStyle(metricColor.gradient)
                .cornerRadius(3)
                if point.value == 0 && point.hasActivity {
                    PointMark(
                        x: .value("Period with activity", Double(point.index) + 0.5),
                        y: .value("Zero value", 0)
                    )
                    .symbolSize(28)
                    .foregroundStyle(metricColor.opacity(0.78))
                    .accessibilityLabel("Activity recorded, but \(metric.lowercased()) is zero")
                }
                let isHighlighted = hoveredPeriod?.id == point.id || selectedPeriodStart == point.period.start
                if isHighlighted {
                    RuleMark(x: .value("Selected period", Double(point.index) + 0.5))
                        .lineStyle(.init(lineWidth: selectedPeriodStart == point.period.start ? 1.5 : 1, dash: [4, 4]))
                        .foregroundStyle(selectedPeriodStart == point.period.start ? metricColor.opacity(0.8) : .secondary.opacity(0.7))
                    PointMark(x: .value("Selected period", Double(point.index) + 0.5), y: .value("Selected value", point.value))
                        .symbolSize(70)
                        .foregroundStyle(metricColor)
                    PointMark(x: .value("Selected period", Double(point.index) + 0.5), y: .value("Selected value", point.value))
                        .symbolSize(22)
                        .foregroundStyle(.background)
                }
            }
            .transaction { $0.animation = nil }
            .chartXScale(range: .plotDimension(startPadding: 54, endPadding: 58))
            .chartXAxis {
                AxisMarks(values: axisPositions) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel(centered: true, collisionResolution: .disabled) {
                        if let position = value.as(Double.self) {
                            let index = Int(floor(position))
                            if chartPoints.indices.contains(index) {
                                Text(chartPoints[index].axisLabel)
                                    .font(.caption2)
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
                ChartHoverOverlay(
                    proxy: proxy,
                    selectionAtX: { proxy, x in
                        guard let rawIndex: Double = proxy.value(atX: x) else { return nil }
                        let index = Int(floor(rawIndex))
                        return chartPoints.indices.contains(index) ? chartPoints[index].period : nil
                    },
                    selection: $hoveredPeriod,
                    card: { period in hoverCard(period) },
                    cardPosition: hoverCardPosition,
                    onDragChanged: { translation, frame in
                        guard canScroll else { return }
                        guard frame.width > 0 else { return }
                        if dragStartScrollPosition == nil {
                            dragStartScrollPosition = scrollPosition
                        }
                        let translatedPeriods = Double(translation.width / frame.width) * visiblePeriodCount
                        let proposed = (dragStartScrollPosition ?? scrollPosition) - translatedPeriods
                        setScrollPosition(proposed)
                        hoveredPeriod = nil
                    },
                    onDragEnded: {
                        dragStartScrollPosition = nil
                    },
                    onTap: { location, frame in
                        guard allowsPeriodSelection else { return }
                        let x = location.x - frame.minX
                        guard x >= 0, x <= frame.width,
                              let rawIndex: Double = proxy.value(atX: x) else { return }
                        let index = Int(floor(rawIndex))
                        guard chartPoints.indices.contains(index) else { return }
                        selectedPeriodStart = chartPoints[index].period.start
                    }
                )
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
        setScrollPosition(scrollPosition + amount)
    }

    private func setScrollPosition(_ proposed: Double) {
        // The rendered window already rounds to a period index; avoid publishing
        // fractional drag updates that cannot change the chart contents.
        let next = min(latestScrollPosition, max(0, proposed.rounded()))
        guard next != scrollPosition else { return }
        scrollPosition = next
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
        VStack(alignment: .center, spacing: 5) {
            Text(periodLabel(period.start))
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .center)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    hoverMetric(
                        MetricFormatters.compactNumber(period.usage.total),
                        icon: "text.word.spacing",
                        accessibilityLabel: "Tokens"
                    )
                    .frame(width: 99, alignment: .leading)
                    hoverMetric(
                        preciseDuration(period.activeRuntime),
                        icon: "clock",
                        accessibilityLabel: "Runtime"
                    )
                    .frame(width: 99, alignment: .leading)
                }
                GridRow {
                    hoverMetric(
                        MetricFormatters.currency(period.estimatedCost),
                        icon: "dollarsign",
                        accessibilityLabel: "Estimated cost"
                    )
                    .frame(width: 99, alignment: .leading)
                    hoverMetric(
                        "\(period.sessions) session\(period.sessions == 1 ? "" : "s")",
                        icon: "person.2",
                        accessibilityLabel: "Sessions"
                    )
                    .frame(width: 99, alignment: .leading)
                }
            }
        }
        .font(.caption2.monospacedDigit())
        .frame(width: 208, alignment: .center)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.55)))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }

    private func hoverCardPosition(for location: CGPoint, in size: CGSize) -> CGPoint {
        let cardSize = CGSize(width: 230, height: 86)
        let horizontalInset: CGFloat = 8
        let verticalInset: CGFloat = 8
        let x = min(
            max(cardSize.width / 2 + horizontalInset, location.x),
            max(cardSize.width / 2 + horizontalInset, size.width - cardSize.width / 2 - horizontalInset)
        )
        let above = location.y - cardSize.height / 2 - 14
        let below = location.y + cardSize.height / 2 + 14
        let y: CGFloat
        if above - cardSize.height / 2 >= verticalInset {
            y = above
        } else if below + cardSize.height / 2 <= size.height - verticalInset {
            y = below
        } else {
            y = min(
                max(cardSize.height / 2 + verticalInset, above),
                max(cardSize.height / 2 + verticalInset, size.height - cardSize.height / 2 - verticalInset)
            )
        }
        return CGPoint(x: x, y: y)
    }

    private func hoverMetric(_ value: String, icon: String, accessibilityLabel: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .frame(width: 13)
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    let projects: [ProjectAggregateRow]
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
            .transaction { $0.animation = nil }
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
