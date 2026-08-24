import AppKit
import CodexMetricsCore
import SwiftUI

enum MenuBarPopoverCommand: String {
    case openDashboard
    case openSettings
    case quitProduct
}

struct MenuBarDashboardView: View {
    @EnvironmentObject private var store: MenuBarStore
    let onCommand: (MenuBarPopoverCommand) -> Void
    @AppStorage(DashboardPreferences.showQuotaAlertMarkerKey, store: DashboardPreferences.sharedDefaults()) private var showQuotaAlertMarker = false
    @AppStorage(DashboardPreferences.quotaAlertUsedPercentKey, store: DashboardPreferences.sharedDefaults()) private var quotaAlertRemainingPercent = 80.0
    @AppStorage(DashboardPreferences.menuBarUsageTrendMetricKey, store: DashboardPreferences.sharedDefaults()) private var usageTrendMetricRawValue = MenuUsageTrendMetric.cost.rawValue

    private var usageTrendMetric: Binding<MenuUsageTrendMetric> {
        Binding(
            get: { MenuUsageTrendMetric(rawValue: usageTrendMetricRawValue) ?? .cost },
            set: { usageTrendMetricRawValue = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)

            VStack(spacing: 0) {
                header

                if let windows = store.subscription?.windows, !windows.isEmpty {
                    sectionDivider
                    VStack(spacing: 0) {
                        ForEach(windows) { quotaRow($0) }
                    }
                }

                if let bankedResets = store.bankedResets, bankedResets.availableCount > 0 {
                    sectionDivider
                    bankedResetSection(bankedResets)
                }

                sectionDivider
                usageTrend

                sectionDivider
                HStack(spacing: 0) {
                    MenuBarActionButton(
                        title: "Open Dashboard",
                        systemImage: "rectangle.grid.2x2.fill",
                        tint: .teal
                    ) {
                        onCommand(.openDashboard)
                    }
                    toolbarDivider
                    MenuBarActionButton(
                        title: "Settings",
                        systemImage: "gearshape.fill"
                    ) {
                        onCommand(.openSettings)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    toolbarDivider
                    MenuBarActionButton(
                        title: "Quit Codex Dashboard",
                        systemImage: "power",
                        tint: .red
                    ) {
                        onCommand(.quitProduct)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                }
                .frame(height: 44)
                .background(Color.primary.opacity(0.025))
            }
        }
        .frame(width: 390)
        .onAppear { store.loadPopover() }
        .onDisappear { store.releasePopover() }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(.separator.opacity(0.5))
            .frame(height: 0.5)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(.separator.opacity(0.45))
            .frame(width: 0.5, height: 24)
    }

    private var header: some View {
        HStack(spacing: 10) {
            MenuBarAppIcon(statusColor: headerQuotaColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.account?.email ?? "Codex Dashboard")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(planLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isBusy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerQuotaColor: Color? {
        store.subscription?.windows
            .map(\.remainingPercent)
            .min()
            .map { quotaColor(for: $0) }
    }

    private var planLabel: String {
        if let plan = store.subscription?.displayPlan { return "ChatGPT \(plan)" }
        if let plan = store.account?.planType { return "ChatGPT \(CodexPlanDisplay.name(for: plan))" }
        return "Plan not reported"
    }

    private func bankedResetSection(_ snapshot: BankedResetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label("Banked resets", systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(snapshot.availableCount.formatted())
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.teal)
            }

            if let credits = snapshot.credits, !credits.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(credits.prefix(3)) { credit in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(credit.title ?? "Codex reset")
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let expiresAt = credit.expiresAt {
                                Text("Expires \(expiresAt, style: .relative)")
                            } else {
                                Text("No expiry reported")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Available to use when needed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let credits = snapshot.credits,
               snapshot.availableCount > credits.count {
                Text("OpenAI reports \(snapshot.availableCount - credits.count) more reset\(snapshot.availableCount - credits.count == 1 ? "" : "s") available.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func quotaRow(_ window: UsageQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))%")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(quotaColor(for: window.remainingPercent))
                    Text("remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            QuotaRemainingBar(
                remainingPercent: window.remainingPercent,
                alertRemainingPercent: $quotaAlertRemainingPercent,
                showsAlertMarker: showQuotaAlertMarker
            )
            HStack {
                Text("Resets \(window.resetsAt, style: .relative)")
                Spacer()
                if showQuotaAlertMarker {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.red)
                            .frame(width: 5, height: 5)
                        Text("Attention at \(quotaAlertRemainingPercent.formatted(.number.precision(.fractionLength(0))))%")
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        showQuotaAlertMarker = true
                    } label: {
                        Text("Set attention marker")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private var usageTrend: some View {
        let calendar = store.analyticsCalendar
        let now = Date.now
        let todayInterval = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) ?? todayInterval
        let monthInterval = calendar.dateInterval(of: .month, for: now) ?? todayInterval
        let today = store.menuBarAggregate(in: todayInterval)
        let week = store.menuBarAggregate(in: weekInterval)
        let month = store.menuBarAggregate(in: monthInterval)

        return MenuUsageTrendView(
            metric: usageTrendMetric,
            days: monthUsageDays(in: monthInterval, calendar: calendar),
            currentWeekDays: currentWeekDays(
                weekInterval: weekInterval,
                monthInterval: monthInterval,
                calendar: calendar
            ),
            todayDay: calendar.component(.day, from: now),
            today: MenuUsageSummary(aggregate: today),
            week: MenuUsageSummary(aggregate: week),
            month: MenuUsageSummary(aggregate: month)
        )
    }

    private func monthUsageDays(in interval: DateInterval, calendar: Calendar) -> [MenuUsageDay] {
        let dailyByStart = Dictionary(store.menuBarDaily.map { (calendar.startOfDay(for: $0.start), $0) }) { _, latest in latest }
        let dayCount = calendar.range(of: .day, in: .month, for: interval.start)?.count ?? 1

        var days: [MenuUsageDay] = []
        days.reserveCapacity(dayCount)
        for offset in 0..<dayCount {
            if let date = calendar.date(byAdding: .day, value: offset, to: interval.start) {
                let start = calendar.startOfDay(for: date)
                days.append(MenuUsageDay(date: start, period: dailyByStart[start]))
            }
        }
        return days
    }

    private func currentWeekDays(
        weekInterval: DateInterval,
        monthInterval: DateInterval,
        calendar: Calendar
    ) -> ClosedRange<Int> {
        let clippedStart = max(weekInterval.start, monthInterval.start)
        let clippedEnd = min(weekInterval.end, monthInterval.end)
        let finalDay = calendar.date(byAdding: .day, value: -1, to: clippedEnd) ?? clippedStart
        return calendar.component(.day, from: clippedStart)...calendar.component(.day, from: finalDay)
    }
}

private enum MenuUsageTrendMetric: String, CaseIterable, Identifiable {
    case cost = "Cost"
    case tokens = "Tokens"

    var id: String { rawValue }
}

private struct MenuUsageDay: Identifiable {
    let date: Date
    let period: PeriodMetric?

    var id: Date { date }
    var day: Int { Calendar.current.component(.day, from: date) }
}

private struct MenuUsageSummary {
    let cost: Decimal
    let tokens: Int64
    let tools: Int
    let skills: Int

    init(aggregate: MenuBarUsageAggregate) {
        cost = aggregate.estimatedCost
        tokens = aggregate.usage.total
        tools = aggregate.toolCalls
        skills = aggregate.skillCalls
    }
}

private struct MenuUsageTrendView: View {
    @Binding var metric: MenuUsageTrendMetric
    let days: [MenuUsageDay]
    let currentWeekDays: ClosedRange<Int>
    let todayDay: Int
    let today: MenuUsageSummary
    let week: MenuUsageSummary
    let month: MenuUsageSummary

    // MenuBarExtra measures its content before the popover has a stable window
    // width. Keep this view's layout finite during that first measurement pass.
    private let contentWidth: CGFloat = 342
    private let barSpacing: CGFloat = 3
    private let comparisonTrailingWidth: CGFloat = 85
    private let comparisonBarWidth: CGFloat = 47

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.teal)
                    Text(insightLabel)
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.weight(.medium))
                .accessibilityElement(children: .combine)

                Spacer(minLength: 8)

                Picker("Usage chart metric", selection: $metric) {
                    ForEach(MenuUsageTrendMetric.allCases) { metric in
                        Text(metric.rawValue.uppercased()).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 132)
            }

            VStack(spacing: 5) {
                monthBars
                monthAxis
                weekSpanMarker
            }

            Divider().opacity(0.55)

            VStack(spacing: 8) {
                comparisonHeader
                comparisonRow("TODAY", summary: today, tint: .cyan)
                comparisonRow("WEEK", summary: week, tint: .teal)
                comparisonRow("MONTH", summary: month, tint: .secondary)
            }
        }
        .frame(width: contentWidth)
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.38), lineWidth: 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var monthBars: some View {
        let barWidth = resolvedBarWidth
        return HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(days) { day in
                let height = barHeight(for: day)
                let isToday = day.day == todayDay
                let isFuture = day.day > todayDay
                let isThisWeek = currentWeekDays.contains(day.day)

                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isFuture ? Color.clear : barColor(isToday: isToday, isThisWeek: isThisWeek))
                    .overlay {
                        if isFuture {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .stroke(isThisWeek ? Color.teal.opacity(0.52) : Color.secondary.opacity(0.28), lineWidth: 0.7)
                        }
                    }
                    .frame(width: barWidth, height: height)
                    .overlay(alignment: .top) {
                        if isToday {
                            Circle()
                                .fill(.cyan)
                                .frame(width: 6, height: 6)
                                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
                                .shadow(color: .cyan.opacity(0.65), radius: 4)
                                .offset(y: -5)
                        }
                    }
                    .accessibilityLabel(day.date.formatted(date: .long, time: .omitted))
                    .accessibilityValue(dayValueLabel(day))
            }
        }
        .frame(width: contentWidth, height: 78, alignment: .bottom)
    }

    private var monthAxis: some View {
        HStack(spacing: 0) {
            Text(monthAnchorLabel(day: 1))
            Spacer()
            Text(monthAnchorLabel(day: 8))
            Spacer()
            Text(monthAnchorLabel(day: 15))
            Spacer()
            Text("TODAY \(todayDay)").foregroundStyle(.cyan)
            Spacer()
            Text(monthAnchorLabel(day: days.count))
        }
        .font(.system(size: 8, weight: .medium).monospacedDigit())
        .foregroundStyle(.tertiary)
    }

    private var weekSpanMarker: some View {
        let count = max(1, days.count)
        let startIndex = max(0, currentWeekDays.lowerBound - 1)
        let endIndex = min(count - 1, currentWeekDays.upperBound - 1)
        let startX = CGFloat(startIndex) * (resolvedBarWidth + barSpacing)
        let spanWidth = CGFloat(endIndex - startIndex + 1) * resolvedBarWidth
            + CGFloat(max(0, endIndex - startIndex)) * barSpacing

        return HStack(spacing: 0) {
            Color.clear.frame(width: startX)
            CompactWeekMarker()
                .frame(width: spanWidth, height: 14)
            Spacer(minLength: 0)
        }
        .frame(width: contentWidth, height: 14)
        .accessibilityHidden(true)
    }

    private var comparisonHeader: some View {
        HStack(spacing: 5) {
            Text("").frame(width: 56)
            Text("COST").frame(width: 60, alignment: .trailing)
            Text("TOKENS").frame(width: 46, alignment: .trailing)
            Text("TOOLS").frame(width: 34, alignment: .trailing)
            Text("SKILLS").frame(width: 36, alignment: .trailing)
            Text("MONTH %").frame(width: comparisonTrailingWidth, alignment: .trailing)
        }
        .font(.system(size: 7.5, weight: .bold))
        .tracking(0.25)
        .foregroundStyle(.tertiary)
    }

    private func comparisonRow(_ title: String, summary: MenuUsageSummary, tint: Color) -> some View {
        let share = monthShare(for: summary)
        return HStack(spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(title == "MONTH" ? .secondary : tint)
            .frame(width: 56, alignment: .leading)

            Text(MetricFormatters.preciseCurrency(summary.cost))
                .frame(width: 60, alignment: .trailing)
            Text(MetricFormatters.compactNumber(summary.tokens))
                .frame(width: 46, alignment: .trailing)
            Text(summary.tools.formatted(.number.notation(.compactName)))
                .frame(width: 34, alignment: .trailing)
            Text(summary.skills.formatted(.number.notation(.compactName)))
                .frame(width: 36, alignment: .trailing)

            HStack(spacing: 4) {
                Text(share.formatted(.percent.precision(.fractionLength(0))))
                    .frame(width: 34, alignment: .trailing)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: comparisonBarWidth * min(1, max(0, share)))
                }
                .frame(width: comparisonBarWidth, height: 4)
            }
            .frame(width: comparisonTrailingWidth)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(MetricFormatters.preciseCurrency(summary.cost)), \(MetricFormatters.compactNumber(summary.tokens)) tokens, \(summary.tools) tools, \(summary.skills) skills, \(share.formatted(.percent.precision(.fractionLength(0)))) of the month")
    }

    private func barValue(_ day: MenuUsageDay) -> Double {
        guard let period = day.period else { return 0 }
        return switch metric {
        case .cost: NSDecimalNumber(decimal: period.estimatedCost).doubleValue
        case .tokens: Double(period.usage.total)
        }
    }

    private var resolvedBarWidth: CGFloat {
        let count = CGFloat(max(1, days.count))
        return max(1, (contentWidth - barSpacing * (count - 1)) / count)
    }

    private func summaryValue(_ summary: MenuUsageSummary) -> Double {
        return switch metric {
        case .cost: NSDecimalNumber(decimal: summary.cost).doubleValue
        case .tokens: Double(summary.tokens)
        }
    }

    private func barHeight(for day: MenuUsageDay) -> CGFloat {
        guard day.day <= todayDay else { return 5 }
        let maximum = max(1, days.lazy.filter { $0.day <= todayDay }.map(barValue).max() ?? 0)
        let fraction = min(1, max(0, barValue(day) / maximum))
        // Daily usage is naturally spiky. A square-root scale keeps outliers
        // dominant without flattening the rest of the month's trend into noise.
        return max(3, 68 * sqrt(fraction))
    }

    private func barColor(isToday: Bool, isThisWeek: Bool) -> Color {
        if isToday { return .cyan }
        if isThisWeek { return .teal.opacity(0.82) }
        return .secondary.opacity(0.36)
    }

    private func monthShare(for summary: MenuUsageSummary) -> Double {
        let denominator = summaryValue(month)
        guard denominator > 0 else { return 0 }
        return min(1, max(0, summaryValue(summary) / denominator))
    }

    private var insightLabel: String {
        let completedDays = max(1, min(todayDay, days.count))
        let average = summaryValue(month) / Double(completedDays)
        guard average > 0 else { return "No usage recorded this month" }
        let ratio = summaryValue(today) / average
        return "Today is \(ratio.formatted(.number.precision(.fractionLength(1))))× daily avg"
    }

    private func monthAnchorLabel(day: Int) -> String {
        guard let firstDate = days.first?.date else { return "—" }
        let month = firstDate.formatted(.dateTime.month(.abbreviated)).uppercased()
        return "\(month) \(day)"
    }

    private func dayValueLabel(_ day: MenuUsageDay) -> String {
        switch metric {
        case .cost: return MetricFormatters.preciseCurrency(day.period?.estimatedCost ?? 0)
        case .tokens: return "\(MetricFormatters.compactNumber(day.period?.usage.total ?? 0)) tokens"
        }
    }
}

private struct CompactWeekMarker: View {
    var body: some View {
        HStack(spacing: 4) {
            Rectangle().frame(height: 0.5)
            Text("THIS WEEK")
                .font(.system(size: 7, weight: .bold))
                .tracking(0.35)
                .fixedSize()
            Rectangle().frame(height: 0.5)
        }
        .foregroundStyle(.cyan)
        .overlay {
            HStack {
                Rectangle().frame(width: 0.5, height: 7)
                Spacer(minLength: 0)
                Rectangle().frame(width: 0.5, height: 7)
            }
            .foregroundStyle(.cyan)
        }
    }
}

private struct QuotaRemainingBar: View {
    let remainingPercent: Double
    @Binding var alertRemainingPercent: Double
    let showsAlertMarker: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDraggingAlert = false

