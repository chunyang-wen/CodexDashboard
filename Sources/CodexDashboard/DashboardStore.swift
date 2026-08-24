import AppKit
import CodexMetricsCore
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct DashboardAnalytics: Sendable {
    let filteredSessions: [SessionSummary]
    let allProjects: [ProjectMetric]
    let projects: [ProjectMetric]
    let usage: TokenUsage
    let estimatedCost: Decimal
    let costCoverage: Double
    let runtime: TimeInterval
    let models: [ModelMetric]
    let allTimeModels: [ModelMetric]
    let tools: [ToolMetric]
    let skills: [SkillMetric]
    let daily: [PeriodMetric]
    let weekly: [PeriodMetric]
    let monthly: [PeriodMetric]
    let yearly: [PeriodMetric]
    let modelDaily: [ModelPeriodMetric]
    let modelWeekly: [ModelPeriodMetric]
    let modelMonthly: [ModelPeriodMetric]
    let modelYearly: [ModelPeriodMetric]
    let turnDurations: [TimeInterval]
    let averageTTFT: TimeInterval?
    let activeDays: Int
    let toolCalls: Int
    let skillCalls: Int
    let completedTurns: Int
    var abortedTurns: Int

    static let empty = DashboardAnalytics(
        filteredSessions: [], allProjects: [], projects: [],
        usage: .zero, estimatedCost: 0, costCoverage: 0, runtime: 0,
        models: [], allTimeModels: [], tools: [], skills: [], daily: [], weekly: [], monthly: [], yearly: [],
        modelDaily: [], modelWeekly: [], modelMonthly: [], modelYearly: [], turnDurations: [],
        averageTTFT: nil, activeDays: 0, toolCalls: 0, skillCalls: 0, completedTurns: 0,
        abortedTurns: 0
    )

    /// Builds analytics from pre-fetched SQL results instead of iterating an
    /// in-memory MetricsIndexSnapshot. Tools/skills/turn durations still come
    /// from the index snapshot; everything else comes from typed SQLite queries.
    static func fromSQLResults(
        sessions: [SessionSummary],
        startDate: Date?,
        aggregate: DailyAggregateResult,
        periodRows: [DailyPeriodRow],
        modelRows: [DailyModelRow],
        allTimeModels: [ModelMetric],
        tools: [ToolMetric],
        skills: [SkillMetric],
        granularity: PeriodGranularity = .month,
        turnDurations: [TimeInterval] = [],
        firstTokenTimes: [TimeInterval] = [],
        calendar: Calendar = .current
    ) -> DashboardAnalytics {
        let filtered = sessions.filter { session in
            startDate.map { session.updatedAt >= $0 } ?? true
        }
        // Keep only the projection selected by the dashboard. Building all four
        // granularities here multiplied the chart data retained by the store,
        // even though each page renders one granularity at a time.
        let periods = Self.bucketPeriods(periodRows, granularity: granularity, calendar: calendar)
        let modelPeriods = Self.bucketModelPeriods(modelRows, granularity: granularity, calendar: calendar)
        let usage = aggregate.usage
        return DashboardAnalytics(
            filteredSessions: filtered,
            allProjects: Analytics.projects(from: sessions),
            projects: Analytics.projects(from: filtered),
            usage: usage,
            estimatedCost: Decimal(aggregate.estimatedCost),
            costCoverage: usage.total > 0 ? Double(aggregate.coveredTokens) / Double(usage.total) : 0,
            runtime: aggregate.activeRuntime,
            models: mergeModelRows(modelRows, projectPath: nil),
            allTimeModels: allTimeModels,
            tools: tools,
            skills: skills,
            daily: granularity == .day ? periods : [],
            weekly: granularity == .week ? periods : [],
            monthly: granularity == .month ? periods : [],
            yearly: granularity == .year ? periods : [],
            modelDaily: granularity == .day ? modelPeriods : [],
            modelWeekly: granularity == .week ? modelPeriods : [],
            modelMonthly: granularity == .month ? modelPeriods : [],
            modelYearly: granularity == .year ? modelPeriods : [],
            turnDurations: turnDurations,
            averageTTFT: firstTokenTimes.isEmpty ? nil : firstTokenTimes.reduce(0, +) / Double(firstTokenTimes.count),
            activeDays: aggregate.activeDays,
            toolCalls: aggregate.toolCalls,
            skillCalls: aggregate.skillCalls,
            completedTurns: aggregate.completedTurns,
            abortedTurns: 0
        )
    }

    private static func bucketPeriods(
        _ rows: [DailyPeriodRow], granularity: PeriodGranularity, calendar: Calendar
    ) -> [PeriodMetric] {
        struct Bucket {
            var usage = TokenUsage.zero
            var sessions = Set<Int>()
            var runtime: TimeInterval = 0
            var cost = 0.0
        }
        var buckets: [Date: Bucket] = [:]
        for row in rows {
            let start = Self.periodStart(row.day, granularity: granularity, calendar: calendar)
            var bucket = buckets[start, default: Bucket()]
            bucket.usage = bucket.usage + row.usage
            bucket.sessions.insert(row.sessions)
            bucket.runtime += row.activeRuntime
            bucket.cost += row.estimatedCost
            buckets[start] = bucket
        }
        return buckets.map { start, bucket in
            PeriodMetric(start: start, usage: bucket.usage, sessions: bucket.sessions.count,
                         activeRuntime: bucket.runtime, estimatedCost: Decimal(bucket.cost))
        }.sorted { $0.start < $1.start }
    }

    private static func bucketModelPeriods(
        _ rows: [DailyModelRow], granularity: PeriodGranularity, calendar: Calendar
    ) -> [ModelPeriodMetric] {
        struct Bucket {
            var usage = TokenUsage.zero
            var sessions = Set<String>()
            var runtime: TimeInterval = 0
            var cost = 0.0
        }
        var buckets: [String: [Date: Bucket]] = [:]
        for row in rows {
            let start = Self.periodStart(row.day, granularity: granularity, calendar: calendar)
            var modelBuckets = buckets[row.model, default: [:]]
            var bucket = modelBuckets[start, default: Bucket()]
            bucket.usage = bucket.usage + row.usage
            bucket.sessions.insert("\(row.model)-\(row.sessions)")
            bucket.runtime += row.activeRuntime
            bucket.cost += row.estimatedCost
            modelBuckets[start] = bucket
            buckets[row.model] = modelBuckets
        }
        return buckets.flatMap { model, modelBuckets in
            modelBuckets.map { start, bucket in
                ModelPeriodMetric(start: start, model: model, usage: bucket.usage,
                                  sessions: bucket.sessions.count, activeRuntime: bucket.runtime,
                                  estimatedCost: Decimal(bucket.cost))
            }
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.model.localizedStandardCompare($1.model) == .orderedAscending
        }
    }

    static func mergeModelRowsPublic(_ rows: [DailyModelRow]) -> [ModelMetric] {
        mergeModelRows(rows, projectPath: nil)
    }

    private static func mergeModelRows(_ rows: [DailyModelRow], projectPath: String?) -> [ModelMetric] {
        struct Bucket {
            var usage = TokenUsage.zero
            var sessions = Set<String>()
            var runtime = 0.0
            var cost = 0.0
        }
        var buckets: [String: Bucket] = [:]
        for row in rows {
            var bucket = buckets[row.model, default: Bucket()]
            bucket.usage = bucket.usage + row.usage
            bucket.sessions.insert("\(row.model)-\(row.day.timeIntervalSince1970)-\(row.sessions)")
            bucket.runtime += row.activeRuntime
            bucket.cost += row.estimatedCost
            buckets[row.model] = bucket
        }
        return buckets.map { model, bucket in
            ModelMetric(model: model, sessions: bucket.sessions.count, usage: bucket.usage,
                        activeRuntime: bucket.runtime, estimatedCost: Decimal(bucket.cost))
        }.sorted { $0.usage.total > $1.usage.total }
    }

    private static func periodStart(_ date: Date, granularity: PeriodGranularity, calendar: Calendar) -> Date {
        switch granularity {
        case .day: calendar.startOfDay(for: date)
        case .week: calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month: calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        case .year: calendar.dateInterval(of: .year, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    static func calculate(
        sessions: [SessionSummary],
        startDate: Date?,
        index: MetricsIndexSnapshot
    ) -> DashboardAnalytics {
        let filtered = sessions.filter { session in
            startDate.map { session.updatedAt >= $0 } ?? true
        }

        let summary = index.aggregate(since: startDate)
        let allTimeModels = startDate == nil ? summary.models : index.aggregate().models
        let averageTTFT = summary.firstTokenTimes.isEmpty
            ? nil
            : summary.firstTokenTimes.reduce(0, +) / Double(summary.firstTokenTimes.count)
        let calendar = Calendar.current

        return DashboardAnalytics(
            filteredSessions: filtered,
            allProjects: Analytics.projects(from: sessions),
            projects: Analytics.projects(from: filtered),
            usage: summary.usage,
            estimatedCost: summary.estimatedCost,
            costCoverage: summary.costCoverage,
            runtime: summary.activeRuntime,
            models: summary.models,
            allTimeModels: allTimeModels,
            tools: summary.tools,
            skills: summary.skills,
            daily: index.periods(granularity: .day, since: startDate, calendar: calendar),
            weekly: index.periods(granularity: .week, since: startDate, calendar: calendar),
            monthly: index.periods(granularity: .month, since: startDate, calendar: calendar),
            yearly: index.periods(granularity: .year, since: startDate, calendar: calendar),
            modelDaily: index.modelPeriods(granularity: .day, since: startDate, calendar: calendar),
            modelWeekly: index.modelPeriods(granularity: .week, since: startDate, calendar: calendar),
            modelMonthly: index.modelPeriods(granularity: .month, since: startDate, calendar: calendar),
            modelYearly: index.modelPeriods(granularity: .year, since: startDate, calendar: calendar),
            turnDurations: summary.turnDurations,
            averageTTFT: averageTTFT,
            activeDays: summary.activeDays,
            toolCalls: summary.toolCalls,
            skillCalls: summary.skillCalls,
            completedTurns: summary.completedTurns,
            abortedTurns: summary.abortedTurns
        )
    }

    /// The menu bar only consumes today's usage, cost, tool calls, and skill calls.
    /// Avoid rebuilding every project/model/period breakdown a second time for it.
    static func calculateToday(
        startDate: Date,
        index: MetricsIndexSnapshot
    ) -> DashboardAnalytics {
        let summary = index.aggregate(since: startDate)

        return DashboardAnalytics(
            filteredSessions: [], allProjects: [], projects: [],
            usage: summary.usage,
            estimatedCost: summary.estimatedCost,
            costCoverage: 0,
            runtime: 0,
            models: [], allTimeModels: [], tools: [], skills: [], daily: [], weekly: [], monthly: [], yearly: [],
            modelDaily: [], modelWeekly: [], modelMonthly: [], modelYearly: [],
            turnDurations: [], averageTTFT: nil, activeDays: 0,
            toolCalls: summary.toolCalls, skillCalls: summary.skillCalls,
            completedTurns: 0, abortedTurns: 0
        )
    }
}

private struct QuotaWeekAnalytics: Sendable {
    let interval: DateInterval?
    let usage: TokenUsage
    let estimatedCost: Decimal

    static let empty = QuotaWeekAnalytics(interval: nil, usage: .zero, estimatedCost: 0)

    static func calculate(
        index: MetricsIndexSnapshot,
        window: UsageQuotaWindow?
    ) -> QuotaWeekAnalytics {
        guard let window else { return .empty }
        let interval = DateInterval(
            start: window.resetsAt.addingTimeInterval(-TimeInterval(window.windowMinutes * 60)),
            end: window.resetsAt
        )
        let agg = index.aggregate(in: interval)
        return QuotaWeekAnalytics(
            interval: interval,
            usage: agg.usage,
            estimatedCost: agg.estimatedCost
        )
    }
}

struct MenuBarUsageAggregate: Sendable {
    let usage: TokenUsage
    let estimatedCost: Decimal
    let toolCalls: Int
    let skillCalls: Int
}

private struct MenuBarAnalytics: Sendable {
    let days: [MenuBarDayMetrics]

    static let empty = MenuBarAnalytics(days: [])

    init(days: [MenuBarDayMetrics]) {
        self.days = days
    }

    init(snapshot: MenuBarMetricsSnapshot) {
        days = snapshot.days
    }

    var snapshot: MenuBarMetricsSnapshot {
        MenuBarMetricsSnapshot(days: days)
    }

    static func calculate(index: MetricsIndexSnapshot, calendar: Calendar = .current) -> Self {
        struct Bucket {
            var usage = TokenUsage.zero
            var estimatedCost = Decimal.zero
            var toolCalls = 0
            var skillCalls = 0
            var sessionIDs = Set<String>()
            var activeRuntime: TimeInterval = 0
        }

        // The popover only renders the current month and week. A short trailing
        // window covers a week crossing a month boundary without retaining years
        // of otherwise unused day records.
        let cutoff = calendar.date(byAdding: .day, value: -45, to: calendar.startOfDay(for: .now)) ?? .distantPast
        var buckets: [Date: Bucket] = [:]
        for contribution in index.days where contribution.day >= cutoff {
            let day = calendar.startOfDay(for: contribution.day)
            var bucket = buckets[day, default: Bucket()]
            bucket.usage = bucket.usage + contribution.usage
            bucket.estimatedCost += contribution.estimatedCost
            bucket.toolCalls += contribution.toolCalls
            bucket.skillCalls += contribution.skillCalls
            bucket.sessionIDs.insert(contribution.sessionID)
            bucket.activeRuntime += contribution.activeRuntime
            buckets[day] = bucket
        }

        return MenuBarAnalytics(days: buckets.map { day, bucket in
            MenuBarDayMetrics(
                day: day,
                usage: bucket.usage,
                estimatedCost: bucket.estimatedCost,
                toolCalls: bucket.toolCalls,
                skillCalls: bucket.skillCalls,
                sessions: bucket.sessionIDs.count,
                activeRuntime: bucket.activeRuntime
            )
        }.sorted { $0.day < $1.day })
    }

    func aggregate(in interval: DateInterval) -> MenuBarUsageAggregate {
        days.lazy
            .filter { interval.contains($0.day) }
            .reduce(MenuBarUsageAggregate(usage: .zero, estimatedCost: 0, toolCalls: 0, skillCalls: 0)) {
                MenuBarUsageAggregate(
                    usage: $0.usage + $1.usage,
                    estimatedCost: $0.estimatedCost + $1.estimatedCost,
                    toolCalls: $0.toolCalls + $1.toolCalls,
                    skillCalls: $0.skillCalls + $1.skillCalls
                )
            }
    }

    var periods: [PeriodMetric] {
        days.map {
            PeriodMetric(
                start: $0.day,
                usage: $0.usage,
                sessions: $0.sessions,
                activeRuntime: $0.activeRuntime,
                estimatedCost: $0.estimatedCost
            )
        }
    }
}


/// Aggregate result from typed SQL tables, matching the MetricsIndexAggregate
/// fields consumed by ContentView.
struct SQLProjectAggregate: Sendable {
    let usage: TokenUsage
    let estimatedCost: Decimal
    let costCoverage: Double
    let activeRuntime: TimeInterval
    let toolCalls: Int
    let skillCalls: Int
    let activeDays: Int
    let turnDurations: [TimeInterval]
    let firstTokenTimes: [TimeInterval]
    let tools: [ToolMetric]
    let skills: [SkillMetric]

    static let empty = SQLProjectAggregate(
        usage: .zero, estimatedCost: 0, costCoverage: 0, activeRuntime: 0,
        toolCalls: 0, skillCalls: 0, activeDays: 0,
        turnDurations: [], firstTokenTimes: [], tools: [], skills: []
    )
}

/// Per-session cost extracted from typed tables for project drill-down.
struct IndexedSessionCost: Sendable {
    let estimatedCost: Decimal
    let coveredTokens: Int64
    let totalTokens: Int64
}

@MainActor
final class DashboardStore: ObservableObject {
    enum Range: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
        case year = "Year"
        var id: String { rawValue }

        var granularity: PeriodGranularity {
            switch self {
            case .day: .day
            case .week: .week
            case .month: .month
            case .year: .year
            }
        }
    }

    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isEnriching = false
    @Published private(set) var isUpdatingAnalytics = false
    @Published private(set) var enrichedSessions = 0
    @Published private(set) var enrichmentTotal = 0
    @Published private(set) var subscription: SubscriptionSnapshot?
    @Published private(set) var bankedResets: BankedResetSnapshot?
    @Published private(set) var account: CodexAccountSnapshot?
    @Published private(set) var pricing: PricingHistory = .bundled
    @Published private(set) var pricingSource = "Bundled fallback"
    @Published private(set) var pricingUpdatedAt: Date?
    @Published private(set) var isRefreshingPricing = false
    @Published private(set) var isRebuildingHistory = false
    @Published private(set) var historySessionCount = 0
    @Published private(set) var historyMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var range: Range = .month
    private var activePage: DashboardPage = .overview
    @Published private(set) var codexHome: URL
    @Published private(set) var refreshInterval: TimeInterval
    @Published private(set) var weekStartsMonday: Bool {
        didSet { defaults.set(weekStartsMonday, forKey: "weekStartsMonday") }
    }
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?
    private var menuBarLoadTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var pricingTask: Task<Void, Never>?
    private var analyticsTask: Task<Void, Never>?
    private var rangeRefreshTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var bankedResetTask: Task<Void, Never>?
    private var sourceWatcher: CodexSourceWatcher?
    private var loadID = UUID()
    private var enrichmentID = UUID()
    private var analyticsID = UUID()
    private var analyticsWorkerID = UUID()
    private let userHome: URL
    private let historicalStore: HistoricalStore
    private let dynamicPricingLoader = DynamicPricingLoader()
    private var analytics = DashboardAnalytics.empty
    private var todayAnalytics = DashboardAnalytics.empty
    private var quotaWeekAnalytics = QuotaWeekAnalytics.empty
    private var menuBarAnalytics = MenuBarAnalytics.empty
    private var metricsIndex = MetricsIndexSnapshot.empty
    private var indexedSessionsByID: [String: IndexedSessionMetrics] = [:]
    @Published private(set) var menuBarDataIsResident = false
    @Published private(set) var dashboardDataIsResident = false

    init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard) {
        self.userHome = userHome
        self.historicalStore = HistoricalStore(userHome: userHome)
        self.defaults = defaults
        let savedPath = defaults.string(forKey: "codexDataPath")
        codexHome = savedPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? userHome.appendingPathComponent(".codex", isDirectory: true)
        let savedInterval = defaults.object(forKey: "metricsRefreshInterval") as? Double
        refreshInterval = savedInterval ?? 60
        range = Range(rawValue: defaults.string(forKey: "dashboardRange") ?? "") ?? .month
        weekStartsMonday = defaults.object(forKey: "weekStartsMonday") as? Bool ?? true
    }

    /// Calendar configured with the user's preferred first weekday for week bucketing.
    var analyticsCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartsMonday ? 2 : 1
        return calendar
    }

    func updateWeekStartsMonday(_ value: Bool) {
        guard value != weekStartsMonday else { return }
        weekStartsMonday = value
        scheduleAnalyticsRefresh()
    }

    var isBusy: Bool { isLoading || isEnriching || isRebuildingHistory }
    var enrichmentFraction: Double {
        enrichmentTotal > 0 ? Double(enrichedSessions) / Double(enrichmentTotal) : 0
    }
    var enrichmentLabel: String {
        "Parsing \(enrichedSessions.formatted()) of \(enrichmentTotal.formatted()) sessions"
    }
    var analyticsUpdateLabel: String { "Updating metrics…" }
    var codexHomeDisplayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return codexHome.path.replacingOccurrences(of: home, with: "~", options: [.anchored])
    }

    var filteredSessions: [SessionSummary] { analytics.filteredSessions }
    /// The project/session hierarchy is structural and independent of chart aggregation.
    var allProjects: [ProjectMetric] { analytics.allProjects }
    var projects: [ProjectMetric] { analytics.projects }
    var usage: TokenUsage { analytics.usage }
    var estimatedCost: Decimal { analytics.estimatedCost }
    var costCoverage: Double { analytics.costCoverage }
    var runtime: TimeInterval { analytics.runtime }
    var models: [ModelMetric] { analytics.models }
    var allTimeModels: [ModelMetric] { analytics.allTimeModels }
    var tools: [ToolMetric] { analytics.tools }
    var skills: [SkillMetric] { analytics.skills }
    var daily: [PeriodMetric] { analytics.daily }
    var weekly: [PeriodMetric] { analytics.weekly }
    var monthly: [PeriodMetric] { analytics.monthly }
    var yearly: [PeriodMetric] { analytics.yearly }
    var modelTrendPeriods: [ModelPeriodMetric] {
        switch range {
        case .day: analytics.modelDaily
        case .week: analytics.modelWeekly
        case .month: analytics.modelMonthly
        case .year: analytics.modelYearly
        }
    }
    var trendPeriods: [PeriodMetric] {
        switch range {
        case .day: daily
        case .week: weekly
        case .month: monthly
        case .year: yearly
        }
    }
    var pricingEffectiveDate: String {
        pricing.latestEffectiveDate?.formatted(.iso8601.year().month().day()) ?? "—"
    }
    var turnDurations: [TimeInterval] { analytics.turnDurations }
    var averageTTFT: TimeInterval? { analytics.averageTTFT }
    var activeDays: Int { analytics.activeDays }
    var toolCalls: Int { analytics.toolCalls }
    var skillCalls: Int { analytics.skillCalls }
    var completedTurns: Int { analytics.completedTurns }
    var abortedTurns: Int { analytics.abortedTurns }
    var todayUsage: TokenUsage { todayAnalytics.usage }
    var todayEstimatedCost: Decimal { todayAnalytics.estimatedCost }
    var todayToolCalls: Int { todayAnalytics.toolCalls }
    var todaySkillCalls: Int { todayAnalytics.skillCalls }
    var quotaWeekInterval: DateInterval? { quotaWeekAnalytics.interval }
    var quotaWeekUsage: TokenUsage { quotaWeekAnalytics.usage }
    var quotaWeekEstimatedCost: Decimal { quotaWeekAnalytics.estimatedCost }
    /// Loads the project aggregate directly from the typed SQL index.
    func loadProjectAggregate(path: String) async -> SQLProjectAggregate {
        let agg = (try? await historicalStore.aggregateDaily(projectPath: path)) ?? DailyAggregateResult()
        let tools = (try? await historicalStore.mergedTools(projectPath: path)) ?? []
        let skills = (try? await historicalStore.mergedSkills(projectPath: path)) ?? []

        return SQLProjectAggregate(
            usage: agg.usage,
            estimatedCost: Decimal(agg.estimatedCost),
            costCoverage: agg.usage.total > 0 ? Double(agg.coveredTokens) / Double(agg.usage.total) : 0,
            activeRuntime: agg.activeRuntime,
            toolCalls: agg.toolCalls,
            skillCalls: agg.skillCalls,
            activeDays: agg.activeDays,
            turnDurations: [],
            firstTokenTimes: [],
            tools: tools.map {
                ToolMetric(tool: $0.tool, calls: $0.calls, attributedCalls: $0.attributedCalls,
                           sessions: $0.sessions, attributedUsage: .zero, estimatedCost: Decimal($0.estimatedCost))
            },
            skills: skills.map {
                SkillMetric(skill: $0.skill, calls: $0.calls, attributedCalls: 0,
                            sessions: $0.sessions, attributedUsage: .zero, estimatedCost: 0)
            }
        )
    }

    func projectPeriods(path: String, granularity: PeriodGranularity, since startDate: Date? = nil) async -> [PeriodMetric] {
        guard let rows = try? await historicalStore.dailyPeriodRows(projectPath: path, since: startDate) else { return [] }
        return Self.bucketPeriodsFromRows(rows, granularity: granularity, calendar: analyticsCalendar)
    }

    func indexedSessionCosts(projectPath: String, sessionIDs: Set<String>? = nil) async -> [String: IndexedSessionCost] {
        let results: [String: (estimatedCost: Decimal, coveredTokens: Int64, totalTokens: Int64)]?
        if let sessionIDs {
            results = try? await historicalStore.sessionCosts(projectPath: projectPath, sessionIDs: sessionIDs)
        } else {
            results = try? await historicalStore.sessionCosts(projectPath: projectPath)
        }
        guard let results else { return [:] }
        return results.mapValues {
            IndexedSessionCost(estimatedCost: $0.estimatedCost, coveredTokens: $0.coveredTokens, totalTokens: $0.totalTokens)
        }
    }

    /// Loads the selected overview period directly from the typed SQL index.
    func periodAggregate(in interval: DateInterval) async -> SQLProjectAggregate {
        let aggregate = (try? await historicalStore.aggregateDaily(since: interval.start, before: interval.end)) ?? DailyAggregateResult()
        let durations = (try? await historicalStore.durationArrays(since: interval.start, before: interval.end)) ?? DurationArrays()
        return SQLProjectAggregate(
            usage: aggregate.usage,
            estimatedCost: Decimal(aggregate.estimatedCost),
            costCoverage: aggregate.usage.total > 0 ? Double(aggregate.coveredTokens) / Double(aggregate.usage.total) : 0,
            activeRuntime: aggregate.activeRuntime,
            toolCalls: aggregate.toolCalls,
            skillCalls: aggregate.skillCalls,
            activeDays: aggregate.activeDays,
            turnDurations: durations.turnDurations,
            firstTokenTimes: durations.firstTokenTimes,
            tools: [],
            skills: []
        )
    }

    static func bucketPeriodsFromRows(
        _ rows: [DailyPeriodRow], granularity: PeriodGranularity, calendar: Calendar? = nil
    ) -> [PeriodMetric] {
        let calendar = calendar ?? Calendar.current
        struct Bucket {
            var usage = TokenUsage.zero
            var sessions = Set<String>()
            var runtime: TimeInterval = 0
            var cost = 0.0
        }
        var buckets: [Date: Bucket] = [:]
        for row in rows {
            let start: Date
            switch granularity {
            case .day: start = calendar.startOfDay(for: row.day)
            case .week: start = calendar.dateInterval(of: .weekOfYear, for: row.day)?.start ?? calendar.startOfDay(for: row.day)
            case .month: start = calendar.dateInterval(of: .month, for: row.day)?.start ?? calendar.startOfDay(for: row.day)
            case .year: start = calendar.dateInterval(of: .year, for: row.day)?.start ?? calendar.startOfDay(for: row.day)
            }
            var bucket = buckets[start, default: Bucket()]
            bucket.usage = bucket.usage + row.usage
            bucket.sessions.insert("\(row.sessions)")
            bucket.runtime += row.activeRuntime
            bucket.cost += row.estimatedCost
            buckets[start] = bucket
        }
        return buckets.map { start, bucket in
            PeriodMetric(start: start, usage: bucket.usage, sessions: bucket.sessions.count,
                         activeRuntime: bucket.runtime, estimatedCost: Decimal(bucket.cost))
        }.sorted { $0.start < $1.start }
    }
    var menuBarDaily: [PeriodMetric] { menuBarAnalytics.periods }
    func menuBarAggregate(in interval: DateInterval) -> MenuBarUsageAggregate {
        menuBarAnalytics.aggregate(in: interval)
    }
    func sessionMetric(withID id: String) async throws -> SessionMetric? {
        try await historicalStore.session(withID: id)
    }

    func load() {
        dashboardDataIsResident = true
        menuBarDataIsResident = false
        menuBarLoadTask?.cancel()
        menuBarLoadTask = nil
        menuBarAnalytics = .empty
        loadTask?.cancel()
        enrichmentTask?.cancel()
        sourceWatcher?.stop()
        sourceWatcher = nil
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        let requestID = UUID()
        loadID = requestID
        enrichmentID = UUID()
        isLoading = true
        isEnriching = false
        enrichedSessions = 0
        enrichmentTotal = 0
        errorMessage = nil
        loadTask = Task {
            // A window lifecycle change or a manual restart can cancel this task.
            // Always release the loading screen when the active request stops.
            defer {
                if loadID == requestID {
                    isLoading = false
                }
            }
            let codexHome = self.codexHome
            // The status item should reflect quota immediately; do not make
            // it wait for the much heavier session merge and index load.
            let storedSubscription: SubscriptionSnapshot?
            do {
                let candidate = try await historicalStore.subscriptionSnapshot()
                storedSubscription = candidate?.isUsable == true ? candidate : nil
            } catch {
                storedSubscription = nil
            }
            _ = acceptSubscription(storedSubscription)
            var hadStoredHistory = false
            let indexed = (try? await Task.detached(priority: .userInitiated) {
                try CodexStore(codexHome: codexHome).loadIndexedSessions()
            }.value) ?? []
            guard !Task.isCancelled, loadID == requestID else { return }
            do {
                let merged = try await historicalStore.mergedSessionSummaries(with: indexed)
                sessions = merged
                pricing = try await historicalStore.pricingHistory()
                historySessionCount = try await historicalStore.sessionCount()
                hadStoredHistory = historySessionCount > 0
            } catch {
                sessions = indexed.map(\.summary)
                historyMessage = "Stored history could not be loaded: \(error.localizedDescription)"
            }
            scheduleAnalyticsRefresh()
            await startBackgroundRefreshIfNeeded(reconcileIfCursorMissing: hadStoredHistory)
            guard !Task.isCancelled, loadID == requestID else { return }
            isLoading = false
            startEnrichmentForAvailableHistory()
            refreshPricing()
            let cachedSubscription = ([
                storedSubscription,
                sessions.compactMap(\.subscription).filter(\.isUsable).max { $0.observedAt < $1.observedAt }
            ].compactMap { $0 }).max { $0.observedAt < $1.observedAt }
            if acceptSubscription(cachedSubscription) {
                scheduleAnalyticsRefresh()
            }
            // Older history does not contain parser-extracted quota snapshots.
            // Keep the bounded tail scan as a one-time compatibility fallback;
            // once a snapshot is persisted, future loads remain entirely in-memory.
            let latestSubscription = if cachedSubscription == nil {
                await Task.detached(priority: .utility) {
                    SubscriptionReader.latest(from: indexed)
                }.value
            } else {
                cachedSubscription
            }
            guard !Task.isCancelled, loadID == requestID else { return }
            if acceptSubscription(latestSubscription) {
                scheduleAnalyticsRefresh()
            }
            if let latestSubscription {
                try? await historicalStore.recordSubscription(latestSubscription)
            }
            account = await Task.detached(priority: .utility) {
                CodexAccountReader.read(from: codexHome)
            }.value
            refreshBankedResets(from: codexHome)
        }
    }

    func activateDashboard() {
        guard !dashboardDataIsResident else { return }
        load()
    }

    /// Loads only values that are safe to keep resident in the menu process.
    /// Full sessions and the detailed metric index are never decoded here.
    func loadMenuBar() {
        guard !dashboardDataIsResident else { return }
        loadTask?.cancel()
        menuBarLoadTask?.cancel()
        sourceWatcher?.stop()
        sourceWatcher = nil
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.loadID == requestID {
                    self.loadTask = nil
                    self.isLoading = false
                }
            }
            do {
                self.subscription = try await self.historicalStore.subscriptionSnapshot()
                guard !Task.isCancelled, self.loadID == requestID else { return }
            } catch {
                guard self.loadID == requestID else { return }
                self.historyMessage = "Menu-bar metrics could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    /// Loads data used only while the menu-bar popover is visible. The quota
    /// subscription remains separate because the status-item icon needs it.
    func loadMenuBarPopover() {
        guard !dashboardDataIsResident else { return }
        menuBarDataIsResident = true
        menuBarLoadTask?.cancel()
        menuBarLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.pricing = try await self.historicalStore.storedPricingHistory()
                guard !Task.isCancelled, self.menuBarDataIsResident else { return }
                self.historySessionCount = try await self.historicalStore.storedSessionCount()
                guard !Task.isCancelled, self.menuBarDataIsResident else { return }
                let requiresMigration = try await self.historicalStore.requiresLegacyMigration()
                guard !Task.isCancelled, self.menuBarDataIsResident else { return }
                if requiresMigration {
                    _ = await self.refreshMenuBarInBackground(changedPaths: [], requiresReconciliation: true)
                    guard !Task.isCancelled, self.menuBarDataIsResident else { return }
                    await self.reloadMenuBarSnapshot()
                    self.pricing = try await self.historicalStore.storedPricingHistory()
                } else if let snapshot = try await self.historicalStore.menuBarMetricsSnapshot() {
                    self.menuBarAnalytics = MenuBarAnalytics(snapshot: snapshot)
                } else if self.historySessionCount > 0 {
                    let calendar = self.analyticsCalendar
                    let cutoff = calendar.date(byAdding: .day, value: -45, to: calendar.startOfDay(for: .now)) ?? .distantPast
                    if let snapshot = try await self.historicalStore.menuBarMetricsFromDaily(since: cutoff) {
                        self.menuBarAnalytics = MenuBarAnalytics(snapshot: snapshot)
                        try? await self.historicalStore.recordMenuBarMetrics(snapshot)
                    }
                }
                let codexHome = self.codexHome
                self.account = await Task.detached(priority: .utility) {
                    CodexAccountReader.read(from: codexHome)
                }.value
                guard !Task.isCancelled, self.menuBarDataIsResident else { return }
                self.refreshBankedResets(from: codexHome)
                await self.startBackgroundRefreshIfNeeded()
            } catch {
                guard self.menuBarDataIsResident else { return }
                self.historyMessage = "Menu-bar metrics could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    func releaseMenuBarMemory() {
        guard !dashboardDataIsResident else { return }
        menuBarDataIsResident = false
        menuBarLoadTask?.cancel()
        menuBarLoadTask = nil
        sourceWatcher?.stop()
        sourceWatcher = nil
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        account = nil
        bankedResetTask?.cancel()
        bankedResetTask = nil
        bankedResets = nil
        menuBarAnalytics = .empty
        historySessionCount = 0
        historyMessage = nil
        Task { [weak self] in
            guard let self else { return }
            await self.historicalStore.releaseMemory()
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// Consumes the system-wide macOS filesystem journal. Normal refresh work is
    /// proportional to changed paths; all-session reconciliation occurs only when
    /// installing the watcher cursor or when macOS reports a journal gap.
    private func startBackgroundRefreshIfNeeded(reconcileIfCursorMissing: Bool? = nil) async {
        guard dashboardDataIsResident || menuBarDataIsResident,
              backgroundRefreshTask == nil,
              refreshInterval > 0 else { return }
        let codexHome = self.codexHome
        let storedEventID = try? await historicalStore.sourceEventID(for: codexHome)
        guard dashboardDataIsResident || menuBarDataIsResident,
              backgroundRefreshTask == nil,
              refreshInterval > 0,
              codexHome == self.codexHome else { return }
        let historyExists = reconcileIfCursorMissing ?? (historySessionCount > 0)
        let watcher: CodexSourceWatcher
        do {
            watcher = try CodexSourceWatcher(
                codexHome: codexHome,
                sinceEventID: storedEventID,
                latency: refreshInterval
            )
        } catch {
            historyMessage = "Automatic refresh unavailable: \(error.localizedDescription)"
            return
        }
        sourceWatcher = watcher

        backgroundRefreshTask = Task(priority: .background) { [weak self, watcher] in
            guard let self else {
                watcher.stop()
                return
            }
            defer {
                watcher.stop()
                if self.sourceWatcher === watcher { self.sourceWatcher = nil }
            }

            var pending: CodexSourceChangeBatch?
            var deferredEventID: UInt64?
            if storedEventID == nil, historyExists, self.dashboardDataIsResident {
                pending = CodexSourceChangeBatch(
                    rolloutPaths: [],
                    indexChanged: true,
                    requiresReconciliation: true,
                    latestEventID: watcher.startingEventID
                )
            } else if storedEventID == nil {
                // Start from the current journal position. The compact snapshot
                // is already authoritative for the menu bar; the next real
                // session event will trigger an incremental refresh.
                deferredEventID = watcher.startingEventID
                try? await self.historicalStore.recordSourceEventID(watcher.startingEventID, for: codexHome)
            }

            var iterator = watcher.events.makeAsyncIterator()
            var failures = 0
            var lastRefreshAt = Date.distantPast
            while !Task.isCancelled {
                if pending == nil {
                    guard await iterator.next() != nil else { return }
                    pending = watcher.takePendingBatch()
                }
                guard let batch = pending else { return }

                // Codex can touch state_5.sqlite (including its WAL/SHM files)
                // without creating or using a session. Do not turn that idle
                // housekeeping into a full source-index read and merge. Keep
                // the event ID in memory and commit it only alongside the next
                // real refresh, so an idle night also avoids cursor writes.
                if !batch.hasSessionActivity {
                    deferredEventID = max(deferredEventID ?? 0, batch.latestEventID)
                    pending = nil
                    continue
                }

                let process = ProcessInfo.processInfo
                if self.isLoading || self.isEnriching
                    || process.thermalState == .serious
                    || process.thermalState == .critical
                    || process.isLowPowerModeEnabled
                {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }

                // The old polling worker naturally limited refreshes to one
                // pass per configured interval. FSEvents is event-driven and
                // can deliver several file-level batches much sooner, so keep
                // the same disk-I/O budget explicitly while retaining precise
                // change detection.
                let minimumInterval = max(0.25, self.refreshInterval)
                let elapsed = Date.now.timeIntervalSince(lastRefreshAt)
                if elapsed < minimumInterval {
                    try? await Task.sleep(for: .seconds(minimumInterval - elapsed))
                    guard !Task.isCancelled else { return }
                }

                let changedPaths = batch.rolloutPaths
                let succeeded = await self.refreshInBackground(
                    changedPaths: changedPaths,
                    indexChanged: batch.indexChanged || batch.requiresReconciliation,
                    requiresReconciliation: batch.requiresReconciliation
                )
                guard !Task.isCancelled else { return }
                lastRefreshAt = .now
                if succeeded {
                    let committedEventID = max(deferredEventID ?? 0, batch.latestEventID)
                    try? await self.historicalStore.recordSourceEventID(committedEventID, for: codexHome)
                    deferredEventID = nil
                    pending = nil
                    failures = 0
                } else {
                    failures += 1
                    let baseDelay = min(300, max(1, Int(self.refreshInterval)) * (1 << min(failures, 3)))
                    let jitter = Int.random(in: 0...min(10, max(1, baseDelay / 8)))
                    try? await Task.sleep(for: .seconds(baseDelay + jitter))
                }
            }
        }
    }

    private func refreshInBackground(
        changedPaths: Set<String>,
        indexChanged: Bool,
        requiresReconciliation: Bool
    ) async -> Bool {
        guard !isLoading, !isEnriching else { return true }
        if !dashboardDataIsResident {
            guard menuBarDataIsResident else { return true }
            return await refreshMenuBarInBackground(
                changedPaths: changedPaths,
                requiresReconciliation: requiresReconciliation
            )
        }
        do {
            let previousIDs = Set(sessions.map(\.id))
            var pathsNeedingEnrichment = changedPaths
            if indexChanged || requiresReconciliation {
                let existingByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
                let codexHome = self.codexHome
                let indexed: [SessionMetric] = (try? await Task.detached(priority: .background) { () throws -> [SessionMetric] in
                    let store = CodexStore(codexHome: codexHome)
                    let indexed: [SessionMetric]
                    if requiresReconciliation {
                        indexed = try store.loadIndexedSessions(reconcile: true)
                    } else {
                        indexed = try store.loadIndexedSessionChanges()
                    }
                    return indexed
                }.value) ?? []
                for session in indexed where !session.rolloutPath.isEmpty {
                    guard let existing = existingByID[session.id] else {
                        pathsNeedingEnrichment.insert(session.rolloutPath)
                        continue
                    }
                    if !existing.enrichmentAvailable || existing.updatedAt < session.updatedAt {
                        pathsNeedingEnrichment.insert(session.rolloutPath)
                    }
                }
                if requiresReconciliation {
                    sessions = try await historicalStore.mergedSessionSummaries(with: indexed)
                } else if !indexed.isEmpty {
                    let merged = try await historicalStore.mergedSessionSummaries(for: indexed)
                    var updatedSessions = sessions
                    var positions = Dictionary(
                        uniqueKeysWithValues: updatedSessions.indices.map { (updatedSessions[$0].id, $0) }
                    )
                    for summary in merged {
                        if let position = positions[summary.id] {
                            updatedSessions[position] = summary
                        } else {
                            positions[summary.id] = updatedSessions.count
                            updatedSessions.append(summary)
                        }
                    }
                    sessions = updatedSessions.sorted { $0.updatedAt > $1.updatedAt }
                }
            }
            let candidates = sessions.filter { session in
                (pathsNeedingEnrichment.contains(session.rolloutPath) || !previousIDs.contains(session.id)) && !session.enrichmentAvailable
            }
            guard !candidates.isEmpty else {
                if indexChanged || requiresReconciliation { scheduleAnalyticsRefresh() }
                return true
            }

            var enriched: [SessionMetric] = []
            enriched.reserveCapacity(candidates.count)
            for await progress in CodexStore(codexHome: codexHome).enrichmentStream(candidates) {
                guard !Task.isCancelled else { return true }
                enriched.append(progress.session)
            }
            guard !enriched.isEmpty else { return true }
            historySessionCount = try await historicalStore.record(enriched, pricing: pricing)
            _ = try await historicalStore.updateMetricsIndex(for: enriched, pricing: pricing)
            let enrichedByID = Dictionary(uniqueKeysWithValues: enriched.map { ($0.id, $0.summary) })
            sessions = sessions.map { enrichedByID[$0.id] ?? $0 }
            scheduleAnalyticsRefresh()
            let latestSubscription = enriched.compactMap(\.subscription).max { $0.observedAt < $1.observedAt }
            if acceptSubscription(latestSubscription) {
                scheduleAnalyticsRefresh()
                if let latestSubscription {
                    try? await historicalStore.recordSubscription(latestSubscription)
                }
            }
            return true
        } catch {
            // Quiet refresh failures are isolated and retried with exponential backoff.
            return false
        }
    }

    /// Refreshes durable history and the small menu-bar projection without
    /// assigning the full session graph to any long-lived app property.
    private func refreshMenuBarInBackground(
        changedPaths: Set<String>,
        requiresReconciliation: Bool
    ) async -> Bool {
        return await performMenuBarRefreshInProcess(
            changedPaths: changedPaths,
            requiresReconciliation: requiresReconciliation
        )
    }

    private func performMenuBarRefreshInProcess(
        changedPaths: Set<String>,
        requiresReconciliation: Bool
    ) async -> Bool {
        do {
            let codexHome = self.codexHome
            let indexed: [SessionMetric] = (try? await Task.detached(priority: .background) { () throws -> [SessionMetric] in
                let store = CodexStore(codexHome: codexHome)
                let indexed: [SessionMetric]
                if requiresReconciliation {
                    indexed = try store.loadIndexedSessions(reconcile: true)
                } else {
                    var changes = try store.loadIndexedSessionChanges()
                    let knownPaths = Set(changes.map(\.rolloutPath))
                    let missingPaths = changedPaths.subtracting(knownPaths)
                    if !missingPaths.isEmpty {
                        changes.append(contentsOf: try store.loadIndexedSessions(forRolloutPaths: missingPaths))
                    }
                    indexed = changes
                }
                return indexed
            }.value) ?? []
            guard !Task.isCancelled, dashboardDataIsResident || menuBarDataIsResident else { return true }

            let merged = requiresReconciliation
                ? try await historicalStore.mergedSessionSummaries(with: indexed)
                : try await historicalStore.mergedSessionSummaries(for: indexed)
            let historicalIDs = Set(merged.lazy.filter(\.enrichmentAvailable).map(\.id))
            let candidates = merged.filter { session in
                (changedPaths.contains(session.rolloutPath) || !historicalIDs.contains(session.id)) && !session.enrichmentAvailable
            }
            var enriched: [SessionMetric] = []
            if !candidates.isEmpty {
                enriched.reserveCapacity(candidates.count)
                for await progress in CodexStore(codexHome: codexHome).enrichmentStream(candidates) {
                    guard !Task.isCancelled, dashboardDataIsResident || menuBarDataIsResident else { return true }
                    enriched.append(progress.session)
                }
                if !enriched.isEmpty {
                    historySessionCount = try await historicalStore.record(enriched, pricing: pricing)
                    _ = try await historicalStore.updateMetricsIndex(for: enriched, pricing: pricing)
                }
            }

            let index = try await historicalStore.metricsIndex(pricing: pricing)
            let compact = await Task.detached(priority: .background) {
                MenuBarAnalytics.calculate(index: index)
            }.value
            guard !Task.isCancelled, dashboardDataIsResident || menuBarDataIsResident else { return true }
            if menuBarDataIsResident {
                menuBarAnalytics = compact
            }
            try await historicalStore.recordMenuBarMetrics(compact.snapshot)

            let latestSubscription = SubscriptionReader.latestCached(from: enriched.isEmpty ? indexed : enriched)
            if acceptSubscription(latestSubscription), let latestSubscription {
                try? await historicalStore.recordSubscription(latestSubscription)
            }
            await historicalStore.releaseMemory()
            malloc_zone_pressure_relief(nil, 0)
            return true
        } catch {
            await historicalStore.releaseMemory()
            malloc_zone_pressure_relief(nil, 0)
            return false
        }
    }

    private func reloadMenuBarSnapshot() async {
        if let snapshot = try? await historicalStore.menuBarMetricsSnapshot() {
            menuBarAnalytics = MenuBarAnalytics(snapshot: snapshot)
        }
        if let snapshot = try? await historicalStore.subscriptionSnapshot() {
            _ = acceptSubscription(snapshot)
        }
        historySessionCount = (try? await historicalStore.storedSessionCount()) ?? historySessionCount
    }

    private func startEnrichmentForAvailableHistory() {
        guard !isEnriching else { return }
        let requestID = UUID()
        enrichmentID = requestID
        let candidates = sessions.filter { session in
            !session.enrichmentAvailable
        }
        enrichedSessions = 0
        enrichmentTotal = candidates.count
        guard !candidates.isEmpty else {
            isEnriching = false
            return
        }

        isEnriching = true
        let indexByID = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset) })
        enrichmentTask = Task {
            let stream = CodexStore(codexHome: codexHome).enrichmentStream(candidates)
            var pending: [(index: Int, session: SessionMetric)] = []
            pending.reserveCapacity(50)
            for await progress in stream {
                guard !Task.isCancelled, enrichmentID == requestID else { return }
                if let index = indexByID[progress.session.id] {
                    pending.append((index, progress.session))
                }
                // A single published array mutation invalidates every aggregate and
                // chart. Batch results so parsing cannot outrun SwiftUI rendering.
                if pending.count >= 50 || progress.completed == progress.total {
                    var updated = sessions
                    for item in pending { updated[item.index] = item.session.summary }
                    do {
                        historySessionCount = try await historicalStore.record(
                            pending.map(\.session),
                            pricing: pricing
                        )
                        _ = try await historicalStore.updateMetricsIndex(
                            for: pending.map(\.session),
                            pricing: pricing
                        )
                    } catch {
                        historyMessage = "History could not be saved: \(error.localizedDescription)"
                    }
                    sessions = updated
                    let latestSubscription = pending.compactMap(\.session.subscription).max { $0.observedAt < $1.observedAt }
                    if acceptSubscription(latestSubscription), let latestSubscription {
                        try? await historicalStore.recordSubscription(latestSubscription)
                    }
                    scheduleAnalyticsRefresh()
                    pending.removeAll(keepingCapacity: true)
                    enrichedSessions = progress.completed
                    enrichmentTotal = progress.total
                }
            }
            if !pending.isEmpty {
                var updated = sessions
                for item in pending { updated[item.index] = item.session.summary }
                do {
                    historySessionCount = try await historicalStore.record(
                        pending.map(\.session),
                        pricing: pricing
                    )
                    _ = try await historicalStore.updateMetricsIndex(
                        for: pending.map(\.session),
                        pricing: pricing
                    )
                } catch {
                    historyMessage = "History could not be saved: \(error.localizedDescription)"
                }
                sessions = updated
                let latestSubscription = pending.compactMap(\.session.subscription).max { $0.observedAt < $1.observedAt }
                if acceptSubscription(latestSubscription), let latestSubscription {
                    try? await historicalStore.recordSubscription(latestSubscription)
                }
                scheduleAnalyticsRefresh()
                pending.removeAll(keepingCapacity: true)
            }
            guard !Task.isCancelled, enrichmentID == requestID else { return }
            isEnriching = false
            // Pick up sessions added while the current scan was running.
            let remaining = sessions.filter { !$0.enrichmentAvailable }
            if !remaining.isEmpty && remaining.count < candidates.count {
                startEnrichmentForAvailableHistory()
            }
        }
    }

    /// Apply a range selected by the view after SwiftUI has finished the current
    /// update transaction. The Picker must not write directly to an @Published
    /// property, because that can publish while the view tree is being updated.
    func updateRange(_ newRange: Range) {
        rangeRefreshTask?.cancel()
        guard newRange != range else { return }
        defaults.set(newRange.rawValue, forKey: "dashboardRange")
        rangeRefreshTask = Task { [weak self] in
            // A short delay crosses the current AppKit/SwiftUI run-loop turn.
            try? await Task.sleep(for: .milliseconds(1))
            guard let self, !Task.isCancelled else { return }
            guard self.range != newRange else { return }
            self.range = newRange
        }
    }

    func updatePage(_ page: DashboardPage) {
        guard activePage != page else { return }
        activePage = page
        scheduleAnalyticsRefresh()
    }

    private func scheduleAnalyticsRefresh() {
        guard dashboardDataIsResident else { return }
        analyticsID = UUID()

        // Keep a single calculator alive and let it consume the newest snapshot.
        // Cancelling a task that is awaiting Task.detached does not cancel that
        // detached calculation, which previously allowed one CPU-heavy calculator
        // per enrichment batch to pile up in the background.
        guard analyticsTask == nil else { return }
        isUpdatingAnalytics = true
        let workerID = UUID()
        analyticsWorkerID = workerID

        analyticsTask = Task {
            defer {
                if analyticsWorkerID == workerID {
                    analyticsTask = nil
                    isUpdatingAnalytics = false
                }
            }
            while !Task.isCancelled {
                let requestID = analyticsID

                // Wait for a quiet moment. If another batch arrives during this
                // window, discard this request before doing any expensive work.
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { break }
                guard analyticsID == requestID else { continue }

                let feedbackStartedAt = ContinuousClock.now
                let sessions = sessions
                let page = activePage
                let granularity = range.granularity
                let weeklyQuotaWindow = subscription?.windows.first { $0.windowMinutes == 10_080 }

                // Fully SQL path: typed tables answer every dashboard question
                // without decoding any JSON blobs.
                let aggregate = (try? await historicalStore.aggregateDaily()) ?? DailyAggregateResult()
                let periodRows = (page == .overview || page == .billing)
                    ? ((try? await historicalStore.dailyPeriodRows()) ?? [])
                    : []
                let modelRows = (page == .overview || page == .models)
                    ? ((try? await historicalStore.dailyModelRows()) ?? [])
                    : []
                let tools = page == .overview
                    ? ((try? await historicalStore.mergedTools()) ?? [])
                    : []
                let skills = page == .overview
                    ? ((try? await historicalStore.mergedSkills()) ?? [])
                    : []
                let todayStart = analyticsCalendar.startOfDay(for: .now)
                let todayAggregateResult = (try? await historicalStore.aggregateDaily(since: todayStart)) ?? DailyAggregateResult()

                var quotaWeekResult = QuotaWeekAnalytics.empty
                if let window = weeklyQuotaWindow {
                    let interval = DateInterval(
                        start: window.resetsAt.addingTimeInterval(-TimeInterval(window.windowMinutes * 60)),
                        end: window.resetsAt
                    )
                    if let agg = try? await historicalStore.aggregateDaily(since: interval.start, before: interval.end) {
                        quotaWeekResult = QuotaWeekAnalytics(interval: interval, usage: agg.usage, estimatedCost: Decimal(agg.estimatedCost))
                    }
                }

                let analyticsCalendar = self.analyticsCalendar
                let refreshed = await Task.detached(priority: .userInitiated) {
                    let calendar = analyticsCalendar
                    var selected = DashboardAnalytics.fromSQLResults(
                        sessions: page == .overview || page == .projects ? sessions : [],
                        startDate: nil,
                        aggregate: aggregate,
                        periodRows: periodRows,
                        modelRows: modelRows,
                        allTimeModels: page == .models
                            ? DashboardAnalytics.mergeModelRowsPublic(modelRows)
                            : [],
                        tools: tools.map { tool in
                            ToolMetric(tool: tool.tool, calls: tool.calls, attributedCalls: tool.attributedCalls,
                                       sessions: tool.sessions, attributedUsage: .zero,
                                       estimatedCost: Decimal(tool.estimatedCost))
                        },
                        skills: skills.map { skill in
                            SkillMetric(skill: skill.skill, calls: skill.calls, attributedCalls: 0,
                                        sessions: skill.sessions, attributedUsage: .zero,
                                        estimatedCost: 0)
                        },
                        granularity: granularity,
                        calendar: calendar
                    )
                    selected.abortedTurns = 0
                    let todayAggregate = todayAggregateResult
                    let today = DashboardAnalytics(
                        filteredSessions: [], allProjects: [], projects: [],
                        usage: todayAggregate.usage,
                        estimatedCost: Decimal(todayAggregate.estimatedCost),
                        costCoverage: 0, runtime: 0,
                        models: [], allTimeModels: [], tools: [], skills: [],
                        daily: [], weekly: [], monthly: [], yearly: [],
                        modelDaily: [], modelWeekly: [], modelMonthly: [], modelYearly: [],
                        turnDurations: [], averageTTFT: nil, activeDays: 0,
                        toolCalls: todayAggregate.toolCalls, skillCalls: todayAggregate.skillCalls,
                        completedTurns: 0, abortedTurns: 0
                    )
                    let quotaWeek = quotaWeekResult
                    return (selected, today, quotaWeek)
                }.value

                let minimumFeedback = Duration.milliseconds(180)
                let elapsed = feedbackStartedAt.duration(to: .now)
                if elapsed < minimumFeedback {
                    try? await Task.sleep(for: minimumFeedback - elapsed)
                }
                guard !Task.isCancelled else { break }

                // Always publish a completed, internally consistent snapshot. If a
                // newer batch arrived while it was being calculated, immediately
                // loop and catch up. Discarding every superseded result can starve
                // the dashboard forever while an active rollout keeps growing.
                analytics = refreshed.0
                todayAnalytics = refreshed.1
                quotaWeekAnalytics = refreshed.2
                guard analyticsID != requestID else { return }
            }
        }
    }

    /// Quota files can briefly expose an older complete line while a newer line is
    /// still being appended. Never let a refresh regress the menu-bar snapshot.
    @discardableResult
    private func acceptSubscription(_ candidate: SubscriptionSnapshot?) -> Bool {
        guard let candidate, candidate.isUsable else { return false }
        if let current = subscription, candidate.observedAt < current.observedAt {
            return false
        }
        guard subscription != candidate else { return false }
        subscription = candidate
        return true
    }

    private func refreshBankedResets(from codexHome: URL) {
        bankedResetTask?.cancel()
        bankedResetTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                await BankedResetReader.latest(from: codexHome)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.bankedResets = snapshot
        }
    }

    func updateCodexHome(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard standardized != codexHome else { return }
        codexHome = standardized
        subscription = nil
        bankedResetTask?.cancel()
        bankedResets = nil
        account = nil
        quotaWeekAnalytics = .empty
        metricsIndex = .empty
        indexedSessionsByID = [:]
        UserDefaults.standard.set(standardized.path, forKey: "codexDataPath")
        if dashboardDataIsResident { load() } else { loadMenuBar() }
    }

    /// Called when the dashboard window closes. The menu-bar UI only needs daily
    /// totals and quota/account metadata, so release enriched sessions and all
    /// dashboard-only projections until the dashboard is opened again.
    func releaseDashboardMemory() {
        guard dashboardDataIsResident else { return }
        dashboardDataIsResident = false
        loadTask?.cancel()
        loadTask = nil
        sourceWatcher?.stop()
        sourceWatcher = nil
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
        analyticsTask?.cancel()
        analyticsTask = nil
        analyticsWorkerID = UUID()
        rangeRefreshTask?.cancel()
        rangeRefreshTask = nil
        isLoading = false
        isEnriching = false
        isUpdatingAnalytics = false
        enrichedSessions = 0
        enrichmentTotal = 0
        if !metricsIndex.days.isEmpty {
            if menuBarDataIsResident {
                menuBarAnalytics = MenuBarAnalytics.calculate(index: metricsIndex)
            }
        }
        sessions = []
        analytics = .empty
        todayAnalytics = .empty
        quotaWeekAnalytics = .empty
        metricsIndex = .empty
        indexedSessionsByID = [:]
        if !menuBarDataIsResident {
            account = nil
            bankedResetTask?.cancel()
            bankedResetTask = nil
            bankedResets = nil
            menuBarAnalytics = .empty
            historySessionCount = 0
        }
        URLCache.shared.removeAllCachedResponses()
        Task { [weak self] in
            guard let self else { return }
            await self.historicalStore.releaseMemory()
            // The dashboard's short-lived arrays can leave empty malloc pages in
            // the process footprint. Return those pages now instead of waiting
            // for system-wide memory pressure.
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    func resetCodexHome() {
        updateCodexHome(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        guard interval != refreshInterval else { return }
        refreshInterval = interval
        UserDefaults.standard.set(interval, forKey: "metricsRefreshInterval")
        sourceWatcher?.stop()
        sourceWatcher = nil
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        Task { [weak self] in
            await self?.startBackgroundRefreshIfNeeded()
        }
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.title = "Export Codex Metric History"
        panel.nameFieldStringValue = "CodexDashboard-History-\(Date.now.formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                try await historicalStore.export(to: destination)
                historyMessage = "Exported \(historySessionCount.formatted()) sessions to \(destination.lastPathComponent)."
                if !dashboardDataIsResident { await historicalStore.releaseMemory() }
            } catch {
                historyMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func preserveAllHistory() {
        historyMessage = "Scanning all available rollouts; parsed metrics will be added to durable history."
        if dashboardDataIsResident {
            startEnrichmentForAvailableHistory()
        } else {
            Task { [weak self] in
                guard let self else { return }
                if await self.refreshMenuBarInBackground(changedPaths: [], requiresReconciliation: true) {
                    await self.reloadMenuBarSnapshot()
                    self.historyMessage = "Durable history is up to date."
                } else {
                    self.historyMessage = "History scan failed."
                }
            }
        }
    }

    func rebuildHistoryIndex() {
        guard !isRebuildingHistory else { return }
        isRebuildingHistory = true
        historyMessage = "Rebuilding the history index…"
        Task { [weak self] in
            guard let self else { return }
            defer { isRebuildingHistory = false }
            do {
                let rebuilt = try await historicalStore.rebuildMetricsIndex(
                    pricing: pricing,
                    calendar: analyticsCalendar
                )
                metricsIndex = rebuilt
                indexedSessionsByID = Dictionary(uniqueKeysWithValues: rebuilt.sessions.map { ($0.sessionID, $0) })
                historyMessage = "History index rebuilt for (rebuilt.sessions.count.formatted()) sessions."
                scheduleAnalyticsRefresh()
            } catch {
                historyMessage = "History index rebuild failed: (error.localizedDescription)"
            }
        }
    }

    func refreshPricing(force: Bool = false) {
        pricingTask?.cancel()
        isRefreshingPricing = true
        pricingTask = Task {
            defer { isRefreshingPricing = false }
            do {
                let snapshot = try await dynamicPricingLoader.refresh(force: force)
                guard !Task.isCancelled else { return }
                var mergedPrices = pricing.schedules.last?.prices ?? PricingRegistry.current.prices
                for (model, price) in snapshot.prices { mergedPrices[model] = price }
                if mergedPrices != pricing.schedules.last?.prices {
                    pricing = pricing.merging(PricingHistory(schedules: [
                        PricingSchedule(effectiveAt: snapshot.fetchedAt, prices: mergedPrices, source: "models.dev")
                    ]))
                    scheduleAnalyticsRefresh()
                    try await historicalStore.recordPricing(pricing)
                    if !dashboardDataIsResident, menuBarDataIsResident,
                       await refreshMenuBarInBackground(changedPaths: [], requiresReconciliation: true) {
                        await reloadMenuBarSnapshot()
                    }
                }
                pricingSource = snapshot.fromCache ? "models.dev cache" : "models.dev"
                pricingUpdatedAt = snapshot.fetchedAt
            } catch {
                pricingSource = "Bundled fallback"
                historyMessage = "Dynamic pricing unavailable: \(error.localizedDescription)"
            }
        }
    }

    func importHistory() {
        let panel = NSOpenPanel()
        panel.title = "Import Codex Metric History"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task {
            do {
                let imported = try await historicalStore.importArchive(from: source)
                historyMessage = "Imported \(imported.formatted()) sessions from \(source.lastPathComponent)."
                await historicalStore.releaseMemory()
                if dashboardDataIsResident { load() } else { loadMenuBar() }
            } catch {
                historyMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}
