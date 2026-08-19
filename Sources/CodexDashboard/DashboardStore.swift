import AppKit
import CodexMetricsCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct MetricsSourceFingerprint: Sendable {
    struct FileStamp: Equatable, Sendable {
        let size: Int64
        let modifiedAt: TimeInterval
    }

    let index: FileStamp?
    let rollouts: [String: FileStamp]

    static func capture(paths: [String], codexHome: URL) -> MetricsSourceFingerprint {
        let manager = FileManager.default
        func stamp(_ path: String) -> FileStamp? {
            guard let values = try? manager.attributesOfItem(atPath: path),
                  let size = values[.size] as? NSNumber,
                  let modified = values[.modificationDate] as? Date else { return nil }
            return FileStamp(size: size.int64Value, modifiedAt: modified.timeIntervalSince1970)
        }
        let indexPath = [
            codexHome.appendingPathComponent("state_5.sqlite").path,
            codexHome.appendingPathComponent("sqlite/state_5.sqlite").path
        ].first(where: { manager.fileExists(atPath: $0) })
        let indexStamp = indexPath.flatMap { path -> FileStamp? in
            let stamps = [path, path + "-wal"].compactMap(stamp)
            guard !stamps.isEmpty else { return nil }
            return FileStamp(
                size: stamps.reduce(0) { $0 + $1.size },
                modifiedAt: stamps.map(\.modifiedAt).max() ?? 0
            )
        }
        return MetricsSourceFingerprint(
            index: indexStamp,
            rollouts: Dictionary(uniqueKeysWithValues: paths.compactMap { path in
                stamp(path).map { (path, $0) }
            })
        )
    }
}

