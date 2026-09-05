@testable import CodexDashboard
import CodexMetricsCore
import Foundation
import SQLite3
import XCTest

@MainActor
final class DashboardStoreLifecycleTests: XCTestCase {
    func testRebuildTimingFreezesFinishedStagesAndTotal() {
        let start = ContinuousClock.now
        var timing = RebuildTiming(now: start)
        timing.begin("Fetching provider history", at: start.advanced(by: .seconds(2)))
        timing.begin("Building index", at: start.advanced(by: .seconds(5)))
        XCTAssertEqual(timing.stages[0].elapsed(at: start.advanced(by: .seconds(9))), .seconds(2))
        XCTAssertEqual(timing.stages[1].elapsed(at: start.advanced(by: .seconds(9))), .seconds(3))
        XCTAssertEqual(timing.stages[2].elapsed(at: start.advanced(by: .seconds(9))), .seconds(4))
        XCTAssertEqual(timing.elapsed(at: start.advanced(by: .seconds(9))), .seconds(9))

        timing.finish(at: start.advanced(by: .seconds(10)))
        timing.finish(at: start.advanced(by: .seconds(20)))
        XCTAssertEqual(timing.stages[2].elapsed(at: start.advanced(by: .seconds(30))), .seconds(5))
        XCTAssertEqual(timing.elapsed(at: start.advanced(by: .seconds(30))), .seconds(10))
    }

    func testRebuildRetainsTimingsAndResetsAfterCancellation() async throws {
        let userHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = "DashboardStoreLifecycleTests.Rebuild.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }
        let store = MenuBarStore(userHome: userHome, defaults: defaults)
        store.rebuildHistoryIndex()
        let cancelledID = store.rebuildTiming?.id
        store.cancelRebuildHistoryIndex()
        XCTAssertNotNil(store.rebuildTiming?.endedAt)
        XCTAssertEqual(store.rebuildMessage, "History index rebuild cancelled.")
        store.rebuildHistoryIndex()
        XCTAssertNotEqual(store.rebuildTiming?.id, cancelledID)
        XCTAssertNil(store.rebuildTiming?.endedAt)
        try await waitUntil { !store.isRebuildingHistory }
        XCTAssertEqual(store.rebuildMessage, "History index rebuilt for 0 sessions.")
        XCTAssertNotNil(store.rebuildTiming?.endedAt)
        XCTAssertEqual(store.rebuildTiming?.stages.map(\.name), ["Preparing", "Building index", "Refreshing totals"])
        XCTAssertTrue(store.rebuildTiming!.stages.allSatisfy { $0.endedAt != nil })
    }

    func testProjectGraphSwitchingPublishesLatestAndLeavingProjectsReleasesIt() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = userHome.appendingPathComponent(".codex", isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.Graph.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let projectA = userHome.appendingPathComponent("GraphA", isDirectory: true)
        let projectB = userHome.appendingPathComponent("GraphB", isDirectory: true)
        for project in [projectA, projectB] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try createGraphSourceDatabase(
            at: codexHome.appendingPathComponent("state_5.sqlite"),
            projectA: projectA.path,
            projectB: projectB.path
        )
        try await HistoricalStore(userHome: userHome).record([
            makeSession(id: "graph-a", codexHome: codexHome, projectPath: projectA.path),
            makeSession(id: "graph-b", codexHome: codexHome, projectPath: projectB.path)
        ])

        let store = DashboardStore(
            userHome: userHome,
            defaults: defaults,
            codexHome: codexHome
        )
        store.activateDashboard()
        try await waitUntil { !store.isLoading && store.hasLoadedAnalytics }
        store.updatePage(.projects)
        try await waitUntil { !store.isLoadingSessionHierarchy && store.allProjects.count == 2 }

        store.loadProjectSessionGraph(projectID: projectA.path)
        store.loadProjectSessionGraph(projectID: projectB.path)
        try await waitUntil {
            store.projectSessionGraphProjectID == projectB.path
                && store.projectSessionGraph?.nodes.map(\.id) == ["graph-b"]
                && !store.isLoadingProjectSessionGraph
        }

        XCTAssertEqual(store.projectSessionGraph?.projectNodeCount, 1)
        store.updatePage(.overview)
        XCTAssertNil(store.projectSessionGraph)
        XCTAssertNil(store.projectSessionGraphProjectID)
        XCTAssertNil(store.projectSessionGraphError)
        XCTAssertFalse(store.isLoadingProjectSessionGraph)
    }

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

