@testable import CodexDashboard
import CodexMetricsCore
import Foundation
import XCTest

@MainActor
final class DashboardStoreLifecycleTests: XCTestCase {
    func testNewestValidQuotaWinsRegardlessOfProvider() {
        let initialDate = Date(timeIntervalSince1970: 100)
        let parsedDate = Date(timeIntervalSince1970: 200)
        let refreshedProxyDate = Date(timeIntervalSince1970: 300)
        let defaultStore = MenuBarStore()
        let initial = makeSubscription(usedPercent: 10, observedAt: initialDate)
        let parsed = makeSubscription(usedPercent: 20, observedAt: parsedDate)
        defaultStore.receiveMenuBarSubscription(initial)
        defaultStore.receiveParsedSubscription(parsed)
        XCTAssertEqual(defaultStore.subscription?.windows.first?.usedPercent, 20)

        let suiteName = "DashboardStoreLifecycleTests.ParsedProvider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(DashboardSubscriptionProvider.sub2API.rawValue, forKey: DashboardPreferences.subscriptionProviderKey)
        let proxyStore = MenuBarStore(defaults: defaults)
        proxyStore.receiveMenuBarSubscription(initial)
        proxyStore.receiveParsedSubscription(parsed)
        XCTAssertEqual(proxyStore.subscription?.windows.first?.usedPercent, 20)

        let refreshedProxy = makeSubscription(usedPercent: 30, observedAt: refreshedProxyDate)
        proxyStore.receiveMenuBarSubscription(refreshedProxy)
        proxyStore.receiveParsedSubscription(parsed)
        XCTAssertEqual(proxyStore.subscription?.windows.first?.usedPercent, 30)
    }

    func testMenuBarLoadDoesNotHydrateDashboardAndReopenRestoresIt() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = userHome.appendingPathComponent(".codex", isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        try await HistoricalStore(userHome: userHome).record([
            SessionMetric(
                id: "lifecycle-session",
                rolloutPath: codexHome.appendingPathComponent("sessions/rollout.jsonl").path,
                projectPath: "/tmp/LifecycleProject",
                title: "Lifecycle test",
                source: "cli",
                provider: "openai",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_060),
                model: "gpt-test",
                reasoningEffort: nil,
                gitBranch: nil,
                cliVersion: nil,
                archived: false,
                usage: TokenUsage(input: 100, output: 20),
                enrichmentAvailable: true
            )
        ])
        try await HistoricalStore(userHome: userHome).recordMenuBarMetrics(
            MenuBarMetricsSnapshot(days: [
                MenuBarDayMetrics(
                    day: Date(timeIntervalSince1970: 1_700_000_000),
                    usage: TokenUsage(input: 50, output: 10),
                    estimatedCost: 0.01,
                    toolCalls: 1,
                    skillCalls: 0,
                    sessions: 1,
                    activeRuntime: 2
                )
            ])
        )

        let dashboardStore = DashboardStore(userHome: userHome, defaults: defaults)
        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        XCTAssertFalse(dashboardStore.dashboardDataIsResident)
        XCTAssertTrue(dashboardStore.sessions.isEmpty)

        menuStore.loadMenuBar()
        try await waitUntil { !menuStore.isLoading }
        XCTAssertFalse(dashboardStore.dashboardDataIsResident)
        XCTAssertTrue(dashboardStore.sessions.isEmpty)
        XCTAssertTrue(menuStore.menuBarDaily.isEmpty)

        dashboardStore.activateDashboard()
        dashboardStore.activateDashboard()
        XCTAssertTrue(dashboardStore.dashboardDataIsResident)
        try await waitUntil { !dashboardStore.isLoading && dashboardStore.sessions.count == 1 }
        XCTAssertEqual(dashboardStore.sessions.map(\.id), ["lifecycle-session"])

        dashboardStore.releaseDashboardMemory()
        XCTAssertFalse(dashboardStore.dashboardDataIsResident)
        try await waitUntil { dashboardStore.sessions.isEmpty }
        XCTAssertTrue(dashboardStore.filteredSessions.isEmpty)
        XCTAssertTrue(dashboardStore.allProjects.isEmpty)

