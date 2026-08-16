import Charts
import CodexMetricsCore
import SwiftUI

enum DashboardPage: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case projects = "Projects"
    case models = "Models"
    case billing = "Usage & Billing"
    case definitions = "Metric Guide"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .projects: "folder"
        case .models: "cpu"
        case .billing: "dollarsign.circle"
        case .definitions: "book.closed"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    Text("~/.codex").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } detail: {
            Group {
                if store.isLoading && store.sessions.isEmpty {
                    ProgressView("Indexing Codex history…")
                        .controlSize(.large)
                } else if let error = store.errorMessage, store.sessions.isEmpty {
                    ContentUnavailableView("Couldn’t load metrics", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    page
                }
            }
            .overlay {
                if store.isUpdatingAnalytics {
                    AnalyticsUpdateOverlay(label: store.analyticsUpdateLabel)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: store.isUpdatingAnalytics)
            .toolbar {
                ToolbarItemGroup {
                    Picker("Range", selection: $store.range) {
                        ForEach(DashboardStore.Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 245)
                    Button { store.load() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh metrics")
                        .disabled(store.isBusy)
                    if store.isEnriching && !store.isUpdatingAnalytics {
                        ProgressView(value: store.enrichmentFraction)
                            .progressViewStyle(.linear)
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
        case .definitions: MetricGuideView()
        }
    }
}

private struct AnalyticsUpdateOverlay: View {
    let label: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(label)
                    .font(.headline)
                Text("Refreshing metrics and charts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(minWidth: 240)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.separator.opacity(0.55))
            }
            .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: DashboardStore
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeader(title: "Codex activity", subtitle: "A local, read-only view of projects, usage, responsiveness, and estimated spend.")
                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard(title: "Projects", value: store.projects.count.formatted(), detail: "\(store.filteredSessions.count) sessions", icon: "folder.fill", tint: .blue)
                    MetricCard(title: "Tokens", value: MetricFormatters.compactNumber(store.usage.total), detail: "\((store.usage.cacheHitRate * 100).formatted(.number.precision(.fractionLength(1))))% cache hit", icon: "text.word.spacing", tint: .purple)
                    MetricCard(title: "Agent runtime", value: MetricFormatters.duration(store.runtime), detail: "Completed turn wall time", icon: "clock.fill", tint: .orange)
                    MetricCard(title: "Equivalent cost", value: store.costCoverage > 0 ? MetricFormatters.currency(store.estimatedCost) : "—", detail: "\((store.costCoverage * 100).formatted(.number.precision(.fractionLength(0))))% token coverage", icon: "dollarsign", tint: .green)
                    MetricCard(title: "Median turn", value: Analytics.percentile(store.turnDurations, 0.5).map(MetricFormatters.duration) ?? "—", detail: "P95 \(Analytics.percentile(store.turnDurations, 0.95).map(MetricFormatters.duration) ?? "—")", icon: "gauge.with.dots.needle.50percent", tint: .pink)
                    MetricCard(title: "First token", value: store.averageTTFT.map(MetricFormatters.duration) ?? "—", detail: "Average response startup", icon: "bolt.fill", tint: .yellow)
                    MetricCard(title: "Active days", value: store.activeDays.formatted(), detail: "Distinct calendar days", icon: "calendar.badge.clock", tint: .teal)
                    MetricCard(title: "Tool calls", value: store.toolCalls.formatted(.number.notation(.compactName)), detail: "\(store.completedTurns) completed · \(store.abortedTurns) aborted", icon: "hammer.fill", tint: .indigo)
                }
                ActivityChart(daily: store.daily, weekly: store.weekly, monthly: store.monthly)
                HStack(alignment: .top, spacing: 16) {
                    TopProjectsView(projects: Array(store.projects.prefix(7)))
                    ModelMixView(models: Array(store.models.prefix(7)))
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 8)
        }
        .navigationTitle("Overview")
    }
}

struct ActivityChart: View {
    let daily: [PeriodMetric]
    let weekly: [PeriodMetric]
    let monthly: [PeriodMetric]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var metric = "Tokens"
    @State private var granularity = PeriodGranularity.day
    @State private var hoveredPeriod: PeriodMetric?
    private var periods: [PeriodMetric] {
        switch granularity {
        case .day: daily
        case .week: weekly
        case .month: monthly
        }
    }
    private var displayedPeriods: [PeriodMetric] { Array(periods.suffix(90)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeader(title: "Activity trend", subtitle: "Detailed token events and completed turns only; indexed totals are excluded until enriched.")
                VStack(alignment: .trailing, spacing: 8) {
                    Picker("Period", selection: $granularity) {
                        Text("Day").tag(PeriodGranularity.day)
                        Text("Week").tag(PeriodGranularity.week)
                        Text("Month").tag(PeriodGranularity.month)
                    }.pickerStyle(.segmented).frame(width: 230)
                    Picker("Metric", selection: $metric) {
                        Text("Tokens").tag("Tokens")
                        Text("Runtime").tag("Runtime")
                        Text("Cost").tag("Cost")
                    }.pickerStyle(.segmented).frame(width: 230)
                }
            }
            Chart(displayedPeriods) { period in
                if metric == "Tokens" {
                    AreaMark(x: .value("Date", period.start), y: .value("Tokens", period.usage.total))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.28), .blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", period.start), y: .value("Tokens", period.usage.total))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(.blue)
                    PointMark(x: .value("Date", period.start), y: .value("Tokens", period.usage.total))
                        .symbolSize(18).foregroundStyle(.blue)
                } else if metric == "Runtime" {
                    AreaMark(x: .value("Date", period.start), y: .value("Hours", period.activeRuntime / 3600))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [.orange.opacity(0.28), .orange.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", period.start), y: .value("Hours", period.activeRuntime / 3600))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(.orange)
                    PointMark(x: .value("Date", period.start), y: .value("Hours", period.activeRuntime / 3600))
                        .symbolSize(18).foregroundStyle(.orange)
                } else {
                    AreaMark(x: .value("Date", period.start), y: .value("USD", period.estimatedCost.doubleValue))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [.green.opacity(0.28), .green.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", period.start), y: .value("USD", period.estimatedCost.doubleValue))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(.green)
                    PointMark(x: .value("Date", period.start), y: .value("USD", period.estimatedCost.doubleValue))
                        .symbolSize(18).foregroundStyle(.green)
                }
                if hoveredPeriod?.id == period.id {
                    RuleMark(x: .value("Selected date", period.start))
                        .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary.opacity(0.7))
                    PointMark(x: .value("Selected date", period.start), y: .value("Selected value", metricValue(period)))
                        .symbolSize(70)
                        .foregroundStyle(metricColor)
                    PointMark(x: .value("Selected date", period.start), y: .value("Selected value", metricValue(period)))
                        .symbolSize(22)
                        .foregroundStyle(.background)
                        .annotation(
                            position: .top,
                            spacing: 10,
                            overflowResolution: .init(
                                x: .fit(to: .chart),
                                y: .fit(to: .chart)
                            )
                        ) { hoverCard(period) }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) }
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
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: metric)
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: granularity)
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
                                      let date: Date = proxy.value(atX: x) else {
                                    hoveredPeriod = nil
                                    return
                                }
                                let nearest = displayedPeriods.min {
                                    abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
                                }
                                if hoveredPeriod?.id != nearest?.id { hoveredPeriod = nearest }
                            case .ended:
                                hoveredPeriod = nil
                            }
                        }
                }
            }
            .frame(height: 220)
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    private func hoverCard(_ period: PeriodMetric) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(periodLabel(period.start)).font(.caption.weight(.semibold))
            HStack(spacing: 12) {
                Label(MetricFormatters.compactNumber(period.usage.total), systemImage: "text.word.spacing")
                Label(preciseDuration(period.activeRuntime), systemImage: "clock")
                Text(MetricFormatters.currency(period.estimatedCost))
                    .accessibilityLabel("Estimated cost \(MetricFormatters.currency(period.estimatedCost))")
            }
            .font(.caption2.monospacedDigit())
            Text("\(period.sessions) session\(period.sessions == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.55)))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }

    private func periodLabel(_ date: Date) -> String {
        switch granularity {
        case .day: date.formatted(date: .abbreviated, time: .omitted)
        case .week: "Week of \(date.formatted(date: .abbreviated, time: .omitted))"
        case .month: date.formatted(.dateTime.year().month(.wide))
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

private enum ProjectTreeSelection: Hashable {
    case project(String)
    case session(String)
}

struct ProjectsView: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedProjects = Set<String>()
    @State private var selection: ProjectTreeSelection?

    var body: some View {
        HSplitView {
            projectTree
                .frame(minWidth: 310, idealWidth: 390, maxWidth: 500)
            selectedDetail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Projects")
        .onAppear { selectInitialProject() }
        .onChange(of: store.allProjects.map(\.id)) { _, _ in selectInitialProject() }
    }

    private var projectTree: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(store.allProjects) { project in
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
            }
        }
    }

    @ViewBuilder private var selectedDetail: some View {
        switch selection {
        case .project(let path):
            if let project = store.allProjects.first(where: { $0.path == path }) {
                let rangedSessions = store.filteredSessions.filter { $0.projectPath == path }
                ProjectDetailView(project: project, rangedSessions: rangedSessions, rangeLabel: store.range.rawValue, rangeStart: store.range.startDate, pricing: store.pricing) { session in
                    expandedProjects.insert(project.id)
                    selection = .session(session.id)
                }
            } else { selectionPlaceholder }
        case .session(let id):
            if let session = store.sessions.first(where: { $0.id == id }) {
                SessionDetailView(session: session)
            } else { selectionPlaceholder }
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

private struct ProjectTreeRow: View {
    let project: ProjectMetric
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(project.sessionCount) sessions · \(MetricFormatters.compactNumber(project.usage.total)) tokens")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(project.lastActivity, style: .relative).font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct SessionTreeRow: View {
    let session: SessionMetric
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle).font(.subheadline).lineLimit(1)
                Text("\(session.model ?? "Unknown") · \(MetricFormatters.compactNumber(session.usage.total)) tokens")
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
    let rangedSessions: [SessionMetric]
    let rangeLabel: String
    let rangeStart: Date?
    let pricing: PricingHistory
    let onSelectSession: (SessionMetric) -> Void
    private var rangedUsage: TokenUsage { Analytics.totalUsage(rangedSessions, since: rangeStart) }
    private var rangedRuntime: TimeInterval {
        rangedSessions.flatMap(\.turns)
            .filter { turn in turn.completed && (rangeStart.map { turn.completedAt >= $0 } ?? true) }
            .reduce(0) { $0 + $1.duration }
    }
    private var cost: Decimal { Analytics.totalEstimatedCost(rangedSessions, pricing: pricing, since: rangeStart) }
    private var coverage: Double { Analytics.costCoverage(rangedSessions, pricing: pricing, since: rangeStart) }
    private var daily: [PeriodMetric] { Analytics.periods(from: rangedSessions, granularity: .day, pricing: pricing, since: rangeStart) }
    private var weekly: [PeriodMetric] { Analytics.periods(from: rangedSessions, granularity: .week, pricing: pricing, since: rangeStart) }
    private var monthly: [PeriodMetric] { Analytics.periods(from: rangedSessions, granularity: .month, pricing: pricing, since: rangeStart) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(project.name, systemImage: "folder.fill").font(.largeTitle.weight(.semibold))
                    Text(project.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    MetricCard(title: "Sessions", value: project.sessionCount.formatted(), detail: "\(rangedSessions.count) in \(rangeLabel)", icon: "bubble.left.and.text.bubble.right.fill", tint: .blue)
                    MetricCard(title: "Tokens", value: MetricFormatters.compactNumber(rangedUsage.total), detail: "\((rangedUsage.cacheHitRate * 100).formatted(.number.precision(.fractionLength(1))))% cached · \(rangeLabel)", icon: "text.word.spacing", tint: .purple)
                    MetricCard(title: "Agent runtime", value: MetricFormatters.duration(rangedRuntime), detail: "Completed turns · \(rangeLabel)", icon: "clock.fill", tint: .orange)
                    MetricCard(title: "Equivalent cost", value: coverage > 0 ? MetricFormatters.currency(cost) : "—", detail: "\((coverage * 100).formatted(.number.precision(.fractionLength(0))))% coverage · \(rangeLabel)", icon: "dollarsign", tint: .green)
                }
                ActivityChart(daily: daily, weekly: weekly, monthly: monthly)
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
                                Text(MetricFormatters.compactNumber(session.usage.total)).monospacedDigit().foregroundStyle(.secondary)
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(session.displayTitle, systemImage: "bubble.left.and.text.bubble.right.fill")
                        .font(.title.weight(.semibold)).lineLimit(2)
                    Label(session.projectName, systemImage: "folder.fill").font(.subheadline.weight(.medium)).foregroundStyle(.blue)
                    Text(session.projectPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    MetricCard(title: "Tokens", value: MetricFormatters.compactNumber(session.usage.total), detail: "\(MetricFormatters.compactNumber(session.usage.output)) output", icon: "text.word.spacing", tint: .purple)
                    MetricCard(title: "Agent runtime", value: MetricFormatters.duration(session.activeRuntime), detail: "\(session.completedTurns) completed turns", icon: "clock.fill", tint: .orange)
                    MetricCard(title: "Session span", value: MetricFormatters.duration(session.sessionSpan), detail: "Includes idle gaps", icon: "calendar.badge.clock", tint: .blue)
                    MetricCard(title: "First token", value: session.averageTTFT.map(MetricFormatters.duration) ?? "—", detail: "Average startup latency", icon: "bolt.fill", tint: .yellow)
                }
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Token composition", subtitle: "Cached and reasoning values are subsets of input and output.")
                    Chart {
                        BarMark(x: .value("Tokens", session.usage.uncachedInput), y: .value("Type", "Uncached input")).foregroundStyle(.blue)
                        BarMark(x: .value("Tokens", session.usage.cachedInput), y: .value("Type", "Cached input")).foregroundStyle(.cyan)
                        BarMark(x: .value("Tokens", session.usage.output), y: .value("Type", "Output")).foregroundStyle(.purple)
                        BarMark(x: .value("Tokens", session.usage.reasoningOutput), y: .value("Type", "Reasoning")).foregroundStyle(.pink)
                    }
                    .frame(height: 190)
                }
                .padding(18).background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 11) {
                    metadata("Model", session.model ?? "Unknown")
                    metadata("Reasoning effort", session.reasoningEffort ?? "Unknown")
                    metadata("Source", session.source)
                    metadata("Git branch", session.gitBranch ?? "—")
                    metadata("Tool calls", session.toolCalls.formatted())
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

struct ModelsView: View {
    @EnvironmentObject private var store: DashboardStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeader(title: "Model portfolio", subtitle: "Compare volume, runtime, cache behavior, and API-equivalent cost.")
                Chart(store.models.prefix(12)) { model in
                    BarMark(x: .value("Tokens", model.usage.total), y: .value("Model", model.model))
                        .foregroundStyle(.purple.gradient)
                        .annotation(position: .trailing) { Text(MetricFormatters.compactNumber(model.usage.total)).font(.caption).foregroundStyle(.secondary) }
                }.frame(height: 420)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow { Text("Model"); Text("Sessions"); Text("Cache hit"); Text("Runtime"); Text("Est. cost") }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellColumns(5)
                    ForEach(store.models) { model in
                        GridRow {
                            Text(model.model).fontWeight(.medium)
                            Text(model.sessions.formatted()).monospacedDigit()
                            Text((model.usage.cacheHitRate * 100).formatted(.percent.scale(1).precision(.fractionLength(1)))).monospacedDigit()
                            Text(MetricFormatters.duration(model.activeRuntime)).monospacedDigit()
                            Text(MetricFormatters.currency(model.estimatedCost)).monospacedDigit()
                        }
                    }
                }
            }.padding(28)
        }.navigationTitle("Models")
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
                Picker("Model", selection: $selectedModel) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 240)
                .onAppear { if selectedModel.isEmpty { selectedModel = defaultModel } }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SubscriptionUsageView(snapshot: store.subscription)
                Divider()
                SectionHeader(title: "Estimated billing", subtitle: "Monthly API-equivalent token cost, separated from actual subscription billing.")
                HStack(spacing: 12) {
                    MetricCard(title: "Selected range", value: MetricFormatters.currency(store.estimatedCost), detail: "API-equivalent estimate", icon: "dollarsign.circle.fill", tint: .green)
                    MetricCard(title: "Coverage", value: (store.costCoverage * 100).formatted(.number.precision(.fractionLength(1))) + "%", detail: "Tokens with model + breakdown", icon: "checkmark.seal.fill", tint: .blue)
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
                        if store.isRefreshingPricing { ProgressView().controlSize(.small) }
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
                Chart(store.monthly) { period in
                    BarMark(x: .value("Month", period.start, unit: .month), y: .value("USD", period.estimatedCost.doubleValue))
                        .foregroundStyle(.green.gradient)
                        .annotation(position: .top) { Text(MetricFormatters.currency(period.estimatedCost)).font(.caption2).foregroundStyle(.secondary) }
                }
                .frame(height: 280)
                Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 12) {
                    GridRow { Text("Month"); Text("Sessions"); Text("Tokens"); Text("Agent runtime"); Text("Estimated cost") }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellColumns(5)
                    ForEach(store.monthly.reversed()) { period in
                        GridRow {
                            Text(period.start.formatted(.dateTime.year().month(.wide))).fontWeight(.medium)
                            Text(period.sessions.formatted()).monospacedDigit()
                            Text(MetricFormatters.compactNumber(period.usage.total)).monospacedDigit()
                            Text(MetricFormatters.duration(period.activeRuntime)).monospacedDigit()
                            Text(MetricFormatters.currency(period.estimatedCost)).monospacedDigit()
                        }
                    }
                }
            }.padding(28)
        }.navigationTitle("Subscription & Billing")
    }
}