    func testProviderActivationPublishesValidatedQuotaImmediately() {
        let suiteName = "DashboardStoreLifecycleTests.ProviderActivation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(DashboardSubscriptionProvider.sub2API.rawValue, forKey: DashboardPreferences.subscriptionProviderKey)
        let store = MenuBarStore(defaults: defaults)
        store.receiveMenuBarSubscription(makeSubscription(usedPercent: 10, observedAt: Date(timeIntervalSince1970: 100)))
        let validated = makeSubscription(usedPercent: 70, observedAt: Date(timeIntervalSince1970: 200))

        store.refreshSubscriptionProvider(validatedSubscription: validated)

        XCTAssertEqual(store.subscription?.windows.first?.usedPercent, 70)
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
        try await waitUntil { !dashboardStore.isLoading && dashboardStore.hasLoadedAnalytics }
        XCTAssertTrue(dashboardStore.hasLoadedAnalytics)
        XCTAssertTrue(dashboardStore.sessions.isEmpty)
        XCTAssertEqual(dashboardStore.topProjects.count, 1)

        dashboardStore.updatePage(.projects)
        try await waitUntil { !dashboardStore.isLoadingSessionHierarchy && dashboardStore.allProjects.count == 1 }
        XCTAssertTrue(dashboardStore.sessions.isEmpty)
        dashboardStore.loadProjectSessions(projectID: dashboardStore.allProjects[0].id)
        try await waitUntil { dashboardStore.allProjects[0].sessions.count == 1 }
        XCTAssertEqual(dashboardStore.allProjects[0].sessions.map(\.id), ["lifecycle-session"])

        dashboardStore.updatePage(.overview)
        XCTAssertTrue(dashboardStore.sessions.isEmpty)

        dashboardStore.releaseDashboardMemory()
        XCTAssertFalse(dashboardStore.dashboardDataIsResident)
        XCTAssertFalse(dashboardStore.hasLoadedAnalytics)
        try await waitUntil { dashboardStore.sessions.isEmpty }
        XCTAssertTrue(dashboardStore.filteredSessions.isEmpty)
        XCTAssertTrue(dashboardStore.allProjects.isEmpty)

        dashboardStore.activateDashboard()
        try await waitUntil { !dashboardStore.isLoading && dashboardStore.hasLoadedAnalytics }
        XCTAssertTrue(dashboardStore.sessions.isEmpty)
        dashboardStore.updatePage(.projects)
        try await waitUntil { !dashboardStore.isLoadingSessionHierarchy && dashboardStore.allProjects.count == 1 }
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

    func testDashboardChartWindowKeepsOnlyLatest45Buckets() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = userHome.appendingPathComponent(".codex", isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.ChartWindow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        let calendar = Calendar.current
        let latest = calendar.startOfDay(for: .now)
        let sessions = (0..<60).map { offset in
            let day = calendar.date(byAdding: .day, value: offset - 59, to: latest)!
            return SessionMetric(
                id: "window-\(offset)",
                rolloutPath: codexHome.appendingPathComponent("sessions/window-\(offset).jsonl").path,
                projectPath: "/tmp/WindowProject",
                title: "Window \(offset)",
                source: "cli",
                provider: "openai",
                createdAt: day,
                updatedAt: day,
                model: "gpt-test",
                reasoningEffort: nil,
                gitBranch: nil,
                cliVersion: nil,
                archived: false,
                usage: TokenUsage(input: 1),
                usageEvents: [UsageEvent(date: day, usage: TokenUsage(input: 1), model: "gpt-test")],
                enrichmentAvailable: true
            )
        }
        try await HistoricalStore(userHome: userHome).record(sessions)

        let store = DashboardStore(userHome: userHome, defaults: defaults)
        store.activateDashboard()
        try await waitUntil { !store.isLoading && !store.isUpdatingAnalytics }
        store.updateRange(.day)
        try await waitUntil { store.range == .day && !store.isUpdatingAnalytics }

        XCTAssertEqual(store.trendPeriods.count, 45)
        XCTAssertEqual(store.modelTrendPeriods.map(\.start).count, 45)
    }

    func testClosingMenuBarKeepsCompactProjectionWarm() async throws {
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
        XCTAssertEqual(menuStore.menuBarDaily.count, 1)
        XCTAssertNil(menuStore.account)
        XCTAssertNil(menuStore.bankedResets)
    }

    func testPersistedMetricsRefreshDoesNotRestartDashboardLoad() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.PersistedRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        let historicalStore = HistoricalStore(userHome: userHome)
        try await historicalStore.record([
            makeSession(id: "persisted-refresh", codexHome: userHome.appendingPathComponent(".codex", isDirectory: true))
        ])

        let store = DashboardStore(userHome: userHome, defaults: defaults)
        store.activateDashboard()
        try await waitUntil { !store.isLoading && !store.isUpdatingAnalytics && store.usage.total > 0 }

        store.refreshPersistedMetrics()

        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isEnriching)
        try await waitUntil { !store.isUpdatingAnalytics }
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

