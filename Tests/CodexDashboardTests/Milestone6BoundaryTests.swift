@testable import CodexDashboard
import CodexMetricsCore
import Foundation
import XCTest

@MainActor
final class Milestone6BoundaryTests: XCTestCase {
    func testLegacyPreferencesMigrateOnceWithoutOverwritingSharedChoices() {
        let legacyName = "Milestone6BoundaryTests.Legacy.\(UUID().uuidString)"
        let sharedName = "Milestone6BoundaryTests.Shared.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: legacyName)!
        let shared = UserDefaults(suiteName: sharedName)!
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            shared.removePersistentDomain(forName: sharedName)
        }

        legacy.set("/legacy/.codex", forKey: DashboardPreferences.codexDataPathKey)
        legacy.set(15.0, forKey: DashboardPreferences.metricsRefreshIntervalKey)
        legacy.set("Runtime", forKey: DashboardPreferences.overviewActivityMetricKey)
        legacy.set("Cost", forKey: DashboardPreferences.projectActivityMetricKey)
        legacy.set(true, forKey: DashboardPreferences.showQuotaAlertMarkerKey)
        legacy.set(65.0, forKey: DashboardPreferences.quotaAlertUsedPercentKey)
        shared.set("/already-selected/.codex", forKey: DashboardPreferences.codexDataPathKey)
        shared.set("Tokens", forKey: DashboardPreferences.overviewActivityMetricKey)
        shared.set(DashboardPreferences.currentMigrationVersion - 1, forKey: DashboardPreferences.migrationVersionKey)

        DashboardPreferences.migrateLegacyDefaults(legacy: legacy, shared: shared)

        XCTAssertEqual(shared.string(forKey: DashboardPreferences.codexDataPathKey), "/already-selected/.codex")
        XCTAssertEqual(shared.double(forKey: DashboardPreferences.metricsRefreshIntervalKey), 15)
        XCTAssertEqual(shared.string(forKey: DashboardPreferences.overviewActivityMetricKey), "Tokens")
        XCTAssertEqual(shared.string(forKey: DashboardPreferences.projectActivityMetricKey), "Cost")
        XCTAssertTrue(shared.bool(forKey: DashboardPreferences.showQuotaFiveHourAlertMarkerKey))
        XCTAssertEqual(shared.double(forKey: DashboardPreferences.quotaFiveHourAlertRemainingPercentKey), 65)
        XCTAssertTrue(shared.bool(forKey: DashboardPreferences.showQuotaWeeklyAlertMarkerKey))
        XCTAssertEqual(shared.double(forKey: DashboardPreferences.quotaWeeklyAlertRemainingPercentKey), 65)
        XCTAssertEqual(shared.integer(forKey: DashboardPreferences.migrationVersionKey), DashboardPreferences.currentMigrationVersion)