    private var fraction: Double {
        min(1, max(0, remainingPercent / 100))
    }

    private var color: Color { quotaColor(for: remainingPercent) }

    private var alertRemainingFraction: Double {
        min(1, max(0, alertRemainingPercent / 100))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 6)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.72), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * fraction)
                    .frame(height: 6)
                    .shadow(color: color.opacity(0.2), radius: 3)

                if showsAlertMarker {
                    alertMarker
                        .position(
                            x: markerX(in: proxy.size.width),
                            y: proxy.size.height / 2
                        )
                }
            }
            .contentShape(Rectangle())
            .gesture(alertDragGesture(width: proxy.size.width))
        }
        .frame(height: 14)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: fraction)
        .animation(
            reduceMotion || isDraggingAlert ? nil : .snappy(duration: 0.2),
            value: alertRemainingFraction
        )
        .onHover { isHovering in
            guard showsAlertMarker else { return }
            if isHovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Quota remaining")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard showsAlertMarker else { return }
            switch direction {
            case .increment:
                alertRemainingPercent = min(100, alertRemainingPercent + 1)
            case .decrement:
                alertRemainingPercent = max(10, alertRemainingPercent - 1)
            @unknown default:
                break
            }
        }
    }

    private var alertMarker: some View {
        ZStack {
            Capsule()
                .fill(.red)
                .frame(width: 2, height: 14)
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle().stroke(.white.opacity(0.9), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
        }
        .frame(width: 12, height: 14)
    }

    private func markerX(in width: CGFloat) -> CGFloat {
        min(max(4, width * alertRemainingFraction), max(4, width - 4))
    }

    private func alertDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard showsAlertMarker, width > 0 else { return }
                isDraggingAlert = true
                let remainingFraction = min(1, max(0, value.location.x / width))
                alertRemainingPercent = min(100, max(10, (remainingFraction * 100).rounded()))
            }
            .onEnded { _ in
                isDraggingAlert = false
            }
    }

    private var accessibilityValue: String {
        let remaining = remainingPercent.formatted(.percent.scale(1).precision(.fractionLength(0)))
        guard showsAlertMarker else { return remaining }
        let alert = alertRemainingPercent.formatted(.number.precision(.fractionLength(0)))
        return "\(remaining) remaining, alert marker at \(alert)% remaining"
    }
}

private func quotaColor(for remainingPercent: Double) -> Color {
    switch remainingPercent {
    case ...10: .red
    case ...25: .orange
    default: .teal
    }
}

private struct MenuBarAppIcon: View {
    let statusColor: Color?

    @MainActor
    private static let cachedAppIcon: NSImage = {
        let original = NSApp.applicationIconImage ?? NSImage()
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        original.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()
        return image
    }()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: Self.cachedAppIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 2.5, y: 1)

            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .overlay {
                        Circle().stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                    }
                    .padding(1.5)
                    .background(.ultraThickMaterial, in: Circle())
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

private struct MenuBarActionButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isHovering ? tint : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isHovering ? tint.opacity(0.11) : Color.clear)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