    func testSub2APIStartupDoesNotReplaceAccountCacheWithDefaultQuota() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.Sub2APIStartup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }
        defaults.set(DashboardSubscriptionProvider.sub2API.rawValue, forKey: DashboardPreferences.subscriptionProviderKey)
        defaults.set("42", forKey: DashboardPreferences.sub2APIAccountIDKey)
        let cached = makeSubscription(usedPercent: 25, observedAt: Date(timeIntervalSince1970: 100))
        let defaultQuota = makeSubscription(usedPercent: 75, observedAt: Date(timeIntervalSince1970: 200))
        DashboardPreferences.cacheSub2APISubscription(cached, defaults: defaults)
        try await HistoricalStore(userHome: userHome).recordSubscription(defaultQuota)

        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        menuStore.loadMenuBar(includeLiveQuota: true)
        try await waitUntil { !menuStore.isLoading }

        XCTAssertEqual(menuStore.subscription, cached)
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

    func testMenuBarPopoverReleasesVisibleStateButKeepsMetricsWarm() async throws {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DashboardStoreLifecycleTests.CloseBridge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: userHome)
        }

        try await HistoricalStore(userHome: userHome).recordMenuBarMetrics(
            MenuBarMetricsSnapshot(days: [
                MenuBarDayMetrics(
                    day: .now,
                    usage: TokenUsage(input: 100, output: 20),
                    estimatedCost: 0.01,
                    toolCalls: 1,
                    skillCalls: 0,
                    sessions: 1,
                    activeRuntime: 1
                )
            ])
        )
        let menuStore = MenuBarStore(userHome: userHome, defaults: defaults)
        menuStore.loadPopover()
        try await waitUntil { menuStore.menuBarDataIsResident && menuStore.menuBarDaily.count == 1 }

        XCTAssertTrue(menuStore.menuBarDataIsResident)
        menuStore.releasePopover()
        XCTAssertFalse(menuStore.menuBarDataIsResident)
        XCTAssertEqual(menuStore.menuBarDaily.count, 1)
    }

    private func makeSession(
        id: String,
        codexHome: URL,
        projectPath: String = "/tmp/Project"
    ) -> SessionMetric {
        let date = Date.now
        return SessionMetric(
            id: id,
            rolloutPath: codexHome.appendingPathComponent("sessions/\(id).jsonl").path,
            projectPath: projectPath,
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

    private func createGraphSourceDatabase(at url: URL, projectA: String, projectB: String) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw NSError(domain: "DashboardStoreLifecycleTests", code: 1)
        }
        defer { if let database { sqlite3_close(database) } }
        let sql = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT, title TEXT,
                source TEXT, created_at INTEGER, updated_at INTEGER, model TEXT
            );
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT NOT NULL PRIMARY KEY,
                status TEXT NOT NULL
            );
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DashboardStoreLifecycleTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error"]
            )
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO threads VALUES (?, ?, ?, ?, 'cli', ?, ?, 'gpt-test')",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw NSError(domain: "DashboardStoreLifecycleTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }
        for row in [
            ("graph-a", "/tmp/graph-a.jsonl", projectA, "Graph A", 10, 20),
            ("graph-b", "/tmp/graph-b.jsonl", projectB, "Graph B", 30, 40)
        ] {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, row.0, -1, transient)
            sqlite3_bind_text(statement, 2, row.1, -1, transient)
            sqlite3_bind_text(statement, 3, row.2, -1, transient)
            sqlite3_bind_text(statement, 4, row.3, -1, transient)
            sqlite3_bind_int64(statement, 5, Int64(row.4))
            sqlite3_bind_int64(statement, 6, Int64(row.5))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "DashboardStoreLifecycleTests", code: 4)
            }
        }
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