        legacy.set("/changed-after-migration/.codex", forKey: DashboardPreferences.codexDataPathKey)
        DashboardPreferences.migrateLegacyDefaults(legacy: legacy, shared: shared)
        XCTAssertEqual(shared.string(forKey: DashboardPreferences.codexDataPathKey), "/already-selected/.codex")
        XCTAssertEqual(shared.string(forKey: DashboardPreferences.overviewActivityMetricKey), "Tokens")
    }

    func testExplicitLaunchPathWinsOverMissingOrMalformedPreferences() {
        let suiteName = "Milestone6BoundaryTests.Path.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let explicit = URL(fileURLWithPath: "/tmp/codex-dashboard-explicit", isDirectory: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(NSNumber(value: 42), forKey: DashboardPreferences.codexDataPathKey)
        let explicitStore = DashboardStore(userHome: userHome, defaults: defaults, codexHome: explicit)
        XCTAssertEqual(explicitStore.codexHome, explicit)

        defaults.removeObject(forKey: DashboardPreferences.codexDataPathKey)
        let fallbackStore = DashboardStore(userHome: userHome, defaults: defaults)
        XCTAssertEqual(
            fallbackStore.codexHome,
            userHome.appendingPathComponent(".codex", isDirectory: true)
        )
    }

    func testCoordinatorPassesExplicitCodexPathAndOmitsAbsentPath() {
        let path = "/tmp/codex-dashboard-launch-path"
        let pathHarness = CoordinatorHarness(path: path)
        pathHarness.coordinator.requestDashboard()
        XCTAssertEqual(
            argumentValue(pathHarness.runtime.launches[0].0, for: "--codex-dashboard-data-path"),
            path
        )

        let noPathHarness = CoordinatorHarness(path: nil)
        noPathHarness.coordinator.requestDashboard()
        XCTAssertNil(argumentValue(noPathHarness.runtime.launches[0].0, for: "--codex-dashboard-data-path"))
    }

    func testHelperSettingsApplicationAuthenticatesAndUpdatesLiveStoreSettings() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Milestone6BoundaryTests.HelperSettings.\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "Milestone6BoundaryTests.HelperSettingsDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            try? FileManager.default.removeItem(at: home)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let store = DashboardStore(userHome: home, defaults: defaults)
        let values: [AnyHashable: Any] = [
            "command": DashboardSettingsUpdate.command,
            "launchToken": "token",
            "hostPID": NSNumber(value: 4242),
            "processID": NSNumber(value: 9001),
            "generation": NSNumber(value: 7),
            "codexDataPath": "~/live-codex",
            "metricsRefreshInterval": NSNumber(value: 15.0),
            "weekStartsMonday": NSNumber(value: false)
        ]
        let update = try! XCTUnwrap(DashboardSettingsUpdate(
            userInfo: values,
            expectedToken: "token",
            expectedHostPID: 4242,
            expectedHelperPID: 9001,
            expectedGeneration: 7
        ))

        store.applySettings(
            codexDataPath: update.codexDataPath,
            refreshInterval: update.refreshInterval,
            weekStartsMonday: update.weekStartsMonday
        )

        XCTAssertEqual(store.codexHome.path, (("~/live-codex" as NSString).expandingTildeInPath))
        XCTAssertFalse(store.weekStartsMonday)
        XCTAssertEqual(store.analyticsCalendar.firstWeekday, 1)
        XCTAssertNil(DashboardSettingsUpdate(
            userInfo: values,
            expectedToken: "stale-token",
            expectedHostPID: 4242,
            expectedHelperPID: 9001,
            expectedGeneration: 7
        ))
        XCTAssertNil(DashboardSettingsUpdate(
            userInfo: values,
            expectedToken: "token",
            expectedHostPID: 4242,
            expectedHelperPID: 9001,
            expectedGeneration: 8
        ))
    }

    func testPersistentHostSourcePhaseExcludesDashboardOnlyFiles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: root.appendingPathComponent("CodexDashboard.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let hostBuild = try XCTUnwrap(
            project.components(separatedBy: "E20000000000000000000001 /* Sources */ = {").dropFirst().first
        )
        let hostSources = hostBuild.components(separatedBy: "E30000000000000000000001 /* Sources */").first ?? ""

        for file in [
            "Components.swift", "ContentView.swift", "DashboardStore.swift",
            "ConversationInspectorView.swift"
        ] {
            XCTAssertFalse(hostSources.contains(file), "\(file) must remain helper-only")
        }
        XCTAssertTrue(hostSources.contains("CodexSourceWatcher.swift in Sources"))
        XCTAssertFalse(hostSources.contains("Charts"))
        XCTAssertTrue(project.contains("ContentView.swift in Helper Sources"))
        XCTAssertTrue(project.contains("DashboardStore.swift in Helper Sources"))
        XCTAssertFalse(project.contains("CodexSourceWatcher.swift in Helper Sources"))
    }

    func testMenuBarSourceHasNoDashboardBridgeOrFullGraphTypes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexDashboard/MenuBarStore.swift"),
            encoding: .utf8
        )
        for forbidden in [
            "DashboardStore", "MetricsIndexSnapshot", "SessionSummary", "ToolMetric", "ModelMetric",
            "attach(to:"
        ] {
            XCTAssertFalse(source.contains(forbidden), "MenuBarStore must not reference \(forbidden)")
        }
        XCTAssertTrue(source.contains("storedSessionCount()"))
        XCTAssertTrue(source.contains("menuBarMetricsSnapshot("))
        XCTAssertTrue(source.contains("releaseMemory()"))
    }

    func testMenuBarPersistedProjectionReadIsBoundedAndChronological() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Milestone6BoundaryTests.MenuBarWindow.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = HistoricalStore(userHome: home)
        let days = (0..<90).map { offset in
            MenuBarDayMetrics(
                day: Date(timeIntervalSince1970: TimeInterval(offset * 86_400)),
                usage: TokenUsage(input: Int64(offset), output: 1),
                estimatedCost: Decimal(offset),
                toolCalls: offset,
                skillCalls: 0,
                sessions: 1,
                activeRuntime: 1
            )
        }
        try await store.recordMenuBarMetrics(MenuBarMetricsSnapshot(days: days))

        let snapshot = try await store.menuBarMetricsSnapshot()
        XCTAssertEqual(snapshot?.days.count, HistoricalStore.menuBarMetricsReadWindowDays)
        XCTAssertEqual(
            snapshot?.days.first?.day,
            days[90 - HistoricalStore.menuBarMetricsReadWindowDays].day
        )
        XCTAssertEqual(snapshot?.days.last?.day, days.last?.day)
        XCTAssertEqual(
            snapshot?.days,
            Array(days.suffix(HistoricalStore.menuBarMetricsReadWindowDays))
        )
    }

    func testWALBoundedReadsAndStableIDsDoNotDuplicateHistory() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Milestone6BoundaryTests.WAL.\(UUID().uuidString)", isDirectory: true)
        let suiteName = "Milestone6BoundaryTests.WALDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: home)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let writer = HistoricalStore(userHome: home)
        let reader = HistoricalStore(userHome: home)
        try await writer.record([Self.walSession(id: "stable-session", codexHome: codexHome, revision: 0)])

        let started = ContinuousClock.now
        try await withTimeout(.seconds(2)) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for revision in 1...20 {
                        try await writer.record([
                            Self.walSession(id: "stable-session", codexHome: codexHome, revision: revision)
                        ])
                        try await writer.recordMenuBarMetrics(MenuBarMetricsSnapshot(days: [
                            MenuBarDayMetrics(day: .now, usage: TokenUsage(input: Int64(revision), output: 1),
                                              estimatedCost: 0.01, toolCalls: 1, skillCalls: 0, sessions: 1,
                                              activeRuntime: 1)
                        ]))
                    }
                }
                for _ in 1...40 {
                    _ = try await reader.storedSessionCount()
                    _ = try await reader.menuBarMetricsSnapshot()
                }
                try await group.waitForAll()
            }
        }
        let elapsed = started.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(2))
        let count = try await reader.storedSessionCount()
        let finalSession = try await reader.session(withID: "stable-session")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(finalSession?.id, "stable-session")
        XCTAssertEqual(finalSession?.usage.input, 20)
    }

    private nonisolated static func walSession(id: String, codexHome: URL, revision: Int) -> SessionMetric {
        SessionMetric(
            id: id,
            rolloutPath: codexHome.appendingPathComponent("sessions/\(id).jsonl").path,
            projectPath: "/tmp/Milestone6",
            title: "Revision \(revision)",
            source: "test",
            provider: "openai",
            createdAt: .now,
            updatedAt: Date(timeIntervalSinceNow: TimeInterval(revision)),
            model: "gpt-test",
            reasoningEffort: nil,
            gitBranch: nil,
            cliVersion: nil,
            archived: false,
            usage: TokenUsage(input: Int64(revision), output: 1),
            enrichmentAvailable: true
        )
    }

    private func argumentValue(_ arguments: [String], for flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private struct TimeoutError: Error {}

    @MainActor
    private final class CoordinatorHarness {
        let runtime = TestRuntime()
        let bus = TestBus()
        let scheduler = TestScheduler()
        let coordinator: DashboardProcessCoordinator

        init(path: String?) {
            coordinator = DashboardProcessCoordinator(
                helperURL: URL(fileURLWithPath: "/tmp/CodexDashboardUI.app"),
                hostPID: 4242,
                runtime: runtime,
                lifecycleBus: bus,
                scheduler: scheduler,
                codexDataPathProvider: { path }
            )
        }
    }

    @MainActor
    private final class TestRuntime: DashboardProcessRuntime {
        var launches: [([String], DashboardProcessIdentity)] = []
        var handler: (@MainActor (DashboardProcessRuntimeEvent) -> Void)?

        func launch(arguments: [String], completion: @escaping @MainActor (Result<DashboardProcessIdentity, Error>) -> Void) {
            let identity = DashboardProcessIdentity(pid: 9001, arguments: arguments)
            launches.append((arguments, identity))
            completion(.success(identity))
        }

        func activate(pid: Int32) {}
        func terminate(pid: Int32) {}

        @discardableResult
        func observe(_ handler: @escaping @MainActor (DashboardProcessRuntimeEvent) -> Void) -> AnyObject {
            self.handler = handler
            return NSObject()
        }
    }

    @MainActor
    private final class TestBus: DashboardLifecycleBus {
        @discardableResult
        func observe(_ handler: @escaping @MainActor (DashboardLifecycleMessage) -> Void) -> AnyObject {
            NSObject()
        }

        func post(_ message: DashboardLifecycleMessage) {}
    }

    @MainActor
    private final class TestScheduler: DashboardCoordinatorScheduler {
        @discardableResult
        func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AnyObject {
            NSObject()
        }
    }
}
