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
    let daily: [PeriodMetric]
    let weekly: [PeriodMetric]
    let monthly: [PeriodMetric]
    let turnDurations: [TimeInterval]
    let averageTTFT: TimeInterval?
    let activeDays: Int
    let toolCalls: Int
    let completedTurns: Int
    let abortedTurns: Int

    static let empty = DashboardAnalytics(
        filteredSessions: [], allProjects: [], projects: [],
        usage: .zero, estimatedCost: 0, costCoverage: 0, runtime: 0,
        models: [], daily: [], weekly: [], monthly: [], turnDurations: [],
        averageTTFT: nil, activeDays: 0, toolCalls: 0, completedTurns: 0,
        abortedTurns: 0
    )

    static func calculate(
        sessions: [SessionMetric],
        startDate: Date?,
        pricing: PricingHistory
    ) -> DashboardAnalytics {
        let filtered = sessions.filter { session in
            startDate.map { session.updatedAt >= $0 } ?? true
        }

        var runtime: TimeInterval = 0
        var turnDurations: [TimeInterval] = []
        var firstTokenTimes: [TimeInterval] = []
        var toolCalls = 0
        var completedTurns = 0
        var abortedTurns = 0
        turnDurations.reserveCapacity(filtered.count)
        firstTokenTimes.reserveCapacity(filtered.count)

        for session in filtered {
            toolCalls += session.toolCalls
            abortedTurns += session.abortedTurns
            for turn in session.turns where turn.completed {
                completedTurns += 1
                turnDurations.append(turn.duration)
                if let timeToFirstToken = turn.timeToFirstToken {
                    firstTokenTimes.append(timeToFirstToken)
                }
                if startDate.map({ turn.completedAt >= $0 }) ?? true {
                    runtime += turn.duration
                }
            }
        }

        let averageTTFT = firstTokenTimes.isEmpty
            ? nil
            : firstTokenTimes.reduce(0, +) / Double(firstTokenTimes.count)
        let calendar = Calendar.current

        return DashboardAnalytics(
            filteredSessions: filtered,
            allProjects: Analytics.projects(from: sessions),
            projects: Analytics.projects(from: filtered),
            usage: Analytics.totalUsage(filtered, since: startDate),
            estimatedCost: Analytics.totalEstimatedCost(filtered, pricing: pricing, since: startDate),
            costCoverage: Analytics.costCoverage(filtered, pricing: pricing, since: startDate),
            runtime: runtime,
            models: Analytics.models(from: filtered, pricing: pricing, since: startDate),
            daily: Analytics.periods(from: filtered, granularity: .day, pricing: pricing, calendar: calendar, since: startDate),
            weekly: Analytics.periods(from: filtered, granularity: .week, pricing: pricing, calendar: calendar, since: startDate),
            monthly: Analytics.periods(from: filtered, granularity: .month, pricing: pricing, calendar: calendar, since: startDate),
            turnDurations: turnDurations,
            averageTTFT: averageTTFT,
            activeDays: Set(filtered.map { calendar.startOfDay(for: $0.updatedAt) }).count,
            toolCalls: toolCalls,
            completedTurns: completedTurns,
            abortedTurns: abortedTurns
        )
    }
}

@MainActor
final class DashboardStore: ObservableObject {
    enum Range: String, CaseIterable, Identifiable {
        case sevenDays = "7D"
        case thirtyDays = "30D"
        case ninetyDays = "90D"
        case year = "1Y"
        case all = "All"
        var id: String { rawValue }

        var startDate: Date? {
            let days: Int?
            switch self {
            case .sevenDays: days = 7
            case .thirtyDays: days = 30
            case .ninetyDays: days = 90
            case .year: days = 365
            case .all: days = nil
            }
            return days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        }
    }

    @Published private(set) var sessions: [SessionMetric] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isEnriching = false
    @Published private(set) var isUpdatingAnalytics = false
    @Published private(set) var enrichedSessions = 0
    @Published private(set) var enrichmentTotal = 0
    @Published private(set) var subscription: SubscriptionSnapshot?
    @Published private(set) var pricing: PricingHistory = .bundled
    @Published private(set) var pricingSource = "Bundled fallback"
    @Published private(set) var pricingUpdatedAt: Date?
    @Published private(set) var isRefreshingPricing = false
    @Published private(set) var historySessionCount = 0
    @Published private(set) var historyMessage: String?
    @Published private(set) var errorMessage: String?
    @Published var range: Range = .thirtyDays {
        didSet {
            guard range != oldValue else { return }
            scheduleAnalyticsRefresh()
            // Filtering is independent of rollout parsing. Keep an active scan alive
            // instead of cancelling and restarting it every time the range changes.
            if !sessions.isEmpty, !isEnriching { startEnrichmentForSelectedRange() }
        }
    }
    private var loadTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var pricingTask: Task<Void, Never>?
    private var analyticsTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var loadID = UUID()
    private var enrichmentID = UUID()
    private var analyticsID = UUID()
    private let historicalStore = HistoricalStore()
    private let dynamicPricingLoader = DynamicPricingLoader()
    private var analytics = DashboardAnalytics.empty

