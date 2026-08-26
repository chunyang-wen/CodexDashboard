import Foundation
import CodexMetricsCore
import SwiftUI

struct MenuBarUsageAggregate: Sendable {
    let usage: TokenUsage
    let estimatedCost: Decimal
    let toolCalls: Int
    let skillCalls: Int
}

struct MenuBarAnalytics: Sendable {
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

/// The menu-bar residency boundary. This store contains only compact persisted
/// projections and display preferences. Dashboard data is owned by the helper.
@MainActor
final class MenuBarStore: ObservableObject {
    private static let liveQuotaRefreshInterval: TimeInterval = 60 * 60

    @Published private(set) var subscription: SubscriptionSnapshot?
    @Published private(set) var bankedResets: BankedResetSnapshot?
    @Published private(set) var account: CodexAccountSnapshot?
    @Published private(set) var historySessionCount = 0
    @Published private(set) var historyMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var menuBarDataIsResident = false

    @Published private(set) var codexHome: URL
    @Published private(set) var subscriptionProvider: DashboardSubscriptionProvider
    @Published private(set) var refreshInterval: TimeInterval
    @Published private(set) var weekStartsMonday: Bool
    var settingsDidChange: (@MainActor () -> Void)?
    var metricsDidChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private let userHome: URL
    private let historicalStore: HistoricalStore
    private let dynamicPricingLoader = DynamicPricingLoader()
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var popoverTask: Task<Void, Never>?
    private var bankedResetTask: Task<Void, Never>?
    private var menuBarMonitorTask: Task<Void, Never>?
    private var liveQuotaMonitorTask: Task<Void, Never>?
    private var pricingRefreshTask: Task<Void, Never>?
    private var sourceWatcher: CodexSourceWatcher?
    private var sourceRefreshTask: Task<Void, Never>?
    private var sourceRefreshGeneration = UUID()
    private var sourceRefreshInFlight = false
    private var menuBarAnalytics = MenuBarAnalytics.empty
    private var hasLiveProviderQuota = false

    init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard) {
        self.userHome = userHome
        self.defaults = defaults
        self.historicalStore = HistoricalStore(userHome: userHome)
        let savedPath = defaults.string(forKey: DashboardPreferences.codexDataPathKey)
        codexHome = savedPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? userHome.appendingPathComponent(".codex", isDirectory: true)
        subscriptionProvider = DashboardPreferences.subscriptionProvider(defaults: defaults)
        refreshInterval = defaults.object(forKey: DashboardPreferences.metricsRefreshIntervalKey) as? Double ?? 60
        weekStartsMonday = defaults.object(forKey: DashboardPreferences.weekStartsMondayKey) as? Bool ?? true
    }

