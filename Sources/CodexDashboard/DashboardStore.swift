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
    let abortedTurns: Int

    static let empty = DashboardAnalytics(
        filteredSessions: [], allProjects: [], projects: [],
        usage: .zero, estimatedCost: 0, costCoverage: 0, runtime: 0,
        models: [], allTimeModels: [], tools: [], skills: [], daily: [], weekly: [], monthly: [], yearly: [],
        modelDaily: [], modelWeekly: [], modelMonthly: [], modelYearly: [], turnDurations: [],
        averageTTFT: nil, activeDays: 0, toolCalls: 0, skillCalls: 0, completedTurns: 0,
        abortedTurns: 0
    )

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
    @Published private(set) var historySessionCount = 0
    @Published private(set) var historyMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var range: Range = .month
    @Published private(set) var codexHome: URL
    @Published private(set) var refreshInterval: TimeInterval
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?
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
    }

    var isBusy: Bool { isLoading || isEnriching }
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
    func projectAggregate(path: String, since startDate: Date? = nil) -> MetricsIndexAggregate {
        metricsIndex.aggregate(projectPath: path, since: startDate)
    }
    func projectPeriods(path: String, granularity: PeriodGranularity, since startDate: Date? = nil) -> [PeriodMetric] {
        metricsIndex.periods(granularity: granularity, projectPath: path, since: startDate)
    }
    func indexedSession(_ id: String) -> IndexedSessionMetrics? {
        indexedSessionsByID[id]
    }
    func periodAggregate(in interval: DateInterval) -> MetricsIndexAggregate {
        metricsIndex.aggregate(in: interval)
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
                self.pricing = try await self.historicalStore.storedPricingHistory()
                self.historySessionCount = try await self.historicalStore.storedSessionCount()
                self.subscription = try await self.historicalStore.subscriptionSnapshot()
                let requiresMigration = try await self.historicalStore.requiresLegacyMigration()
                if requiresMigration {
                    _ = await self.refreshMenuBarInBackground(changedPaths: [], requiresReconciliation: true)
                    await self.reloadMenuBarSnapshot()
                    self.pricing = try await self.historicalStore.storedPricingHistory()
                } else if let snapshot = try await self.historicalStore.menuBarMetricsSnapshot() {
                    self.menuBarAnalytics = MenuBarAnalytics(snapshot: snapshot)
                } else if self.historySessionCount > 0 {
                    _ = await self.refreshMenuBarInBackground(changedPaths: [], requiresReconciliation: true)
                    await self.reloadMenuBarSnapshot()
                }
                let codexHome = self.codexHome
                self.account = await Task.detached(priority: .utility) {
                    CodexAccountReader.read(from: codexHome)
                }.value
                self.refreshBankedResets(from: codexHome)
                guard !Task.isCancelled, self.loadID == requestID else { return }
                await self.startBackgroundRefreshIfNeeded()
            } catch {
                guard self.loadID == requestID else { return }
                self.historyMessage = "Menu-bar metrics could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    /// Consumes the system-wide macOS filesystem journal. Normal refresh work is
    /// proportional to changed paths; all-session reconciliation occurs only when
    /// installing the watcher cursor or when macOS reports a journal gap.
    private func startBackgroundRefreshIfNeeded(reconcileIfCursorMissing: Bool? = nil) async {
        guard backgroundRefreshTask == nil, refreshInterval > 0 else { return }
        let codexHome = self.codexHome
        let storedEventID = try? await historicalStore.sourceEventID(for: codexHome)
        guard backgroundRefreshTask == nil, refreshInterval > 0, codexHome == self.codexHome else { return }
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
            if storedEventID == nil, historyExists {
                pending = CodexSourceChangeBatch(
                    rolloutPaths: [],
                    indexChanged: true,
                    requiresReconciliation: true,
                    latestEventID: watcher.startingEventID
                )
            } else if storedEventID == nil {
                try? await self.historicalStore.recordSourceEventID(watcher.startingEventID, for: codexHome)
            }

            var iterator = watcher.events.makeAsyncIterator()
            var failures = 0
            var lastRefreshAt = Date.distantPast
            while !Task.isCancelled {
                if pending == nil {
                    pending = await iterator.next()
                }
                guard let batch = pending else { return }

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
                    try? await self.historicalStore.recordSourceEventID(batch.latestEventID, for: codexHome)
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
                let indexed = (try? await Task.detached(priority: .background) {
                    try CodexStore(codexHome: codexHome).loadIndexedSessions()
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
                let merged = try await historicalStore.mergedSessionSummaries(with: indexed)
                sessions = merged
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
            let indexed = (try? await Task.detached(priority: .background) {
                try CodexStore(codexHome: codexHome).loadIndexedSessions()
            }.value) ?? []
            guard !Task.isCancelled, !dashboardDataIsResident else { return true }

            let merged = try await historicalStore.mergedSessionSummaries(with: indexed)
            let historicalIDs = Set(merged.lazy.filter(\.enrichmentAvailable).map(\.id))
            let candidates = merged.filter { session in
                (changedPaths.contains(session.rolloutPath) || !historicalIDs.contains(session.id)) && !session.enrichmentAvailable
            }
            var enriched: [SessionMetric] = []
            if !candidates.isEmpty {
                enriched.reserveCapacity(candidates.count)
                for await progress in CodexStore(codexHome: codexHome).enrichmentStream(candidates) {
                    guard !Task.isCancelled, !dashboardDataIsResident else { return true }
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
            guard !Task.isCancelled, !dashboardDataIsResident else { return true }
            menuBarAnalytics = compact
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
                let pricing = pricing
                let weeklyQuotaWindow = subscription?.windows.first { $0.windowMinutes == 10_080 }
                let index: MetricsIndexSnapshot
                do {
                    index = try await historicalStore.metricsIndex(pricing: pricing)
                } catch {
                    historyMessage = "Metric index could not be saved: \(error.localizedDescription)"
                    index = .empty
                }
                let refreshed = await Task.detached(priority: .userInitiated) {
                    let selected = DashboardAnalytics.calculate(
                        sessions: sessions,
                        startDate: nil,
                        index: index
                    )
                    let today = DashboardAnalytics.calculateToday(
                        startDate: Calendar.current.startOfDay(for: .now),
                        index: index
                    )
                    let quotaWeek = QuotaWeekAnalytics.calculate(
                        index: index,
                        window: weeklyQuotaWindow
                    )
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
                menuBarAnalytics = MenuBarAnalytics.calculate(index: index)
                metricsIndex = index
                indexedSessionsByID = Dictionary(
                    uniqueKeysWithValues: index.sessions.map { ($0.sessionID, $0) }
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
            menuBarAnalytics = MenuBarAnalytics.calculate(index: metricsIndex)
        }
        sessions = []
        analytics = .empty
        todayAnalytics = .empty
        quotaWeekAnalytics = .empty
        metricsIndex = .empty
        indexedSessionsByID = [:]
        URLCache.shared.removeAllCachedResponses()
        Task { [weak self] in
            guard let self else { return }
            await self.historicalStore.releaseMemory()
            guard !self.dashboardDataIsResident else { return }
            await self.startBackgroundRefreshIfNeeded()
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
                    if !dashboardDataIsResident,
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
