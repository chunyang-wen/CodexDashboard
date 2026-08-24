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
    @Published private(set) var isLoading = false
    @Published private(set) var menuBarDataIsResident = false

    @Published private(set) var codexHome: URL
    @Published private(set) var refreshInterval: TimeInterval
    @Published private(set) var weekStartsMonday: Bool
    var settingsDidChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private let historicalStore: HistoricalStore
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var popoverTask: Task<Void, Never>?
    private var bankedResetTask: Task<Void, Never>?
    private var menuBarAnalytics = MenuBarAnalytics.empty

    init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.historicalStore = HistoricalStore(userHome: userHome)
        let savedPath = defaults.string(forKey: DashboardPreferences.codexDataPathKey)
        codexHome = savedPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? userHome.appendingPathComponent(".codex", isDirectory: true)
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

    func loadMenuBar() {
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
                let snapshot = try await self.historicalStore.subscriptionSnapshot()
                guard !Task.isCancelled, self.loadID == requestID else { return }
                self.subscription = snapshot?.isUsable == true ? snapshot : nil
            } catch {
                guard !Task.isCancelled, self.loadID == requestID else { return }
                self.historyMessage = "Menu-bar metrics could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    func loadPopover() {
        menuBarDataIsResident = true
        popoverTask?.cancel()
        popoverTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadCompactSnapshot()
            guard !Task.isCancelled, self.menuBarDataIsResident else { return }
            let codexHome = self.codexHome
            self.account = await Task.detached(priority: .utility) {
                CodexAccountReader.read(from: codexHome)
            }.value
            guard !Task.isCancelled, self.menuBarDataIsResident else { return }
            self.bankedResetTask?.cancel()
            self.bankedResetTask = Task { [weak self] in
                let snapshot = await Task.detached(priority: .utility) {
                    await BankedResetReader.latest(from: codexHome)
                }.value
                guard !Task.isCancelled, let self, self.menuBarDataIsResident else { return }
                self.bankedResets = snapshot
            }
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
        account = nil
        bankedResets = nil
        menuBarAnalytics = .empty
        historySessionCount = 0
        historyMessage = nil
        codexHome = standardized
        defaults.set(standardized.path, forKey: DashboardPreferences.codexDataPathKey)
        settingsDidChange?()
        if menuBarDataIsResident {
            loadPopover()
        } else {
            loadMenuBar()
        }
    }

    func resetCodexHome() {
        updateCodexHome(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        guard interval != refreshInterval else { return }
        refreshInterval = interval
        defaults.set(interval, forKey: DashboardPreferences.metricsRefreshIntervalKey)
        settingsDidChange?()
    }

    func updateWeekStartsMonday(_ value: Bool) {
        guard value != weekStartsMonday else { return }
        weekStartsMonday = value
        defaults.set(value, forKey: DashboardPreferences.weekStartsMondayKey)
        settingsDidChange?()
    }

    func receiveMenuBarSubscription(_ snapshot: SubscriptionSnapshot?) {
        subscription = snapshot
    }

    func reloadCompactSnapshot() async {
        guard menuBarDataIsResident else { return }
        do {
            historySessionCount = try await historicalStore.storedSessionCount()
            guard menuBarDataIsResident else { return }
            if let snapshot = try await historicalStore.menuBarMetricsSnapshot(
                maxDays: HistoricalStore.menuBarMetricsReadWindowDays
            ) {
                menuBarAnalytics = MenuBarAnalytics(snapshot: snapshot)
            } else {
                let cutoff = analyticsCalendar.date(
                    byAdding: .day,
                    value: -45,
                    to: analyticsCalendar.startOfDay(for: .now)
                ) ?? .distantPast
                if let snapshot = try await historicalStore.menuBarMetricsFromDaily(since: cutoff) {
                    menuBarAnalytics = MenuBarAnalytics(snapshot: snapshot)
                    try? await historicalStore.recordMenuBarMetrics(snapshot)
                }
            }
            let snapshot = try await historicalStore.subscriptionSnapshot()
            subscription = snapshot?.isUsable == true ? snapshot : nil
        } catch {
            guard menuBarDataIsResident else { return }
            historyMessage = "Menu-bar metrics could not be loaded: \(error.localizedDescription)"
        }
    }
}