    var analyticsCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartsMonday ? 2 : 1
        return calendar
    }

    var isBusy: Bool { isLoading }

    var menuBarDaily: [PeriodMetric] { menuBarAnalytics.periods }

    func menuBarAggregate(in interval: DateInterval) -> MenuBarUsageAggregate {
        menuBarAnalytics.aggregate(in: interval)
    }

    func loadMenuBar(includeLiveQuota: Bool = false) {
        loadTask?.cancel()
        popoverTask?.cancel()
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled, self.loadID == requestID {
                    self.isLoading = false
                }
            }
            do {
                if !self.hasLiveProviderQuota {
                    let snapshot = try await self.historicalStore.freshSubscriptionSnapshot()
                    guard !Task.isCancelled, self.loadID == requestID else { return }
                    if let snapshot, snapshot.isUsable {
                        self.subscription = snapshot
                    }
                }
                if includeLiveQuota {
                    await self.refreshLiveQuota(requestID: requestID)
                }
            } catch {
                guard !Task.isCancelled, self.loadID == requestID else { return }
                self.historyMessage = "Menu-bar metrics could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    func startMenuBarMonitoring() {
        menuBarMonitorTask?.cancel()
        pricingRefreshTask?.cancel()
        sourceWatcher?.stop()
        sourceWatcher = nil
        liveQuotaMonitorTask?.cancel()
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        sourceRefreshGeneration = UUID()
        loadMenuBar(includeLiveQuota: true)
        startLiveQuotaMonitoring()
        startPricingMonitoring()
        guard refreshInterval > 0 else { return }
        menuBarMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let interval = max(self.refreshInterval, 5)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self.loadMenuBar()
                await self.refreshSourceFromIndex()
            }
        }
        startSourceMonitoring()
    }

    private func startLiveQuotaMonitoring() {
        liveQuotaMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.liveQuotaRefreshInterval))
                guard !Task.isCancelled else { return }
                self.loadMenuBar(includeLiveQuota: true)
            }
        }
    }

    private func refreshLiveQuota(requestID: UUID? = nil) async {
        let codexHome = self.codexHome
        let provider = subscriptionProvider
        let cliProxyAPIConfiguration = DashboardPreferences.cliProxyAPIConfiguration(defaults: defaults)
        let sub2APIConfiguration = DashboardPreferences.sub2APIConfiguration(defaults: defaults)
        let liveData: ProviderLiveSnapshot? = await Task.detached(priority: .utility) {
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
        }.value
        if provider != .default {
            account = liveData?.account
        }
        guard !Task.isCancelled,
              requestID.map({ $0 == self.loadID }) ?? true,
              let live = liveData?.subscription,
              live.isUsable else { return }

        let quotaChanged = self.subscription?.hasSameQuota(as: live) != true
        if quotaChanged, provider == .default {
            try? await self.historicalStore.recordSubscription(live)
        }
        self.hasLiveProviderQuota = true
        self.subscription = live
        if quotaChanged {
            self.metricsDidChange?()
        }
    }

    private func startPricingMonitoring() {
        pricingRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshPricing()
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
    }

    private func refreshPricing() async {
        do {
            let snapshot = try await dynamicPricingLoader.refresh()
            var pricing = try await historicalStore.pricingHistory()
            var mergedPrices = pricing.schedules.last?.prices ?? PricingRegistry.current.prices
            for (model, price) in snapshot.prices {
                mergedPrices[model] = price
            }
            guard mergedPrices != pricing.schedules.last?.prices else { return }
            pricing = pricing.merging(PricingHistory(schedules: [
                PricingSchedule(effectiveAt: snapshot.fetchedAt, prices: mergedPrices, source: "models.dev")
            ]))
            try await historicalStore.recordPricing(pricing)
        } catch {
            // Pricing remains available from the bundled catalog or the last cache.
        }
    }

    func loadPopover() {
        menuBarDataIsResident = true
        popoverTask?.cancel()
        bankedResetTask?.cancel()
        bankedResets = nil
        let codexHome = codexHome
        let provider = subscriptionProvider
        let cliProxyAPIConfiguration = DashboardPreferences.cliProxyAPIConfiguration(defaults: defaults)
        let sub2APIConfiguration = DashboardPreferences.sub2APIConfiguration(defaults: defaults)
        popoverTask = Task { [weak self] in
            guard let self else { return }
            await self.preparePopover()
        }
        bankedResetTask = Task { [weak self] in
            let snapshot: BankedResetSnapshot? = await Task.detached(priority: .utility) {
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
            guard !Task.isCancelled, let self, self.menuBarDataIsResident else { return }
            self.bankedResets = snapshot
        }
    }

    /// Loads local popup data after the fixed-size panel is already visible.
    /// Remote reset-credit data runs independently in `bankedResetTask`.
    func preparePopover() async {
        menuBarDataIsResident = true
        await reloadCompactSnapshot(includeSessionCount: false)
        guard !Task.isCancelled, menuBarDataIsResident else { return }
        let codexHome = codexHome
        if subscriptionProvider == .default {
            account = await Task.detached(priority: .utility) {
                CodexAccountReader.read(from: codexHome)
            }.value
        }
    }

    func releasePopover() {
        menuBarDataIsResident = false
        popoverTask?.cancel()
        popoverTask = nil
        bankedResetTask?.cancel()
        bankedResetTask = nil
        account = nil
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

    func updateCodexHome(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard standardized != codexHome else { return }
        loadTask?.cancel()
        loadTask = nil
        popoverTask?.cancel()
        popoverTask = nil
        bankedResetTask?.cancel()
        bankedResetTask = nil
        isLoading = false
        subscription = nil
        hasLiveProviderQuota = false
        account = nil
        bankedResets = nil
        menuBarAnalytics = .empty
        historySessionCount = 0
        historyMessage = nil
        codexHome = standardized
        defaults.set(standardized.path, forKey: DashboardPreferences.codexDataPathKey)
        settingsDidChange?()
        startMenuBarMonitoring()
        if menuBarDataIsResident {
            loadPopover()
        } else {
            loadMenuBar(includeLiveQuota: true)
        }
    }

    func resetCodexHome() {
        updateCodexHome(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
    }

    func updateSubscriptionProvider(_ provider: DashboardSubscriptionProvider) {
        guard provider != subscriptionProvider else { return }
        subscriptionProvider = provider
        defaults.set(provider.rawValue, forKey: DashboardPreferences.subscriptionProviderKey)
        refreshSubscriptionProvider()
    }

    func refreshSubscriptionProvider() {
        loadTask?.cancel()
        loadTask = nil
        bankedResetTask?.cancel()
        bankedResetTask = nil
        subscription = nil
        hasLiveProviderQuota = false
        account = nil
        bankedResets = nil
        settingsDidChange?()
        loadMenuBar(includeLiveQuota: true)
        if menuBarDataIsResident {
            loadPopover()
        }
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        guard interval != refreshInterval else { return }
        refreshInterval = interval
        defaults.set(interval, forKey: DashboardPreferences.metricsRefreshIntervalKey)
        settingsDidChange?()
        startMenuBarMonitoring()
    }

    func updateWeekStartsMonday(_ value: Bool) {
        guard value != weekStartsMonday else { return }
        weekStartsMonday = value
        defaults.set(value, forKey: DashboardPreferences.weekStartsMondayKey)
        settingsDidChange?()
    }

    func receiveMenuBarSubscription(_ snapshot: SubscriptionSnapshot?) {
        guard let snapshot, snapshot.isUsable else { return }
        hasLiveProviderQuota = true
        subscription = snapshot
    }

    func reloadCompactSnapshot(includeSessionCount: Bool = true) async {
        guard menuBarDataIsResident else { return }
        do {
            if !hasLiveProviderQuota {
                let subscriptionSnapshot = try await historicalStore.freshSubscriptionSnapshot()
                if let subscriptionSnapshot, subscriptionSnapshot.isUsable {
                    subscription = subscriptionSnapshot
                }
            }
            guard menuBarDataIsResident else { return }

            if includeSessionCount {
                historySessionCount = try await historicalStore.storedSessionCount()
                guard menuBarDataIsResident else { return }
            }
            let cutoff = analyticsCalendar.date(
                byAdding: .day,
                value: -HistoricalStore.menuBarMetricsReadWindowDays,
                to: analyticsCalendar.startOfDay(for: .now)
            ) ?? .distantPast
            let dailySnapshot = try await historicalStore.menuBarMetricsFromDaily(since: cutoff)
            let indexSnapshot = dailySnapshot == nil
                ? try await historicalStore.menuBarMetricsFromIndex(since: cutoff, calendar: analyticsCalendar)
                : nil
            let storedSnapshot = dailySnapshot == nil && indexSnapshot == nil
                ? try await historicalStore.menuBarMetricsSnapshot(maxDays: HistoricalStore.menuBarMetricsReadWindowDays)
                : nil
            if let snapshot = dailySnapshot ?? indexSnapshot ?? storedSnapshot {
                menuBarAnalytics = MenuBarAnalytics(snapshot: snapshot)
                try? await historicalStore.recordMenuBarMetrics(snapshot)
            }
        } catch {
            guard menuBarDataIsResident else { return }
            historyMessage = "Menu-bar metrics could not be loaded: \(error.localizedDescription)"
        }
    }

    /// Keeps the compact durable projection current while the dashboard helper
    /// is closed. The host owns this watcher so menubar-only use still observes
    /// new rollout events and today's cost.
    private func startSourceMonitoring() {
        let generation = sourceRefreshGeneration
        let codexHome = self.codexHome
        sourceRefreshTask = Task { [weak self] in
            guard let self else { return }
            let storedEventID = try? await self.historicalStore.sourceEventID(for: codexHome)
            guard !Task.isCancelled,
                  generation == self.sourceRefreshGeneration,
                  codexHome == self.codexHome else { return }

            let watcher: CodexSourceWatcher
            do {
                watcher = try CodexSourceWatcher(
                    codexHome: codexHome,
                    sinceEventID: storedEventID,
                    latency: self.refreshInterval
                )
            } catch {
                return
            }
            guard generation == self.sourceRefreshGeneration else {
                watcher.stop()
                return
            }
            self.sourceWatcher = watcher

            defer {
                watcher.stop()
                if self.sourceWatcher === watcher { self.sourceWatcher = nil }
            }

            var pending: CodexSourceChangeBatch?
            var deferredEventID: UInt64?
            if storedEventID == nil {
                pending = CodexSourceChangeBatch(
                    rolloutPaths: [],
                    indexChanged: true,
                    requiresReconciliation: true,
                    latestEventID: watcher.startingEventID
                )
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

                if !batch.hasSessionActivity {
                    deferredEventID = max(deferredEventID ?? 0, batch.latestEventID)
                    pending = nil
                    continue
                }

                let process = ProcessInfo.processInfo
                if process.thermalState == .serious
                    || process.thermalState == .critical
                    || process.isLowPowerModeEnabled
                {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }

                let minimumInterval = max(0.25, self.refreshInterval)
                let elapsed = Date.now.timeIntervalSince(lastRefreshAt)
                if elapsed < minimumInterval {
                    try? await Task.sleep(for: .seconds(minimumInterval - elapsed))
                    guard !Task.isCancelled else { return }
                }

                let succeeded = await self.refreshSource(
                    changedPaths: batch.rolloutPaths,
                    indexChanged: batch.indexChanged,
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

    private func refreshSource(
        changedPaths: Set<String>,
        indexChanged: Bool,
        requiresReconciliation: Bool
    ) async -> Bool {
        guard !sourceRefreshInFlight else { return true }
        sourceRefreshInFlight = true
        defer { sourceRefreshInFlight = false }
        do {
            let codexHome = self.codexHome
            let userHome = self.userHome
            let indexed = try await Task.detached(priority: .background) {
                let store = CodexStore(codexHome: codexHome, userHome: userHome)
                if requiresReconciliation {
                    return try store.loadIndexedSessions(reconcile: true)
                }
                if indexChanged {
                    let changed = try store.loadIndexedSessionChanges()
                    if !changed.isEmpty || changedPaths.isEmpty {
                        return changed
                    }
                }
                return try store.loadIndexedSessions(forRolloutPaths: changedPaths)
            }.value
            guard !indexed.isEmpty else { return true }

            let pricing = try await historicalStore.pricingHistory()
            let store = CodexStore(codexHome: codexHome, userHome: userHome)
            var batch: [SessionMetric] = []
            batch.reserveCapacity(10)
            for await progress in store.enrichmentStream(indexed) {
                guard !Task.isCancelled else { return true }
                batch.append(progress.session)
                if batch.count >= 10 {
                    try await persistSourceBatch(batch, pricing: pricing)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty {
                try await persistSourceBatch(batch, pricing: pricing)
            }

            await reloadCompactSnapshot(includeSessionCount: false)
            metricsDidChange?()
            return true
        } catch {
            return false
        }
    }

    /// FSEvents is the low-latency path, but the source index is the durable
    /// fallback when a long-running stream misses an event or is interrupted.
    private func refreshSourceFromIndex() async {
        _ = await refreshSource(
            changedPaths: [],
            indexChanged: true,
            requiresReconciliation: false
        )
    }

    private func persistSourceBatch(_ sessions: [SessionMetric], pricing: PricingHistory) async throws {
        _ = try await historicalStore.record(sessions, pricing: pricing)
        _ = try await historicalStore.updateMetricsIndex(
            for: sessions,
            pricing: pricing,
            calendar: analyticsCalendar
        )
        if !hasLiveProviderQuota,
           let latestSubscription = sessions.compactMap(\.subscription)
            .filter(\.isUsable)
            .max(by: { $0.observedAt < $1.observedAt }) {
            try await historicalStore.recordSubscription(latestSubscription)
            subscription = latestSubscription
        }
    }
}
