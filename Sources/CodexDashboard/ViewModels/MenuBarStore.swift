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
    @Published private(set) var subscription: SubscriptionSnapshot?
    @Published private(set) var bankedResets: BankedResetSnapshot?
    @Published private(set) var account: CodexAccountSnapshot?
    @Published private(set) var historySessionCount = 0
    @Published private(set) var historyMessage: String?
    @Published private(set) var isRebuildingHistory = false
    @Published private(set) var rebuildProgress: Double? = nil
    @Published private(set) var rebuildMessage: String? = nil
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
    private var pricingRefreshTask: Task<Void, Never>?
    private var sourceWatcher: CodexSourceWatcher?
    private var sourceRefreshTask: Task<Void, Never>?
    private var sourceRefreshGeneration = UUID()
    private var sourceRefreshInFlight = false
    private var dashboardIsOpen = false
    private var menuBarAnalytics = MenuBarAnalytics.empty
    private var rebuildTask: Task<Void, Never>?

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
        if subscriptionProvider == .sub2API {
            subscription = DashboardPreferences.cachedSub2APISubscription(defaults: defaults)
        }
    }

    var analyticsCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartsMonday ? 2 : 1
        return calendar
    }

    var isBusy: Bool { isLoading || isRebuildingHistory }

    var menuBarDaily: [PeriodMetric] { menuBarAnalytics.periods }

    func menuBarAggregate(in interval: DateInterval) -> MenuBarUsageAggregate {
        menuBarAnalytics.aggregate(in: interval)
    }

    /// Defer the host's potentially large initial/recovery reconciliation while
    /// the helper owns the visible dashboard. This prevents both processes from
    /// parsing the same source index concurrently.
    func setDashboardOpen(_ isOpen: Bool) {
        dashboardIsOpen = isOpen
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
                let snapshot = try await self.historicalStore.freshSubscriptionSnapshot()
                guard !Task.isCancelled, self.loadID == requestID else { return }
                if includeLiveQuota, self.subscriptionProvider != .default {
                    let receivedLiveQuota = await self.refreshLiveQuota(requestID: requestID)
                    if !receivedLiveQuota, self.subscription == nil {
                        _ = self.acceptSubscription(snapshot)
                    }
                } else {
                    _ = self.acceptSubscription(snapshot)
                    if includeLiveQuota {
                        _ = await self.refreshLiveQuota(requestID: requestID)
                    }
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
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        sourceRefreshGeneration = UUID()
        loadMenuBar(includeLiveQuota: true)
        Task { [weak self] in
            await self?.reloadCompactSnapshot(includeSessionCount: false)
        }
        startPricingMonitoring()
        guard refreshInterval > 0 else { return }
        menuBarMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let interval = max(self.refreshInterval, 5)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self.loadMenuBar(includeLiveQuota: true)
                await self.refreshSourceFromIndex()
            }
        }
        startSourceMonitoring()
    }

    @discardableResult
    private func refreshLiveQuota(requestID: UUID? = nil) async -> Bool {
        let codexHome = self.codexHome
        let provider = subscriptionProvider
        let cliProxyAPIConfiguration = provider == .cliProxyAPI
            ? DashboardPreferences.cliProxyAPIConfiguration(defaults: defaults) : nil
        let sub2APIConfiguration = provider == .sub2API
            ? await DashboardPreferences.refreshedSub2APIConfiguration(defaults: defaults) : nil
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
        if let usageCosts = liveData?.usageCosts, !usageCosts.isEmpty,
           (try? await historicalStore.recordProviderUsageCosts(usageCosts, calendar: analyticsCalendar)) != nil {
            await reloadCompactSnapshot(includeSessionCount: false)
            metricsDidChange?()
        }
        guard !Task.isCancelled,
              requestID.map({ $0 == self.loadID }) ?? true,
              let live = liveData?.subscription,
              live.isUsable else { return false }

        if provider == .default {
            try? await self.historicalStore.recordSubscription(live)
        } else if provider == .sub2API {
            DashboardPreferences.cacheSub2APISubscription(live, defaults: defaults)
        }
        let quotaChanged = subscription?.hasSameQuota(as: live) != true
        if acceptSubscription(live), quotaChanged {
            self.metricsDidChange?()
        }
        return true
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
            var pricing = try await historicalStore.storedPricingHistory()
            var mergedPrices = pricing.schedules.last?.prices ?? PricingRegistry.current.prices
            for (model, price) in snapshot.prices {
                mergedPrices[model] = price
            }
            guard mergedPrices != pricing.schedules.last?.prices else { return }
            pricing = pricing.merging(PricingHistory(schedules: [
                PricingSchedule(effectiveAt: snapshot.fetchedAt, prices: mergedPrices, source: "models.dev")
            ]))
            try await historicalStore.recordPricing(pricing)
            metricsDidChange?()
        } catch {
            // Pricing remains available from the bundled catalog or the last cache.
        }
    }

    func loadPopover() {
        CodexMemoryTrace.mark("host.popover.load.begin")
        menuBarDataIsResident = true
        popoverTask?.cancel()
        bankedResetTask?.cancel()
        bankedResets = nil
        let codexHome = codexHome
        let provider = subscriptionProvider
        let defaults = defaults
        let cliProxyAPIConfiguration = provider == .cliProxyAPI
            ? DashboardPreferences.cliProxyAPIConfiguration(defaults: defaults) : nil
        popoverTask = Task { [weak self] in
            guard let self else { return }
            self.isLoading = true
            defer {
                if self.menuBarDataIsResident { self.isLoading = false }
            }
            await self.preparePopover()
            CodexMemoryTrace.mark("host.popover.compact-ready", details: "days=\(self.menuBarDaily.count)")
            guard !Task.isCancelled, self.menuBarDataIsResident else { return }
            _ = await self.refreshLiveQuota()
            CodexMemoryTrace.mark("host.popover.load.done", details: "days=\(self.menuBarDaily.count)")
        }
        bankedResetTask = Task { [weak self] in
            let sub2APIConfiguration = provider == .sub2API
                ? await DashboardPreferences.refreshedSub2APIConfiguration(defaults: defaults) : nil
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
        CodexMemoryTrace.mark("host.popover.release.begin", details: "days=\(menuBarDaily.count)")
        menuBarDataIsResident = false
        popoverTask?.cancel()
        popoverTask = nil
        bankedResetTask?.cancel()
        bankedResetTask = nil
        account = nil
        bankedResets = nil
        historySessionCount = 0
        historyMessage = nil
        Task { [weak self] in
            guard let self else { return }
            await self.historicalStore.releaseMemory()
            malloc_zone_pressure_relief(nil, 0)
            CodexMemoryTrace.mark("host.popover.release.done")
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

    func refreshSubscriptionProvider(validatedSubscription: SubscriptionSnapshot? = nil) {
        loadTask?.cancel()
        loadTask = nil
        bankedResetTask?.cancel()
        bankedResetTask = nil
        subscription = nil
        account = nil
        bankedResets = nil
        _ = acceptSubscription(validatedSubscription)
        if subscriptionProvider == .sub2API, let validatedSubscription {
            DashboardPreferences.cacheSub2APISubscription(validatedSubscription, defaults: defaults)
        }
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
        _ = acceptSubscription(snapshot)
    }

    func receiveParsedSubscription(_ snapshot: SubscriptionSnapshot?) {
        _ = acceptSubscription(snapshot)
    }

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

    func reloadCompactSnapshot(includeSessionCount: Bool = true) async {
        do {
            if includeSessionCount {
                historySessionCount = try await historicalStore.storedSessionCount()
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
            if subscriptionProvider == .default {
                let subscriptionSnapshot = try await historicalStore.freshSubscriptionSnapshot()
                _ = acceptSubscription(subscriptionSnapshot)
            }
        } catch {
            if menuBarDataIsResident {
                historyMessage = "Menu-bar metrics could not be loaded: \(error.localizedDescription)"
            }
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

                while dashboardIsOpen && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { return }

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
            if requiresReconciliation {
                return await reconcileSourceInBatches(codexHome: codexHome, userHome: userHome)
            }
            let indexed: [SessionMetric] = try await Task.detached(priority: .background) {
                let store = CodexStore(codexHome: codexHome, userHome: userHome)
                if indexChanged {
                    let changed = try store.loadIndexedSessionChanges()
                    if !changed.isEmpty || changedPaths.isEmpty {
                        return changed
                    }
                }
                return try store.loadIndexedSessions(forRolloutPaths: changedPaths)
            }.value
            guard !indexed.isEmpty else { return true }

            let pricing = try await historicalStore.storedPricingHistory()
            let store = CodexStore(codexHome: codexHome, userHome: userHome)
            var batch: [SessionMetric] = []
            batch.reserveCapacity(10)
            for chunkStart in stride(from: 0, to: indexed.count, by: 25) {
                let chunkEnd = min(chunkStart + 25, indexed.count)
                for await progress in store.enrichmentStream(Array(indexed[chunkStart..<chunkEnd])) {
                    guard !Task.isCancelled else { return true }
                    batch.append(progress.session)
                    if batch.count >= 10 {
                        try await persistSourceBatch(batch, pricing: pricing)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                if !batch.isEmpty {
                    try await persistSourceBatch(batch, pricing: pricing)
                    batch.removeAll(keepingCapacity: true)
                }
            }

            await reloadCompactSnapshot(includeSessionCount: false)
            metricsDidChange?()
            return true
        } catch {
            return false
        }
    }

    private func reconcileSourceInBatches(codexHome: URL, userHome: URL) async -> Bool {
        do {
            let pricing = try await historicalStore.storedPricingHistory()
            let store = CodexStore(codexHome: codexHome, userHome: userHome)
            let batchSize = 50
            var cursor: Int64?
            while !Task.isCancelled {
                let cursorForPage = cursor
                let page = try await Task.detached(priority: .background) {
                    try store.loadIndexedSessionBatch(afterRowID: cursorForPage, batchSize: batchSize)
                }.value
                if page.sourceRowCount == 0 {
                    try await Task.detached(priority: .background) {
                        try store.finishIndexedSessionReconciliation()
                    }.value
                    break
                }

                if !page.sessions.isEmpty {
                    var batch: [SessionMetric] = []
                    batch.reserveCapacity(batchSize)
                    for await progress in store.enrichmentStream(page.sessions) {
                        guard !Task.isCancelled else { return true }
                        batch.append(progress.session)
                        if batch.count >= batchSize {
                            try await persistSourceBatch(batch, pricing: pricing)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty {
                        try await persistSourceBatch(batch, pricing: pricing)
                    }
                }

                // Advance the checkpoint only after this page's metrics are safe.
                try await Task.detached(priority: .background) {
                    try store.commitIndexedSessionBatch(page)
                }.value
                guard let next = page.nextRowID else { break }
                cursor = next
                await Task.yield()
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
        if let latestSubscription = sessions.compactMap(\.subscription)
            .filter(\.isUsable)
            .max(by: { $0.observedAt < $1.observedAt }) {
            try await historicalStore.recordSubscription(latestSubscription)
            receiveParsedSubscription(latestSubscription)
        }
    }

    func cancelRebuildHistoryIndex() {
        guard isRebuildingHistory else { return }
        rebuildTask?.cancel()
        rebuildTask = nil
        isRebuildingHistory = false
        rebuildProgress = nil
        rebuildMessage = "History index rebuild cancelled."
    }

    func rebuildHistoryIndex() {
        guard !isRebuildingHistory else { return }
        isRebuildingHistory = true
        rebuildProgress = nil
        rebuildMessage = "Rebuilding the history index…"

        let provider = subscriptionProvider
        let defaults = defaults
        let calendar = analyticsCalendar

        rebuildTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRebuildingHistory = false
                self.rebuildProgress = nil
                self.rebuildTask = nil
            }
            do {
                if provider == .sub2API,
                   let configuration = await DashboardPreferences.refreshedSub2APIConfiguration(defaults: defaults) {
                    if Task.isCancelled { return }
                    self.rebuildMessage = "Fetching provider usage history…"
                    self.rebuildProgress = 0.05
                    let earliest = (try? await self.historicalStore.earliestSessionDate())
                        ?? calendar.date(byAdding: .day, value: -90, to: .now)
                        ?? .now
                    if let historicalCosts = try? await Sub2APIReader.historicalUsageCosts(
                        using: configuration,
                        since: earliest,
                        before: .now,
                        calendar: calendar
                    ), !historicalCosts.isEmpty {
                        if Task.isCancelled { return }
                        _ = try? await self.historicalStore.recordProviderUsageCosts(
                            historicalCosts,
                            calendar: calendar
                        )
                    }
                }
                if Task.isCancelled { return }
                self.rebuildMessage = "Rebuilding the history index…"
                self.rebuildProgress = 0.2
                let pricing = try await self.historicalStore.storedPricingHistory()
                let rebuilt = try await self.historicalStore.rebuildMetricsIndex(
                    pricing: pricing,
                    calendar: calendar,
                    progress: { [weak self] progress, message in
                        Task { @MainActor [weak self] in
                            guard let self, self.isRebuildingHistory else { return }
                            self.rebuildProgress = 0.2 + 0.8 * progress
                            self.rebuildMessage = message
                        }
                    }
                )
                if Task.isCancelled { return }
                await self.reloadCompactSnapshot(includeSessionCount: true)
                self.metricsDidChange?()
                self.rebuildMessage = "History index rebuilt for \(rebuilt.sessions.count.formatted()) sessions."
            } catch is CancellationError {
                self.rebuildMessage = "History index rebuild cancelled."
            } catch {
                guard !Task.isCancelled else {
                    self.rebuildMessage = "History index rebuild cancelled."
                    return
                }
                self.rebuildMessage = "History index rebuild failed: \(error.localizedDescription)"
            }
        }
    }
}
