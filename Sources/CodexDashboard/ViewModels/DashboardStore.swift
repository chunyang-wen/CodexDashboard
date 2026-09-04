import AppKit
import CodexMetricsCore
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    @Published private(set) var hasLoadedAnalytics = false
    @Published private(set) var isLoadingSessionHierarchy = false
    @Published private(set) var isLoadingProjectSessionGraph = false
    @Published private(set) var projectSessionGraph: SessionGraph?
    @Published private(set) var projectSessionGraphProjectID: String?
    @Published private(set) var projectSessionGraphError: String?
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
    @Published private(set) var modelCount = 0
    @Published private(set) var modelPageCount = 1
    @Published private(set) var isRebuildingHistory = false
    @Published private(set) var rebuildProgress: Double? = nil
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
    private var sessionHierarchyTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var projectSessionTasks: [String: Task<Void, Never>] = [:]
    private var projectSessionCursors: [String: (rowID: Int64, updatedAt: Int64?)] = [:]
    private var projectSessionHasMore: Set<String> = []
    private var projectSessionGraphTask: Task<Void, Never>?
    private var projectSessionGraphLoadID = UUID()
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
    private let modelPageSize = 4
    private var modelPageIndex = 0
    @Published private var analytics = DashboardAnalytics.empty
    @Published private(set) var topProjects: [ProjectAggregateRow] = []
    @Published private(set) var projectCatalog: [ProjectMetric] = []
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

    var isBusy: Bool { isLoading || isLoadingSessionHierarchy || isEnriching || isRebuildingHistory }
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
    var allProjects: [ProjectMetric] {
        activePage == .projects && !projectCatalog.isEmpty ? projectCatalog : analytics.allProjects
    }
    var projects: [ProjectMetric] {
        activePage == .projects && !projectCatalog.isEmpty ? projectCatalog : analytics.projects
    }
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
    var medianTurnDuration: TimeInterval? { analytics.medianTurnDuration }
    var p95TurnDuration: TimeInterval? { analytics.p95TurnDuration }
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
        await loadProjectAggregate(paths: [path])
    }

    func loadProjectAggregate(paths: [String]) async -> SQLProjectAggregate {
        var aggregate = DailyAggregateResult()
        var toolTotals: [String: (calls: Int, attributedCalls: Int, sessions: Int, cost: Double)] = [:]
        var skillTotals: [String: (calls: Int, attributedCalls: Int, sessions: Int, cost: Double)] = [:]
        for path in Set(paths) {
            let daily = (try? await historicalStore.aggregateDaily(projectPath: path)) ?? DailyAggregateResult()
            aggregate.usage = aggregate.usage + daily.usage
            aggregate.estimatedCost += daily.estimatedCost
            aggregate.coveredTokens += daily.coveredTokens
            aggregate.activeRuntime += daily.activeRuntime
            aggregate.toolCalls += daily.toolCalls
            aggregate.skillCalls += daily.skillCalls
            aggregate.completedTurns += daily.completedTurns
            aggregate.activeDays += daily.activeDays

            for tool in (try? await historicalStore.mergedTools(projectPath: path)) ?? [] {
                var total = toolTotals[tool.tool] ?? (0, 0, 0, 0)
                total.calls += tool.calls
                total.attributedCalls += tool.attributedCalls
                total.sessions += tool.sessions
                total.cost += tool.estimatedCost
                toolTotals[tool.tool] = total
            }
            for skill in (try? await historicalStore.mergedSkills(projectPath: path)) ?? [] {
                var total = skillTotals[skill.skill] ?? (0, 0, 0, 0)
                total.calls += skill.calls
                total.attributedCalls += skill.attributedCalls
                total.sessions += skill.sessions
                total.cost += skill.estimatedCost
                skillTotals[skill.skill] = total
            }
        }
        // A merged project can have multiple checkouts active on the same day;
        // count calendar buckets once across all paths.
        let dayRows = await projectPeriods(paths: paths, granularity: .day)
        aggregate.activeDays = Set(dayRows.map(\.start)).count

        return SQLProjectAggregate(
            usage: aggregate.usage,
            estimatedCost: Decimal(aggregate.estimatedCost),
            costCoverage: aggregate.usage.total > 0 ? Double(aggregate.coveredTokens) / Double(aggregate.usage.total) : 0,
            activeRuntime: aggregate.activeRuntime,
            toolCalls: aggregate.toolCalls,
            skillCalls: aggregate.skillCalls,
            activeDays: aggregate.activeDays,
            medianTurnDuration: nil,
            p95TurnDuration: nil,
            averageFirstTokenTime: nil,
            tools: toolTotals.map { name, value in
                ToolMetric(tool: name, calls: value.calls, attributedCalls: value.attributedCalls,
                           sessions: value.sessions, attributedUsage: .zero, estimatedCost: Decimal(value.cost))
            },
            skills: skillTotals.map { name, value in
                SkillMetric(skill: name, calls: value.calls, attributedCalls: value.attributedCalls,
                            sessions: value.sessions, attributedUsage: .zero, estimatedCost: Decimal(value.cost))
            }
        )
    }

    func projectPeriods(path: String, granularity: PeriodGranularity, since startDate: Date? = nil) async -> [PeriodMetric] {
        await projectPeriods(paths: [path], granularity: granularity, since: startDate)
    }

    func projectPeriods(paths: [String], granularity: PeriodGranularity, since startDate: Date? = nil) async -> [PeriodMetric] {
        var totals: [Date: (usage: TokenUsage, sessions: Int, runtime: TimeInterval, cost: Decimal)] = [:]
        for path in Set(paths) {
            let periods = (try? await historicalStore.periodMetrics(
                projectPath: path,
                since: startDate,
                granularity: granularity,
                calendar: analyticsCalendar
            )) ?? []
            for period in periods {
                var total = totals[period.start] ?? (.zero, 0, 0, 0)
                total.usage = total.usage + period.usage
                total.sessions += period.sessions
                total.runtime += period.activeRuntime
                total.cost += period.estimatedCost
                totals[period.start] = total
            }
        }
        return totals.map { start, value in
            PeriodMetric(start: start, usage: value.usage, sessions: value.sessions,
                         activeRuntime: value.runtime, estimatedCost: value.cost)
        }.sorted { $0.start < $1.start }
    }

    func indexedSessionCosts(projectPath: String, sessionIDs: Set<String>? = nil) async -> [String: IndexedSessionCost] {
        await indexedSessionCosts(projectPaths: [projectPath], sessionIDs: sessionIDs)
    }

    func indexedSessionCosts(projectPaths: [String], sessionIDs: Set<String>? = nil) async -> [String: IndexedSessionCost] {
        var combined: [String: IndexedSessionCost] = [:]
        for path in Set(projectPaths) {
        let results: [String: (estimatedCost: Decimal, coveredTokens: Int64, totalTokens: Int64)]?
        if let sessionIDs {
                results = try? await historicalStore.sessionCosts(projectPath: path, sessionIDs: sessionIDs)
        } else {
                results = try? await historicalStore.sessionCosts(projectPath: path)
        }
            for (id, value) in results ?? [:] {
                let existing = combined[id] ?? IndexedSessionCost(estimatedCost: 0, coveredTokens: 0, totalTokens: 0)
                combined[id] = IndexedSessionCost(
                    estimatedCost: existing.estimatedCost + value.estimatedCost,
                    coveredTokens: existing.coveredTokens + value.coveredTokens,
                    totalTokens: existing.totalTokens + value.totalTokens
                )
            }
        }
        return combined
    }

    /// Loads the selected overview period directly from the typed SQL index.
    func periodAggregate(in interval: DateInterval) async -> SQLProjectAggregate {
        let aggregate = (try? await historicalStore.aggregateDaily(since: interval.start, before: interval.end)) ?? DailyAggregateResult()
        let durations = (try? await historicalStore.durationSummary(since: interval.start, before: interval.end)) ?? DurationSummary()
        CodexMemoryTrace.mark(
            "helper.overview.period-summary-ready",
            details: "turns=\(durations.turnCount) firstTokenSamples=\(durations.firstTokenCount)"
        )
        return SQLProjectAggregate(
            usage: aggregate.usage,
            estimatedCost: Decimal(aggregate.estimatedCost),
            costCoverage: aggregate.usage.total > 0 ? Double(aggregate.coveredTokens) / Double(aggregate.usage.total) : 0,
            activeRuntime: aggregate.activeRuntime,
            toolCalls: aggregate.toolCalls,
            skillCalls: aggregate.skillCalls,
            activeDays: aggregate.activeDays,
            medianTurnDuration: durations.medianTurnDuration,
            p95TurnDuration: durations.p95TurnDuration,
            averageFirstTokenTime: durations.averageFirstTokenTime,
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
        CodexMemoryTrace.mark("helper.dashboard-store.load.begin")
        dashboardDataIsResident = true
        loadTask?.cancel()
        sessionHierarchyTask?.cancel()
        sessionHierarchyTask = nil
        enrichmentTask?.cancel()
        let requestID = UUID()
        loadID = requestID
        enrichmentID = UUID()
        isLoading = true
        hasLoadedAnalytics = false
        isEnriching = false
        isLoadingSessionHierarchy = false
        sessions = []
        modelCount = 0
        modelPageCount = 1
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
            let cliProxyAPIConfiguration = provider == .cliProxyAPI
                ? DashboardPreferences.cliProxyAPIConfiguration(defaults: defaults) : nil
            let sub2APIConfiguration = provider == .sub2API
                ? await DashboardPreferences.refreshedSub2APIConfiguration(defaults: defaults) : nil
            // The status item should reflect quota immediately; do not make
            // it wait for the much heavier session merge and index load.
            let storedSubscription = try? await historicalStore.subscriptionSnapshot()
                .flatMap { $0.isUsable ? $0 : nil }
            _ = acceptSubscription(storedSubscription)

            // Paint only the compact SQL projection. The selected range affects
            // these queries; the full session hierarchy belongs to Projects.
            scheduleAnalyticsRefresh()
            while !hasLoadedAnalytics, !Task.isCancelled, loadID == requestID {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled, loadID == requestID else { return }
            isLoading = false

            // Live quota/account I/O is independent of local metrics and must
            // never delay the first dashboard frame.
            let liveDataTask: Task<ProviderLiveSnapshot?, Never> = Task.detached(priority: .utility) {
                switch provider {
                case .default:
                    return CLIProxyAPILiveSnapshot(
                        subscription: await SubscriptionReader.live(from: codexHome),
                        account: nil
                    )
                case .cliProxyAPI:
                    guard let cliProxyAPIConfiguration else { return nil }
                    return await CLIProxyAPIReader.liveData(using: cliProxyAPIConfiguration)
                case .sub2API:
                    guard let sub2APIConfiguration else { return nil }
                    return await Sub2APIReader.liveData(using: sub2APIConfiguration)
                }
            }

            pricing = (try? await historicalStore.storedPricingHistory()) ?? .bundled
            historySessionCount = (try? await historicalStore.storedSessionCount()) ?? 0
            if activePage == .projects {
                loadSessionHierarchy()
            }

            let liveData: ProviderLiveSnapshot? = await liveDataTask.value
            guard !Task.isCancelled, loadID == requestID else { return }
            if let usageCosts = liveData?.usageCosts, !usageCosts.isEmpty,
               (try? await historicalStore.recordProviderUsageCosts(usageCosts, calendar: analyticsCalendar)) != nil {
                scheduleAnalyticsRefresh()
            }
            if provider != .default {
                account = liveData?.account
            }
            if let liveSubscription = liveData?.subscription, liveSubscription.isUsable {
                if provider == .default {
                    try? await historicalStore.recordSubscription(liveSubscription)
                }
                _ = acceptSubscription(liveSubscription)
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

    /// Refreshes projections already persisted by the menu-bar source watcher.
    /// Source events must not restart the full index load, live provider calls,
    /// or rollout enrichment while the dashboard is open.
    func refreshPersistedMetrics() {
        guard dashboardDataIsResident else { return }
        Task { [weak self] in
            guard let self else { return }
            if let refreshedIndex = try? await self.historicalStore.metricsIndex(pricing: self.pricing, calendar: self.analyticsCalendar) {
                self.metricsIndex = refreshedIndex
                self.indexedSessionsByID = Dictionary(uniqueKeysWithValues: refreshedIndex.sessions.map { ($0.sessionID, $0) })
            }
            let snapshot = try? await self.historicalStore.subscriptionSnapshot()
            _ = self.acceptSubscription(snapshot ?? nil)
            guard self.dashboardDataIsResident,
                  let storedPricing = try? await self.historicalStore.storedPricingHistory(),
                  self.pricing != storedPricing else {
                self.scheduleAnalyticsRefresh()
                return
            }
            self.pricing = storedPricing
            self.scheduleAnalyticsRefresh()
        }
    }

    private func loadSessionHierarchy() {
        guard dashboardDataIsResident,
              activePage == .projects,
              sessionHierarchyTask == nil,
              projectCatalog.isEmpty else { return }
        isLoadingSessionHierarchy = true
        sessionHierarchyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.sessionHierarchyTask = nil
                self.isLoadingSessionHierarchy = false
            }
            guard !Task.isCancelled, self.dashboardDataIsResident else { return }
            let rows = (try? await self.historicalStore.projectAggregates()) ?? []
            let catalog = await Task.detached(priority: .utility) {
                ProjectCatalogBuilder.make(rows: rows)
            }.value
            guard !Task.isCancelled, self.dashboardDataIsResident else { return }
            self.projectCatalog = catalog
        }
    }

    func loadProjectSessions(projectID: String) {
        guard let project = projectCatalog.first(where: { $0.id == projectID }),
              project.sessions.isEmpty,
              projectSessionTasks[projectID] == nil else { return }
        loadProjectSessionPage(projectID: projectID, project: project, afterRowID: 0, afterUpdatedAt: nil)
    }

    func loadMoreProjectSessions(projectID: String) {
        guard projectSessionHasMore.contains(projectID),
              projectSessionTasks[projectID] == nil,
              let project = projectCatalog.first(where: { $0.id == projectID }),
              let cursor = projectSessionCursors[projectID] else { return }
        loadProjectSessionPage(
            projectID: projectID,
            project: project,
            afterRowID: cursor.rowID,
            afterUpdatedAt: cursor.updatedAt
        )
    }

    func loadProjectSessionGraph(projectID: String) {
        guard dashboardDataIsResident,
              activePage == .projects,
              let project = projectCatalog.first(where: { $0.id == projectID }) else { return }
        if projectSessionGraphProjectID == projectID, projectSessionGraph != nil { return }

        projectSessionGraphTask?.cancel()
        let loadID = UUID()
        projectSessionGraphLoadID = loadID
        projectSessionGraphProjectID = projectID
        projectSessionGraph = nil
        projectSessionGraphError = nil
        isLoadingProjectSessionGraph = true
        let codexHome = codexHome
        let paths = Set(project.paths)

        projectSessionGraphTask = Task { [weak self] in
            defer {
                if let self, self.projectSessionGraphLoadID == loadID {
                    self.projectSessionGraphTask = nil
                    self.isLoadingProjectSessionGraph = false
                }
            }
            do {
                let graph = try await Task.detached(priority: .utility) {
                    try CodexStore(codexHome: codexHome).loadSessionGraph(forProjectPaths: paths)
                }.value
                guard !Task.isCancelled,
                      let self,
                      self.dashboardDataIsResident,
                      self.activePage == .projects,
                      self.projectSessionGraphLoadID == loadID,
                      self.projectSessionGraphProjectID == projectID else { return }
                self.projectSessionGraph = graph
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.projectSessionGraphLoadID == loadID else { return }
                self.projectSessionGraphError = error.localizedDescription
            }
        }
    }

    func retryProjectSessionGraph() {
        guard let projectID = projectSessionGraphProjectID else { return }
        projectSessionGraphProjectID = nil
        loadProjectSessionGraph(projectID: projectID)
    }

    private func loadProjectSessionPage(
        projectID: String,
        project: ProjectMetric,
        afterRowID: Int64,
        afterUpdatedAt: Int64?
    ) {
        let codexHome = codexHome
        projectSessionTasks[projectID] = Task { [weak self] in
            defer { self?.projectSessionTasks[projectID] = nil }
            guard let self else { return }
            let indexedPage = (try? await Task.detached(priority: .utility) {
                    try CodexStore(codexHome: codexHome).loadIndexedSessionPage(
                        forProjectPaths: Set(project.paths),
                        afterRowID: afterRowID,
                        afterUpdatedAt: afterUpdatedAt,
                        batchSize: 50
                )
            }.value)
            guard !Task.isCancelled, self.dashboardDataIsResident else { return }
            let summaries: [SessionSummary]
            let nextRowID: Int64?
            if let indexedPage, !indexedPage.sessions.isEmpty {
                summaries = (try? await self.historicalStore.mergedSessionSummaries(for: indexedPage.sessions))
                    ?? indexedPage.sessions.map(\.summary)
                nextRowID = indexedPage.nextRowID
            } else if indexedPage == nil || (afterRowID == 0 && afterUpdatedAt == nil),
                      let historicalPage = try? await self.historicalStore.sessionSummaryPage(
                          forProjectPaths: Set(project.paths), afterRowID: afterRowID, batchSize: 50
                      ) {
                summaries = historicalPage.summaries
                nextRowID = historicalPage.nextRowID
            } else {
                summaries = []
                nextRowID = nil
            }
            guard !Task.isCancelled else { return }
            guard let index = self.projectCatalog.firstIndex(where: { $0.id == projectID }) else { return }
            let current = self.projectCatalog[index]
            let existingIDs = Set(current.sessions.map(\.id))
            let merged = (current.sessions + summaries.filter { !existingIDs.contains($0.id) })
                .sorted { $0.updatedAt > $1.updatedAt }
            self.projectCatalog[index] = ProjectMetric(
                path: current.path,
                paths: current.paths,
                sessions: merged,
                usage: current.usage,
                activeRuntime: current.activeRuntime,
                sessionCount: current.sessionCount,
                lastActivity: current.lastActivity,
                kind: current.kind
            )
            if let nextRowID {
                self.projectSessionCursors[projectID] = (nextRowID, indexedPage?.nextUpdatedAt)
                self.projectSessionHasMore.insert(projectID)
            } else {
                self.projectSessionCursors.removeValue(forKey: projectID)
                self.projectSessionHasMore.remove(projectID)
            }
            self.sessions = merged
        }
    }

    private func releaseSessionHierarchy() {
        sessionHierarchyTask?.cancel()
        sessionHierarchyTask = nil
        for task in projectSessionTasks.values { task.cancel() }
        projectSessionTasks.removeAll()
        projectSessionCursors.removeAll()
        projectSessionHasMore.removeAll()
        releaseProjectSessionGraph()
        enrichmentTask?.cancel()
        enrichmentTask = nil
        enrichmentID = UUID()
        isLoadingSessionHierarchy = false
        isEnriching = false
        enrichedSessions = 0
        enrichmentTotal = 0
        sessions = []
        projectCatalog = []
    }

    private func releaseProjectSessionGraph() {
        projectSessionGraphTask?.cancel()
        projectSessionGraphTask = nil
        projectSessionGraphLoadID = UUID()
        projectSessionGraph = nil
        projectSessionGraphProjectID = nil
        projectSessionGraphError = nil
        isLoadingProjectSessionGraph = false
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
                    if acceptSubscription(latestSubscription),
                       let latestSubscription {
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
                if acceptSubscription(latestSubscription),
                   let latestSubscription {
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

        if pathChanged || providerChanged || subscriptionProvider != .default {
            load()
        }
        if weekStartChanged, !pathChanged {
            scheduleAnalyticsRefresh()
        }
    }

    func updatePage(_ page: DashboardPage) {
        guard activePage != page else { return }
        activePage = page
        if page == .projects {
            loadSessionHierarchy()
        } else {
            releaseSessionHierarchy()
        }
        scheduleAnalyticsRefresh()
    }

    func updateModelPage(_ page: Int) {
        let page = max(0, page)
        guard modelPageIndex != page else { return }
        modelPageIndex = page
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
                let chartStartDate = try? await historicalStore.latestPeriodStart(
                    granularity: granularity,
                    limit: 45,
                    calendar: self.analyticsCalendar
                )

                // Fully SQL path: typed tables answer every dashboard question
                // without decoding any JSON blobs.
                let aggregate = (try? await historicalStore.aggregateDaily()) ?? DailyAggregateResult()
                let periodRows = (page == .overview || page == .billing)
                    ? ((try? await historicalStore.periodMetrics(since: chartStartDate, granularity: granularity, calendar: self.analyticsCalendar)) ?? [])
                    : []
                let modelPageSize = page == .models ? self.modelPageSize : 7
                let modelOffset = page == .models ? self.modelPageIndex * self.modelPageSize : 0
                let modelCountResult = page == .models
                    ? ((try? await historicalStore.modelCount()) ?? 0)
                    : 0
                let models = (page == .overview || page == .models)
                    ? ((try? await historicalStore.modelMetrics(limit: modelPageSize, offset: modelOffset)) ?? [])
                    : []
                let modelRows = (page == .overview || page == .models)
                    ? ((try? await historicalStore.modelPeriodMetrics(
                        since: chartStartDate,
                        granularity: granularity,
                        calendar: self.analyticsCalendar,
                        models: Set(models.map(\.model))
                    )) ?? [])
                    : []
                let allTimeModels = page == .models ? models : []
                let tools = page == .overview
                    ? ((try? await historicalStore.mergedTools(limit: 10)) ?? [])
                    : []
                let skills = page == .overview
                    ? ((try? await historicalStore.mergedSkills(limit: 10)) ?? [])
                    : []
                let projectRows = page == .overview
                    ? ((try? await historicalStore.projectAggregates(limit: 7)) ?? [])
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

                CodexMemoryTrace.mark(
                    "helper.analytics.sql-ready",
                    details: "models=\(models.count) modelTrend=\(modelRows.count) periods=\(periodRows.count) projects=\(projectRows.count)"
                )

                let refreshed = await Task.detached(priority: .userInitiated) {
                    var selected = DashboardAnalytics.fromSQLResults(
                        sessions: page == .projects ? sessions : [],
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
                        medianTurnDuration: nil, p95TurnDuration: nil, averageTTFT: nil, activeDays: 0,
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
                if page == .overview {
                    topProjects = projectRows
                } else if page == .models {
                    modelCount = modelCountResult
                    modelPageCount = max(1, Int(ceil(Double(modelCountResult) / Double(self.modelPageSize))))
                }
                hasLoadedAnalytics = true
                CodexMemoryTrace.mark(
                    "helper.analytics.published",
                    details: "page=\(page) models=\(models.count) modelTrend=\(modelRows.count) sessions=\(sessions.count)"
                )
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
        let defaults = defaults
        let cliProxyAPIConfiguration = provider == .cliProxyAPI
            ? DashboardPreferences.cliProxyAPIConfiguration(defaults: defaults) : nil
        bankedResetTask?.cancel()
        bankedResetTask = Task { [weak self] in
            let sub2APIConfiguration = provider == .sub2API
                ? await DashboardPreferences.refreshedSub2APIConfiguration(defaults: defaults) : nil
            let snapshot = await Task.detached(priority: .utility) {
                switch provider {
                case .default:
                    return await BankedResetReader.latest(from: codexHome)
                case .cliProxyAPI:
                    guard let cliProxyAPIConfiguration else { return nil }
                    return await CLIProxyAPIReader.latestBankedReset(using: cliProxyAPIConfiguration)
                case .sub2API:
                    guard let sub2APIConfiguration else { return nil }
                    return await Sub2APIReader.latestBankedReset(using: sub2APIConfiguration)
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.bankedResets = snapshot
        }
    }

    /// Called when the dashboard window closes. Release all dashboard-only
    /// projections; the menu-bar host owns its separate compact projection.
    func releaseDashboardMemory() {
        CodexMemoryTrace.mark(
            "helper.dashboard.release.begin",
            details: "models=\(models.count) modelTrend=\(modelTrendPeriods.count) sessions=\(sessions.count)"
        )
        guard dashboardDataIsResident else { return }
        dashboardDataIsResident = false
        loadTask?.cancel()
        loadTask = nil
        sessionHierarchyTask?.cancel()
        sessionHierarchyTask = nil
        for task in projectSessionTasks.values { task.cancel() }
        projectSessionTasks.removeAll()
        projectSessionCursors.removeAll()
        projectSessionHasMore.removeAll()
        releaseProjectSessionGraph()
        enrichmentTask?.cancel()
        enrichmentTask = nil
        analyticsTask?.cancel()
        analyticsTask = nil
        analyticsWorkerID = UUID()
        rangeRefreshTask?.cancel()
        rangeRefreshTask = nil
        isLoading = false
        hasLoadedAnalytics = false
        isLoadingSessionHierarchy = false
        isEnriching = false
        isUpdatingAnalytics = false
        enrichedSessions = 0
        enrichmentTotal = 0
        sessions = []
        modelCount = 0
        modelPageCount = 1
        topProjects = []
        projectCatalog = []
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
            CodexMemoryTrace.mark("helper.dashboard.release.done")
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

    func cancelRebuildHistoryIndex() {
        guard isRebuildingHistory else { return }
        rebuildTask?.cancel()
        rebuildTask = nil
        isRebuildingHistory = false
        rebuildProgress = nil
        historyMessage = "History index rebuild cancelled."
    }

    func rebuildHistoryIndex() {
        guard !isRebuildingHistory else { return }
        isRebuildingHistory = true
        rebuildProgress = nil
        historyMessage = "Rebuilding the history index…"
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRebuildingHistory = false
                self.rebuildProgress = nil
                self.rebuildTask = nil
            }
            do {
                if self.subscriptionProvider == .sub2API,
                   let configuration = await DashboardPreferences.refreshedSub2APIConfiguration(defaults: self.defaults) {
                    if Task.isCancelled { return }
                    self.historyMessage = "Fetching provider usage history…"
                    self.rebuildProgress = 0.05
                    let earliest = (try? await self.historicalStore.earliestSessionDate())
                        ?? self.analyticsCalendar.date(byAdding: .day, value: -90, to: .now)
                        ?? .now
                    if let historicalCosts = try? await Sub2APIReader.historicalUsageCosts(
                        using: configuration,
                        since: earliest,
                        before: .now,
                        calendar: self.analyticsCalendar
                    ), !historicalCosts.isEmpty {
                        if Task.isCancelled { return }
                        _ = try? await self.historicalStore.recordProviderUsageCosts(
                            historicalCosts,
                            calendar: self.analyticsCalendar
                        )
                    }
                }
                if Task.isCancelled { return }
                self.historyMessage = "Rebuilding the history index…"
                self.rebuildProgress = 0.2
                let rebuilt = try await self.historicalStore.rebuildMetricsIndex(
                    pricing: self.pricing,
                    calendar: self.analyticsCalendar,
                    progress: { [weak self] progress, message in
                        Task { @MainActor [weak self] in
                            guard let self, self.isRebuildingHistory else { return }
                            self.rebuildProgress = 0.2 + 0.8 * progress
                            self.historyMessage = message
                        }
                    }
                )
                if Task.isCancelled { return }
                guard self.dashboardDataIsResident else { return }
                self.metricsIndex = rebuilt
                self.indexedSessionsByID = Dictionary(uniqueKeysWithValues: rebuilt.sessions.map { ($0.sessionID, $0) })
                self.scheduleAnalyticsRefresh()
                self.historyMessage = "History index rebuilt for \(rebuilt.sessions.count.formatted()) sessions."
            } catch is CancellationError {
                self.historyMessage = "History index rebuild cancelled."
            } catch {
                guard !Task.isCancelled else {
                    self.historyMessage = "History index rebuild cancelled."
                    return
                }
                self.historyMessage = "History index rebuild failed: \(error.localizedDescription)"
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