private struct DashboardAnalytics: Sendable {
    let filteredSessions: [SessionMetric]
    let allProjects: [ProjectMetric]
    let projects: [ProjectMetric]
    let usage: TokenUsage
    let estimatedCost: Decimal
    let costCoverage: Double
    let runtime: TimeInterval
    let models: [ModelMetric]
    let tools: [ToolMetric]
    let skills: [SkillMetric]
    let daily: [PeriodMetric]
    let weekly: [PeriodMetric]
    let monthly: [PeriodMetric]
    let yearly: [PeriodMetric]
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
        models: [], tools: [], skills: [], daily: [], weekly: [], monthly: [], yearly: [], turnDurations: [],
        averageTTFT: nil, activeDays: 0, toolCalls: 0, skillCalls: 0, completedTurns: 0,
        abortedTurns: 0
    )

    static func calculate(
        sessions: [SessionMetric],
        startDate: Date?,
        index: MetricsIndexSnapshot
    ) -> DashboardAnalytics {
        let filtered = sessions.filter { session in
            startDate.map { session.updatedAt >= $0 } ?? true
        }

        let summary = index.aggregate(since: startDate)
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
            tools: summary.tools,
            skills: summary.skills,
            daily: index.periods(granularity: .day, since: startDate, calendar: calendar),
            weekly: index.periods(granularity: .week, since: startDate, calendar: calendar),
            monthly: index.periods(granularity: .month, since: startDate, calendar: calendar),
            yearly: index.periods(granularity: .year, since: startDate, calendar: calendar),
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
            models: [], tools: [], skills: [], daily: [], weekly: [], monthly: [], yearly: [],
            turnDurations: [], averageTTFT: nil, activeDays: 0,
            toolCalls: summary.toolCalls, skillCalls: summary.skillCalls,
            completedTurns: 0, abortedTurns: 0
        )
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

    @Published private(set) var sessions: [SessionMetric] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isEnriching = false
    @Published private(set) var isUpdatingAnalytics = false
    @Published private(set) var enrichedSessions = 0
    @Published private(set) var enrichmentTotal = 0
    @Published private(set) var subscription: SubscriptionSnapshot?
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
    private var loadTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var pricingTask: Task<Void, Never>?
    private var analyticsTask: Task<Void, Never>?
    private var rangeRefreshTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var loadID = UUID()
    private var enrichmentID = UUID()
    private var analyticsID = UUID()
    private let historicalStore = HistoricalStore()
    private let dynamicPricingLoader = DynamicPricingLoader()
    private var analytics = DashboardAnalytics.empty
    private var todayAnalytics = DashboardAnalytics.empty
    private var metricsIndex = MetricsIndexSnapshot.empty

    init(defaults: UserDefaults = .standard) {
        let savedPath = defaults.string(forKey: "codexDataPath")
        codexHome = savedPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let savedInterval = defaults.object(forKey: "metricsRefreshInterval") as? Double
        refreshInterval = savedInterval ?? 60
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

    var filteredSessions: [SessionMetric] { analytics.filteredSessions }
    /// The project/session hierarchy is structural and independent of chart aggregation.
    var allProjects: [ProjectMetric] { analytics.allProjects }
    var projects: [ProjectMetric] { analytics.projects }
    var usage: TokenUsage { analytics.usage }
    var estimatedCost: Decimal { analytics.estimatedCost }
    var costCoverage: Double { analytics.costCoverage }
    var runtime: TimeInterval { analytics.runtime }
    var models: [ModelMetric] { analytics.models }
    var tools: [ToolMetric] { analytics.tools }
    var skills: [SkillMetric] { analytics.skills }
    var daily: [PeriodMetric] { analytics.daily }
    var weekly: [PeriodMetric] { analytics.weekly }
    var monthly: [PeriodMetric] { analytics.monthly }
    var yearly: [PeriodMetric] { analytics.yearly }
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
    func projectAggregate(path: String, since startDate: Date? = nil) -> MetricsIndexAggregate {
        metricsIndex.aggregate(projectPath: path, since: startDate)
    }
    func projectPeriods(path: String, granularity: PeriodGranularity, since startDate: Date? = nil) -> [PeriodMetric] {
        metricsIndex.periods(granularity: granularity, projectPath: path, since: startDate)
    }
    func indexedSession(_ id: String) -> IndexedSessionMetrics? {
        metricsIndex.sessions.first { $0.sessionID == id }
    }

    func load() {
        loadTask?.cancel()
        enrichmentTask?.cancel()
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
            do {
                let codexHome = self.codexHome
                let indexed = try await Task.detached(priority: .userInitiated) {
                    try CodexStore(codexHome: codexHome).loadIndexedSessions()
                }.value
                guard !Task.isCancelled, loadID == requestID else { return }
                do {
                    sessions = try await historicalStore.mergedSessions(with: indexed)
                    pricing = try await historicalStore.pricingHistory()
                    historySessionCount = try await historicalStore.sessionCount()
                } catch {
                    sessions = indexed
                    historyMessage = "Stored history could not be loaded: \(error.localizedDescription)"
                }
                scheduleAnalyticsRefresh()
                isLoading = false
                startEnrichmentForAvailableHistory()
                refreshPricing()
                let latestSubscription = await Task.detached(priority: .utility) {
                    SubscriptionReader.latest(from: indexed)
                }.value
                guard !Task.isCancelled, loadID == requestID else { return }
                subscription = latestSubscription
                account = await Task.detached(priority: .utility) {
                    CodexAccountReader.read(from: codexHome)
                }.value
                startBackgroundRefreshIfNeeded()
            } catch {
                guard loadID == requestID else { return }
                errorMessage = error.localizedDescription
                isLoading = false
                isEnriching = false
            }
        }
    }

    /// Watches only small file metadata and performs quiet, in-process enrichment.
    /// No helper executable or dedicated OS thread is created.
    private func startBackgroundRefreshIfNeeded() {
        guard backgroundRefreshTask == nil, refreshInterval > 0 else { return }
        backgroundRefreshTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            let codexHome = self.codexHome
            let initialPaths = self.sessions.map(\.rolloutPath)
            var fingerprint = await Task.detached(priority: .background) {
                MetricsSourceFingerprint.capture(paths: initialPaths, codexHome: codexHome)
            }.value
            var failures = 0

            while !Task.isCancelled {
                let configuredDelay = Int(self.refreshInterval)
                guard configuredDelay > 0 else { return }
                let baseDelay = min(300, configuredDelay * (1 << min(failures, 3)))
                let jitter = Int.random(in: 0...min(10, max(1, baseDelay / 8)))
                try? await Task.sleep(for: .seconds(baseDelay + jitter))
                guard !Task.isCancelled else { return }
                let process = ProcessInfo.processInfo
                guard process.thermalState != .serious,
                      process.thermalState != .critical,
                      !process.isLowPowerModeEnabled else { continue }

                let paths = self.sessions.map(\.rolloutPath).filter { !$0.isEmpty }
                let next = await Task.detached(priority: .background) {
                    MetricsSourceFingerprint.capture(paths: paths, codexHome: codexHome)
                }.value
                let changedPaths = Set(next.rollouts.compactMap { path, stamp in
                    fingerprint.rollouts[path] == stamp ? nil : path
                })
                let indexChanged = fingerprint.index != next.index
                fingerprint = next
                guard indexChanged || !changedPaths.isEmpty else {
                    failures = 0
                    continue
                }

                if await self.refreshInBackground(changedPaths: changedPaths, indexChanged: indexChanged) {
                    failures = 0
                    let refreshedPaths = self.sessions.map(\.rolloutPath).filter { !$0.isEmpty }
                    fingerprint = await Task.detached(priority: .background) {
                        MetricsSourceFingerprint.capture(paths: refreshedPaths, codexHome: codexHome)
                    }.value
                } else {
                    failures += 1
                }
            }
        }
    }

    private func refreshInBackground(changedPaths: Set<String>, indexChanged: Bool) async -> Bool {
        guard !isLoading, !isEnriching else { return true }
        do {
            let previousIDs = Set(sessions.map(\.id))
            if indexChanged {
                let existingByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
                let codexHome = self.codexHome
                let indexed = try await Task.detached(priority: .background) {
                    try CodexStore(codexHome: codexHome).loadIndexedSessions()
                }.value
                let merged = try await historicalStore.mergedSessions(with: indexed)
                sessions = merged.map { session in
                    guard let existing = existingByID[session.id],
                          !changedPaths.contains(session.rolloutPath) else { return session }
                    return existing
                }
            }
            let candidates = sessions.filter { session in
                changedPaths.contains(session.rolloutPath) || !previousIDs.contains(session.id)
            }
            guard !candidates.isEmpty else {
                if indexChanged { scheduleAnalyticsRefresh() }
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
            let persisted = try await historicalStore.sessions(withIDs: Set(enriched.map(\.id)))
            let byID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
            sessions = sessions.map { byID[$0.id] ?? $0 }
            scheduleAnalyticsRefresh()
            let sessionSnapshot = sessions
            subscription = await Task.detached(priority: .background) {
                SubscriptionReader.latest(from: sessionSnapshot)
            }.value
            return true
        } catch {
            // Quiet refresh failures are isolated and retried with exponential backoff.
            return false
        }
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
                    for item in pending { updated[item.index] = item.session }
                    do {
                        historySessionCount = try await historicalStore.record(
                            pending.map(\.session),
                            pricing: pricing
                        )
                        let persisted = try await historicalStore.sessions(
                            withIDs: Set(pending.map(\.session.id))
                        )
                        let persistedByID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
                        for item in pending {
                            if let preserved = persistedByID[item.session.id] {
                                updated[item.index] = preserved
                            }
                        }
                    } catch {
                        historyMessage = "History could not be saved: \(error.localizedDescription)"
                    }
                    sessions = updated
                    scheduleAnalyticsRefresh()
                    pending.removeAll(keepingCapacity: true)
                    enrichedSessions = progress.completed
                    enrichmentTotal = progress.total
                }
            }
            guard !Task.isCancelled, enrichmentID == requestID else { return }
            isEnriching = false
            // Pick up sessions added while the current scan was running.
            startEnrichmentForAvailableHistory()
        }
    }

    /// Apply a range selected by the view after SwiftUI has finished the current
    /// update transaction. The Picker must not write directly to an @Published
    /// property, because that can publish while the view tree is being updated.
    func updateRange(_ newRange: Range) {
        rangeRefreshTask?.cancel()
        guard newRange != range else { return }
        rangeRefreshTask = Task { [weak self] in
            // A short delay crosses the current AppKit/SwiftUI run-loop turn.
            try? await Task.sleep(for: .milliseconds(1))
            guard let self, !Task.isCancelled else { return }
            guard self.range != newRange else { return }
            self.range = newRange
        }
    }

    private func scheduleAnalyticsRefresh() {
        isUpdatingAnalytics = true
        analyticsID = UUID()

        // Keep a single calculator alive and let it consume the newest snapshot.
        // Cancelling a task that is awaiting Task.detached does not cancel that
        // detached calculation, which previously allowed one CPU-heavy calculator
        // per enrichment batch to pile up in the background.
        guard analyticsTask == nil else { return }

        analyticsTask = Task {
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
                let index: MetricsIndexSnapshot
                do {
                    index = try await historicalStore.metricsIndex(for: sessions, pricing: pricing)
                } catch {
                    historyMessage = "Metric index could not be saved: \(error.localizedDescription)"
                    let records = await Task.detached(priority: .userInitiated) {
                        sessions.map { MetricsIndexBuilder.build(session: $0, pricing: pricing) }
                    }.value
                    index = MetricsIndexSnapshot(
                        sessions: records.map(\.session),
                        days: records.flatMap(\.days)
                    )
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
                    return (selected, today)
                }.value

                // A newer snapshot supersedes this result. Loop once and calculate
                // only the latest state instead of starting another worker beside it.
                guard analyticsID == requestID else { continue }

                let minimumFeedback = Duration.milliseconds(180)
                let elapsed = feedbackStartedAt.duration(to: .now)
                if elapsed < minimumFeedback {
                    try? await Task.sleep(for: minimumFeedback - elapsed)
                }
                guard !Task.isCancelled, analyticsID == requestID else { continue }
                analytics = refreshed.0
                todayAnalytics = refreshed.1
                metricsIndex = index
                isUpdatingAnalytics = false
                analyticsTask = nil
                return
            }
            analyticsTask = nil
            isUpdatingAnalytics = false
        }
    }

    func updateCodexHome(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard standardized != codexHome else { return }
        codexHome = standardized
        UserDefaults.standard.set(standardized.path, forKey: "codexDataPath")
        load()
    }

    func resetCodexHome() {
        updateCodexHome(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        guard interval != refreshInterval else { return }
        refreshInterval = interval
        UserDefaults.standard.set(interval, forKey: "metricsRefreshInterval")
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        startBackgroundRefreshIfNeeded()
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
            } catch {
                historyMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func preserveAllHistory() {
        historyMessage = "Scanning all available rollouts; parsed metrics will be added to durable history."
        startEnrichmentForAvailableHistory()
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
                load()
            } catch {
                historyMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}