        dashboardStore.activateDashboard()
        try await waitUntil { !dashboardStore.isLoading && dashboardStore.sessions.count == 1 }
        XCTAssertTrue(dashboardStore.dashboardDataIsResident)
    }

    func testChangingDashboardRangeRefreshesOverviewPeriods() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.RangeRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        try await HistoricalStore(userHome: userHome).record([
            makeSession(id: "range-refresh-session", codexHome: userHome.appendingPathComponent(".codex", isDirectory: true))
        ])

        let store = DashboardStore(userHome: userHome, defaults: defaults)
        store.activateDashboard()
        try await waitUntil {
            !store.isLoading && !store.isUpdatingAnalytics && !store.trendPeriods.isEmpty
        }

        store.updateRange(.day)
        try await waitUntil {
            store.range == .day && !store.isUpdatingAnalytics && !store.trendPeriods.isEmpty
        }

        XCTAssertEqual(store.trendPeriods.count, 1)
        XCTAssertGreaterThan(store.trendPeriods[0].usage.total, 0)

        store.updateRange(.week)
        try await waitUntil {
            store.range == .week && !store.isUpdatingAnalytics && !store.trendPeriods.isEmpty
        }

        XCTAssertEqual(store.trendPeriods.count, 1)
        XCTAssertGreaterThan(store.trendPeriods[0].usage.total, 0)
    }

    func testReleasingMenuBarMemoryClearsPopoverProjection() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.Popover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        try await HistoricalStore(userHome: userHome).record([
            SessionMetric(
                id: "popover-session",
                rolloutPath: "/tmp/popover-rollout.jsonl",
                projectPath: "/tmp/PopoverProject",
                title: "Popover test",
                source: "cli",
                provider: "openai",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_060),
                model: "gpt-test",
                reasoningEffort: nil,
                gitBranch: nil,
                cliVersion: nil,
                archived: false,
                usage: TokenUsage(input: 50, output: 10),
                enrichmentAvailable: true
            )
        ])

        try await HistoricalStore(userHome: userHome).recordMenuBarMetrics(
            MenuBarMetricsSnapshot(days: [
                MenuBarDayMetrics(
                    day: Date(timeIntervalSince1970: 1_700_000_000),
                    usage: TokenUsage(input: 50, output: 10),
                    estimatedCost: 0.01,
                    toolCalls: 1,
                    skillCalls: 0,
                    sessions: 1,
                    activeRuntime: 2
                )
            ])
        )

        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        menuStore.loadPopover()
        try await waitUntil {
            menuStore.menuBarDataIsResident && menuStore.menuBarDaily.count == 1
        }

        XCTAssertTrue(menuStore.menuBarDataIsResident)
        XCTAssertEqual(menuStore.historySessionCount, 0)
        XCTAssertEqual(menuStore.menuBarDaily.count, 1)

        menuStore.releasePopover()

        XCTAssertFalse(menuStore.menuBarDataIsResident)
        XCTAssertEqual(menuStore.historySessionCount, 0)
        XCTAssertTrue(menuStore.menuBarDaily.isEmpty)
        XCTAssertNil(menuStore.account)
        XCTAssertNil(menuStore.bankedResets)
    }

    func testMenuBarPathChangeClearsCompactStateAndSynchronizesSubscription() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = userHome.appendingPathComponent(".codex", isDirectory: true)
        let newCodexHome = userHome.appendingPathComponent("alternate-codex", isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.PathChange.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newCodexHome, withIntermediateDirectories: true)
        let payload = Data(#"{"email":"old@example.com"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let authJSON = "{\"tokens\":{\"id_token\":\"e30.\(payload).sig\"}}"
        try Data(authJSON.utf8)
            .write(to: codexHome.appendingPathComponent("auth.json"))

        let subscription = SubscriptionSnapshot(
            planType: "pro",
            limitID: "primary",
            limitName: "Primary",
            windows: [UsageQuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: .now.addingTimeInterval(3600))],
            credits: nil,
            rateLimitReachedType: nil,
            observedAt: .now
        )
        let historicalStore = HistoricalStore(userHome: userHome)
        try await historicalStore.record([makeSession(id: "path-session", codexHome: codexHome)])
        try await historicalStore.recordSubscription(subscription)
        try await historicalStore.recordMenuBarMetrics(MenuBarMetricsSnapshot(days: [
            MenuBarDayMetrics(day: .now, usage: TokenUsage(input: 1, output: 2), estimatedCost: 0.01,
                              toolCalls: 1, skillCalls: 0, sessions: 1, activeRuntime: 1)
        ]))

        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        menuStore.loadPopover()
        try await waitUntil {
            menuStore.menuBarDataIsResident
                && menuStore.subscription != nil
                && menuStore.account?.email == "old@example.com"
                && !menuStore.menuBarDaily.isEmpty
        }

        try await historicalStore.recordMenuBarMetrics(MenuBarMetricsSnapshot(days: [
            MenuBarDayMetrics(day: .now, usage: TokenUsage(input: 1, output: 2), estimatedCost: 0.01,
                              toolCalls: 1, skillCalls: 0, sessions: 1, activeRuntime: 1),
            MenuBarDayMetrics(day: .now.addingTimeInterval(-86_400), usage: TokenUsage(input: 3, output: 4), estimatedCost: 0.02,
                              toolCalls: 2, skillCalls: 1, sessions: 1, activeRuntime: 2)
        ]))
        await menuStore.reloadCompactSnapshot()
        XCTAssertEqual(menuStore.menuBarDaily.count, 1)
        menuStore.updateCodexHome(newCodexHome)

        XCTAssertNil(menuStore.subscription)
        XCTAssertNil(menuStore.account)
        XCTAssertNil(menuStore.bankedResets)
        XCTAssertEqual(menuStore.historySessionCount, 0)
        XCTAssertTrue(menuStore.menuBarDaily.isEmpty)
        XCTAssertNil(menuStore.historyMessage)
    }

    func testMenuBarLoadsOnlyThePersistedCompactProjection() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = userHome.appendingPathComponent(".codex", isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.Migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try await HistoricalStore(userHome: userHome).recordMenuBarMetrics(MenuBarMetricsSnapshot(days: [
            MenuBarDayMetrics(day: .now, usage: TokenUsage(input: 10, output: 2), estimatedCost: 0.01,
                              toolCalls: 1, skillCalls: 0, sessions: 1, activeRuntime: 1)
        ]))
        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        menuStore.loadPopover()

        try await waitUntil {
            menuStore.menuBarDataIsResident
                && !menuStore.menuBarDaily.isEmpty
        }
        XCTAssertEqual(menuStore.historySessionCount, 0)
        XCTAssertEqual(menuStore.menuBarDaily.count, 1)
    }

    func testMenuBarPrefersCurrentTypedIndexOverStaleCompactProjection() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.CurrentProjection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        let now = Date.now
        let historicalStore = HistoricalStore(userHome: userHome)
        try await historicalStore.recordMenuBarMetrics(MenuBarMetricsSnapshot(days: [
            MenuBarDayMetrics(
                day: now,
                usage: .zero,
                estimatedCost: 0,
                toolCalls: 0,
                skillCalls: 0,
                sessions: 0,
                activeRuntime: 0
            )
        ]))
        let sessions = [
            makeSession(id: "current-a", codexHome: userHome.appendingPathComponent(".codex", isDirectory: true)),
            makeSession(id: "current-b", codexHome: userHome.appendingPathComponent(".codex", isDirectory: true))
        ]
        _ = try await historicalStore.record(sessions)
        _ = try await historicalStore.metricsIndex(for: sessions)

        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        await menuStore.preparePopover()

        XCTAssertEqual(menuStore.menuBarDaily.last?.sessions, 2)
        XCTAssertGreaterThan(menuStore.menuBarDaily.last?.usage.total ?? 0, 0)
    }

    func testMenuBarSubscriptionLoadIsIndependent() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.Subscription.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        let subscription = SubscriptionSnapshot(
            planType: "pro",
            limitID: "primary",
            limitName: "Primary",
            windows: [UsageQuotaWindow(usedPercent: 25, windowMinutes: 300, resetsAt: .now.addingTimeInterval(3600))],
            credits: nil,
            rateLimitReachedType: nil,
            observedAt: .now
        )
        try await HistoricalStore(userHome: userHome).recordSubscription(subscription)

        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        menuStore.loadPopover()

        try await waitUntil { menuStore.subscription != nil }
        XCTAssertEqual(menuStore.subscription?.planType, subscription.planType)
        XCTAssertEqual(menuStore.subscription?.windows.first?.usedPercent, 25)
    }

    func testConfiguredProviderFallsBackToStoredQuota() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.ProviderFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        defaults.set(DashboardSubscriptionProvider.sub2API.rawValue, forKey: DashboardPreferences.subscriptionProviderKey)
        let subscription = SubscriptionSnapshot(
            planType: "fallback",
            limitID: "fallback",
            limitName: nil,
            windows: [UsageQuotaWindow(usedPercent: 35, windowMinutes: 300, resetsAt: .now.addingTimeInterval(3600))],
            credits: nil,
            rateLimitReachedType: nil,
            observedAt: .now
        )
        try await HistoricalStore(userHome: userHome).recordSubscription(subscription)

        let dashboardStore = DashboardStore(userHome: userHome, defaults: defaults)
        dashboardStore.activateDashboard()
        try await waitUntil { !dashboardStore.isLoading && dashboardStore.subscription != nil }
        XCTAssertEqual(dashboardStore.subscription?.planType, "fallback")

        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        menuStore.loadMenuBar()
        try await waitUntil { !menuStore.isLoading && menuStore.subscription != nil }
        XCTAssertEqual(menuStore.subscription?.planType, "fallback")
    }

    func testFailedProviderRefreshKeepsLastValidQuota() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.ProviderRefreshFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        defaults.set(DashboardSubscriptionProvider.sub2API.rawValue, forKey: DashboardPreferences.subscriptionProviderKey)
        let subscription = SubscriptionSnapshot(
            planType: "live",
            limitID: "live",
            limitName: nil,
            windows: [UsageQuotaWindow(usedPercent: 15, windowMinutes: 300, resetsAt: .now.addingTimeInterval(3600))],
            credits: nil,
            rateLimitReachedType: nil,
            observedAt: .now
        )
        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        menuStore.receiveMenuBarSubscription(subscription)
        menuStore.loadMenuBar(includeLiveQuota: true)
        try await waitUntil { !menuStore.isLoading }

        XCTAssertEqual(menuStore.subscription?.planType, "live")
        XCTAssertEqual(menuStore.subscription?.windows.first?.usedPercent, 15)
    }

    func testMenuBarPopoverCanReleaseItsBoundedProjection() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.CloseBridge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        try await HistoricalStore(userHome: userHome).record([
            makeSession(id: "close-bridge-session", codexHome: userHome.appendingPathComponent(".codex", isDirectory: true))
        ])
        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        menuStore.loadPopover()
        try await waitUntil { menuStore.menuBarDataIsResident }

        XCTAssertTrue(menuStore.menuBarDataIsResident)
        menuStore.releasePopover()
        XCTAssertFalse(menuStore.menuBarDataIsResident)
        XCTAssertTrue(menuStore.menuBarDaily.isEmpty)
    }

    private func makeSession(id: String, codexHome: URL) -> SessionMetric {
        let date = Date.now
        return SessionMetric(
            id: id,
            rolloutPath: codexHome.appendingPathComponent("sessions/\(id).jsonl").path,
            projectPath: "/tmp/Project",
            title: id,
            source: "cli",
            provider: "openai",
            createdAt: date,
            updatedAt: date.addingTimeInterval(60),
            model: "gpt-test",
            reasoningEffort: nil,
            gitBranch: nil,
            cliVersion: nil,
            archived: false,
            usage: TokenUsage(input: 100, output: 20),
            enrichmentAvailable: true
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for lifecycle state")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeSubscription(usedPercent: Double, observedAt: Date) -> SubscriptionSnapshot {
        SubscriptionSnapshot(
            planType: "pro",
            limitID: "primary",
            limitName: nil,
            windows: [
                UsageQuotaWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: .now.addingTimeInterval(3_600)
                )
            ],
            credits: nil,
            rateLimitReachedType: nil,
            observedAt: observedAt
        )
    }
}