    var isBusy: Bool { isLoading || isEnriching }
    var enrichmentFraction: Double {
        enrichmentTotal > 0 ? Double(enrichedSessions) / Double(enrichmentTotal) : 0
    }
    var enrichmentLabel: String {
        "Parsing \(enrichedSessions.formatted()) of \(enrichmentTotal.formatted()) sessions"
    }
    var analyticsUpdateLabel: String { "Updating \(range.rawValue)…" }

    var filteredSessions: [SessionMetric] { analytics.filteredSessions }
    /// The project/session hierarchy is structural and must not disappear when an
    /// analytics date range changes.
    var allProjects: [ProjectMetric] { analytics.allProjects }
    var projects: [ProjectMetric] { analytics.projects }
    var usage: TokenUsage { analytics.usage }
    var estimatedCost: Decimal { analytics.estimatedCost }
    var costCoverage: Double { analytics.costCoverage }
    var runtime: TimeInterval { analytics.runtime }
    var models: [ModelMetric] { analytics.models }
    var daily: [PeriodMetric] { analytics.daily }
    var weekly: [PeriodMetric] { analytics.weekly }
    var monthly: [PeriodMetric] { analytics.monthly }
    var pricingEffectiveDate: String {
        pricing.latestEffectiveDate?.formatted(.iso8601.year().month().day()) ?? "—"
    }
    var turnDurations: [TimeInterval] { analytics.turnDurations }
    var averageTTFT: TimeInterval? { analytics.averageTTFT }
    var activeDays: Int { analytics.activeDays }
    var toolCalls: Int { analytics.toolCalls }
    var completedTurns: Int { analytics.completedTurns }
    var abortedTurns: Int { analytics.abortedTurns }

    func load() {
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
            do {
                let indexed = try await Task.detached(priority: .userInitiated) {
                    try CodexStore().loadIndexedSessions()
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
                startEnrichmentForSelectedRange()
                refreshPricing()
                let latestSubscription = await Task.detached(priority: .utility) {
                    SubscriptionReader.latest(from: indexed)
                }.value
                guard !Task.isCancelled, loadID == requestID else { return }
                subscription = latestSubscription
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
        guard backgroundRefreshTask == nil else { return }
        backgroundRefreshTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            let codexHome = CodexStore().codexHome
            let initialPaths = self.sessions.map(\.rolloutPath)
            var fingerprint = await Task.detached(priority: .background) {
                MetricsSourceFingerprint.capture(paths: initialPaths, codexHome: codexHome)
            }.value
            var failures = 0

            while !Task.isCancelled {
                let baseDelay = min(300, 20 * (1 << min(failures, 4)))
                let jitter = Int.random(in: 0...min(10, baseDelay / 4))
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
                guard indexChanged || !changedPaths.isEmpty else { continue }

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
                let indexed = try await Task.detached(priority: .background) {
                    try CodexStore().loadIndexedSessions()
                }.value
                let merged = try await historicalStore.mergedSessions(with: indexed)
                sessions = merged.map { session in
                    guard let existing = existingByID[session.id],
                          !changedPaths.contains(session.rolloutPath) else { return session }
                    return existing
                }
            }
            let candidates = sessions.filter { session in
                (changedPaths.contains(session.rolloutPath) || !previousIDs.contains(session.id))
                    && (range.startDate.map { session.updatedAt >= $0 } ?? true)
            }
            guard !candidates.isEmpty else {
                if indexChanged { scheduleAnalyticsRefresh() }
                return true
            }

            var enriched: [SessionMetric] = []
            enriched.reserveCapacity(candidates.count)
            for await progress in CodexStore().enrichmentStream(candidates) {
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

    private func startEnrichmentForSelectedRange() {
        guard !isEnriching else { return }
        let requestID = UUID()
        enrichmentID = requestID
        let candidates = sessions.filter { session in
            !session.enrichmentAvailable && (range.startDate.map { session.updatedAt >= $0 } ?? true)
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
            let stream = CodexStore().enrichmentStream(candidates)
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
            // The selected range may have expanded while this scan was running.
            // Pick up only the newly in-scope sessions after the current work settles.
            startEnrichmentForSelectedRange()
        }
    }

    private func scheduleAnalyticsRefresh() {
        analyticsTask?.cancel()
        isUpdatingAnalytics = true
        let feedbackStartedAt = ContinuousClock.now
        let requestID = UUID()
        analyticsID = requestID
        let sessions = sessions
        let startDate = range.startDate
        let pricing = pricing

        analyticsTask = Task {
            // Coalesce a quick succession of parser publications.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let refreshed = await Task.detached(priority: .userInitiated) {
                DashboardAnalytics.calculate(
                    sessions: sessions,
                    startDate: startDate,
                    pricing: pricing
                )
            }.value
            let minimumFeedback = Duration.milliseconds(180)
            let elapsed = feedbackStartedAt.duration(to: .now)
            if elapsed < minimumFeedback {
                try? await Task.sleep(for: minimumFeedback - elapsed)
            }
            guard !Task.isCancelled, analyticsID == requestID else { return }
            analytics = refreshed
            isUpdatingAnalytics = false
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
            } catch {
                historyMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func preserveAllHistory() {
        historyMessage = "Scanning all available rollouts; parsed metrics will be added to durable history."
        if range == .all {
            startEnrichmentForSelectedRange()
        } else {
            range = .all
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
                load()
            } catch {
                historyMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}
