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
        periods: [PeriodMetric],
        modelPeriods: [ModelPeriodMetric],
        models: [ModelMetric],
        allTimeModels: [ModelMetric],
        tools: [ToolMetric],
        skills: [SkillMetric],
        granularity: PeriodGranularity = .month,
        turnDurations: [TimeInterval] = [],
        firstTokenTimes: [TimeInterval] = []
    ) -> DashboardAnalytics {
        let filtered = sessions.filter { session in
            startDate.map { session.updatedAt >= $0 } ?? true
        }
        // Keep only the projection selected by the dashboard. Building all four
        // granularities here multiplied the chart data retained by the store,
        // even though each page renders one granularity at a time.
        let usage = aggregate.usage
        return DashboardAnalytics(
            filteredSessions: filtered,
            allProjects: Analytics.projects(from: sessions),
            projects: Analytics.projects(from: filtered),
            usage: usage,
            estimatedCost: Decimal(aggregate.estimatedCost),
            costCoverage: usage.total > 0 ? Double(aggregate.coveredTokens) / Double(usage.total) : 0,
            runtime: aggregate.activeRuntime,
            models: models,
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
    @Published private(set) var weekStartsMonday: Bool {
        didSet { defaults.set(weekStartsMonday, forKey: DashboardPreferences.weekStartsMondayKey) }
    }
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var pricingTask: Task<Void, Never>?
    private var analyticsTask: Task<Void, Never>?
    private var rangeRefreshTask: Task<Void, Never>?
    private var bankedResetTask: Task<Void, Never>?
    private var loadID = UUID()
    private var enrichmentID = UUID()
    private var analyticsID = UUID()
    private var analyticsWorkerID = UUID()
    private let userHome: URL
    private let historicalStore: HistoricalStore
    private let dynamicPricingLoader = DynamicPricingLoader()
    @Published private var analytics = DashboardAnalytics.empty
    private var todayAnalytics = DashboardAnalytics.empty
    private var quotaWeekAnalytics = QuotaWeekAnalytics.empty
    private var metricsIndex = MetricsIndexSnapshot.empty
    private var indexedSessionsByID: [String: IndexedSessionMetrics] = [:]
    @Published private(set) var dashboardDataIsResident = false
    private(set) var subscriptionProvider: DashboardSubscriptionProvider

    init(
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        codexHome launchCodexHome: URL? = nil
    ) {
        self.userHome = userHome
        self.historicalStore = HistoricalStore(userHome: userHome)
        self.defaults = defaults
        let savedPath = defaults.string(forKey: DashboardPreferences.codexDataPathKey)
        codexHome = launchCodexHome
            ?? savedPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? userHome.appendingPathComponent(".codex", isDirectory: true)
        subscriptionProvider = DashboardPreferences.subscriptionProvider(defaults: defaults)
        range = Range(rawValue: defaults.string(forKey: DashboardPreferences.dashboardRangeKey) ?? "") ?? .month
        weekStartsMonday = defaults.object(forKey: DashboardPreferences.weekStartsMondayKey) as? Bool ?? true
    }

    /// Calendar configured with the user's preferred first weekday for week bucketing.
    var analyticsCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartsMonday ? 2 : 1
        return calendar
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
        (try? await historicalStore.periodMetrics(
            projectPath: path,
            since: startDate,
            granularity: granularity,
            calendar: analyticsCalendar
        )) ?? []
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
            var sessionIDs = Set<String>()
            var fallbackSessionCount = 0
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
            bucket.sessionIDs.formUnion(row.sessionIDs)
            bucket.fallbackSessionCount += row.sessions
            bucket.runtime += row.activeRuntime
            bucket.cost += row.estimatedCost
            buckets[start] = bucket
        }
        return buckets.map { start, bucket in
            let sessions = bucket.sessionIDs.isEmpty ? bucket.fallbackSessionCount : bucket.sessionIDs.count
            return PeriodMetric(start: start, usage: bucket.usage, sessions: sessions,
                                activeRuntime: bucket.runtime, estimatedCost: Decimal(bucket.cost))
        }.sorted { $0.start < $1.start }
    }
    func sessionMetric(withID id: String) async throws -> SessionMetric? {
        try await historicalStore.session(withID: id)
    }

    func load() {
        dashboardDataIsResident = true
        loadTask?.cancel()
        enrichmentTask?.cancel()
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
            let provider = self.subscriptionProvider
            let cliProxyAPIConfiguration = DashboardPreferences.cliProxyAPIConfiguration(defaults: defaults)
            // The status item should reflect quota immediately; do not make
            // it wait for the much heavier session merge and index load.
            let storedSubscription: SubscriptionSnapshot?
            if provider == .default {
                do {
                    let candidate = try await historicalStore.subscriptionSnapshot()
                    storedSubscription = candidate?.isUsable == true ? candidate : nil
                } catch {
                    storedSubscription = nil
                }
            } else {
                storedSubscription = nil
            }
            _ = acceptSubscription(storedSubscription)
            let liveData: CLIProxyAPILiveSnapshot? = await Task.detached(priority: .utility) {
                switch provider {
                case .default:
                    return CLIProxyAPILiveSnapshot(
                        subscription: await SubscriptionReader.live(from: codexHome),
                        account: nil
                    )
                case .cliProxyAPI:
                    guard let cliProxyAPIConfiguration else { return nil }
                    return await CLIProxyAPIReader.liveData(using: cliProxyAPIConfiguration)
                }
            }.value
            guard !Task.isCancelled, loadID == requestID else { return }
            if provider == .cliProxyAPI {
                account = liveData?.account
            }
            let liveSubscription = liveData?.subscription
            if let liveSubscription, liveSubscription.isUsable {
                if provider == .default {
                    try? await historicalStore.recordSubscription(liveSubscription)
                }
                _ = acceptSubscription(liveSubscription)
            }
            let indexed = (try? await Task.detached(priority: .userInitiated) {
                try CodexStore(codexHome: codexHome).loadIndexedSessions()
            }.value) ?? []
            guard !Task.isCancelled, loadID == requestID else { return }
            do {
                let merged = try await historicalStore.mergedSessionSummaries(with: indexed)
                sessions = merged
                pricing = try await historicalStore.pricingHistory()
                historySessionCount = try await historicalStore.sessionCount()
            } catch {
                sessions = indexed.map(\.summary)
                historyMessage = "Stored history could not be loaded: \(error.localizedDescription)"
            }
            scheduleAnalyticsRefresh()
            guard !Task.isCancelled, loadID == requestID else { return }
            isLoading = false
            startEnrichmentForAvailableHistory()
            refreshPricing()
            let cachedSubscription = provider == .default
                ? ([
                    storedSubscription,
                    sessions.compactMap(\.subscription).filter(\.isUsable).max { $0.observedAt < $1.observedAt }
                ].compactMap { $0 }).max { $0.observedAt < $1.observedAt }
                : nil
            if acceptSubscription(cachedSubscription) {
                scheduleAnalyticsRefresh()
            }
            // Older history does not contain parser-extracted quota snapshots.
            // Keep the bounded tail scan as a one-time compatibility fallback;
            // once a snapshot is persisted, future loads remain entirely in-memory.
            let latestSubscription = if provider == .default, cachedSubscription == nil {
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
            if provider == .default, let latestSubscription {
                try? await historicalStore.recordSubscription(latestSubscription)
            }
            if provider == .default {
                account = await Task.detached(priority: .utility) {
                    CodexAccountReader.read(from: codexHome)
                }.value
            }
            refreshBankedResets(from: codexHome)
        }
    }

    func activateDashboard() {
        guard !dashboardDataIsResident else { return }
        load()
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
        defaults.set(newRange.rawValue, forKey: DashboardPreferences.dashboardRangeKey)
        rangeRefreshTask = Task { [weak self] in
            // A short delay crosses the current AppKit/SwiftUI run-loop turn.
            try? await Task.sleep(for: .milliseconds(1))
            guard let self, !Task.isCancelled else { return }
            guard self.range != newRange else { return }
            self.range = newRange
            self.scheduleAnalyticsRefresh()
        }
    }

    func applySettings(
        codexDataPath: String?,
        refreshInterval _: TimeInterval?,
        weekStartsMonday newWeekStartsMonday: Bool?
    ) {
        let newSubscriptionProvider = DashboardPreferences.subscriptionProvider(defaults: defaults)
        let providerChanged = newSubscriptionProvider != subscriptionProvider
        if providerChanged {
            subscriptionProvider = newSubscriptionProvider
            subscription = nil
            account = nil
            bankedResetTask?.cancel()
            bankedResetTask = nil
            bankedResets = nil
        }

        var pathChanged = false
        if let codexDataPath,
           !codexDataPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let newCodexHome = URL(
                fileURLWithPath: (codexDataPath as NSString).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
            if newCodexHome != codexHome {
                codexHome = newCodexHome
                defaults.set(newCodexHome.path, forKey: DashboardPreferences.codexDataPathKey)
                pathChanged = true
            }
        }

        var weekStartChanged = false
        if let newWeekStartsMonday, newWeekStartsMonday != weekStartsMonday {
            weekStartsMonday = newWeekStartsMonday
            weekStartChanged = true
        }

        if pathChanged || providerChanged || subscriptionProvider == .cliProxyAPI {
            load()
        }
        if weekStartChanged, !pathChanged {
            scheduleAnalyticsRefresh()
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
                    ? ((try? await historicalStore.periodMetrics(granularity: granularity, calendar: self.analyticsCalendar)) ?? [])
                    : []
                let modelRows = (page == .overview || page == .models)
                    ? ((try? await historicalStore.modelPeriodMetrics(granularity: granularity, calendar: self.analyticsCalendar)) ?? [])
                    : []
                let models = (page == .overview || page == .models)
                    ? ((try? await historicalStore.modelMetrics()) ?? [])
                    : []
                let allTimeModels = page == .models ? models : []
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

                let refreshed = await Task.detached(priority: .userInitiated) {
                    var selected = DashboardAnalytics.fromSQLResults(
                        sessions: page == .overview || page == .projects ? sessions : [],
                        startDate: nil,
                        aggregate: aggregate,
                        periods: periodRows,
                        modelPeriods: modelRows,
                        models: models,
                        allTimeModels: allTimeModels,
                        tools: tools.map { tool in
                            ToolMetric(tool: tool.tool, calls: tool.calls, attributedCalls: tool.attributedCalls,
                                       sessions: tool.sessions, attributedUsage: .zero,
                                       estimatedCost: Decimal(tool.estimatedCost))
                        },
                        skills: skills.map { skill in
                            SkillMetric(skill: skill.skill, calls: skill.calls, attributedCalls: skill.attributedCalls,
                                        sessions: skill.sessions, attributedUsage: .zero,
                                        estimatedCost: Decimal(skill.estimatedCost))
                        },
                        granularity: granularity
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
        let provider = subscriptionProvider
        let cliProxyAPIConfiguration = DashboardPreferences.cliProxyAPIConfiguration(defaults: defaults)
        bankedResetTask?.cancel()
        bankedResetTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                switch provider {
                case .default:
                    return await BankedResetReader.latest(from: codexHome)
                case .cliProxyAPI:
                    guard let cliProxyAPIConfiguration else { return nil }
                    return await CLIProxyAPIReader.latestBankedReset(using: cliProxyAPIConfiguration)
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.bankedResets = snapshot
        }
    }

    /// Called when the dashboard window closes. Release all dashboard-only
    /// projections; the menu-bar host owns its separate compact projection.
    func releaseDashboardMemory() {
        guard dashboardDataIsResident else { return }
        dashboardDataIsResident = false
        loadTask?.cancel()
        loadTask = nil
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
        sessions = []
        analytics = .empty
        todayAnalytics = .empty
        quotaWeekAnalytics = .empty
        metricsIndex = .empty
        indexedSessionsByID = [:]
        subscription = nil
        account = nil
        bankedResetTask?.cancel()
        bankedResetTask = nil
        bankedResets = nil
        historySessionCount = 0
        historyMessage = nil
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
        guard dashboardDataIsResident else { return }
        startEnrichmentForAvailableHistory()
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
                guard dashboardDataIsResident else { return }
                metricsIndex = rebuilt
                indexedSessionsByID = Dictionary(uniqueKeysWithValues: rebuilt.sessions.map { ($0.sessionID, $0) })
                scheduleAnalyticsRefresh()
                historyMessage = "History index rebuilt for \(rebuilt.sessions.count.formatted()) sessions."
            } catch {
                historyMessage = "History index rebuild failed: \(error.localizedDescription)"
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
                if dashboardDataIsResident {
                    load()
                }
            } catch {
                historyMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}