private struct SubscriptionUsageView: View {
    let snapshot: SubscriptionSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Subscription usage", subtitle: "Latest quota snapshot reported by Codex; no token-to-quota conversion is inferred locally.")
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
                Text("\(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% used")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: min(100, max(0, window.usedPercent)), total: 100)
                .tint(quotaColor)
            HStack {
                Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))% remaining")
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
        switch window.usedPercent {
        case 90...: .red
        case 70...: .orange
        default: .blue
        }
    }
}

struct MetricGuideView: View {
    private let metrics: [(String, String, String)] = [
        ("Total tokens", "Final cumulative tokens reported by Codex for each session.", "Exact when a token_count event or indexed total exists."),
        ("Input / cached input", "Prompt tokens processed; cached input is a subset served from prompt cache.", "Cached tokens are not added again to input."),
        ("Output / reasoning", "Generated tokens; reasoning output is a subset of output, not an additional total.", "Useful for model-effort comparisons."),
        ("Agent runtime", "Sum of duration_ms from completed turns.", "Includes tool execution and model waiting inside a turn; excludes time between turns."),
        ("Session span", "Last session update minus session creation.", "Includes idle gaps. Never treat this as working time."),
        ("First-token latency", "Mean time_to_first_token_ms for completed turns.", "Measures startup responsiveness, not total completion speed."),
        ("Median / P95 turn", "50th and 95th percentile completed-turn runtimes.", "P95 surfaces slow-tail sessions hidden by averages."),
        ("Cache hit rate", "Cached input divided by total input.", "A high rate usually lowers API-equivalent input cost."),
        ("Estimated cost", "Uncached input × input rate + cached input × cached rate + output × output rate.", "API-equivalent estimate only; excludes tool-call fees and subscription terms."),
        ("Subscription quota", "Latest plan, usage windows, credits, and reset timestamps reported by Codex.", "Quota percentage is account-provided; it is not inferred from local token totals."),
        ("Weekly / monthly usage", "Token deltas grouped by token event timestamp; runtime grouped by turn completion.", "Sessions without detailed events are assigned to last-update date."),
        ("Active days", "Distinct local calendar days with project session activity.", "A cadence metric, not a productivity score."),
        ("Cost coverage", "Share of total tokens with both detailed breakdown and a recognized model price.", "Low coverage means the estimate is incomplete.")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader(title: "Metric guide", subtitle: "Definitions, calculation boundaries, and interpretation notes.")
                ForEach(metrics, id: \.0) { metric in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(metric.0).font(.headline)
                        Text(metric.1).font(.subheadline)
                        Text(metric.2).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }.padding(28).frame(maxWidth: 760, alignment: .leading)
        }.navigationTitle("Metric Guide")
    }
}
