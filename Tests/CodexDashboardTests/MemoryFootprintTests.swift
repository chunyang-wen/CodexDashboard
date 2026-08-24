@testable import CodexDashboard
import CodexMetricsCore
import Darwin
import Foundation
import XCTest

final class MemoryFootprintTests: XCTestCase {
    private func getPhysicalFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    @MainActor
    func testMemoryFootprintAcrossScenarios() async throws {
        let tempUserHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tempCodexHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempUserHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempCodexHome, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempUserHome)
            try? FileManager.default.removeItem(at: tempCodexHome)
        }

        let defaultsSuite = "MemoryFootprintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.set(tempCodexHome.path, forKey: "codexDataPath")

        // 1. Populate SQLite database with 1,000 historical sessions
        let historicalStore = HistoricalStore(userHome: tempUserHome)
        let startDate = Date(timeIntervalSince1970: 1_770_000_000)
        var generatedSessions: [SessionMetric] = []
        generatedSessions.reserveCapacity(1_000)

        for i in 1...1_000 {
            let sessionDate = startDate.addingTimeInterval(Double(i * 3600))
            let inputTokens: Int64 = Int64(500 + i * 10)
            let outputTokens: Int64 = Int64(100 + i * 2)
            let usage = TokenUsage(input: inputTokens, cachedInput: 200, output: outputTokens, reasoningOutput: 50, total: inputTokens + outputTokens)
            let session = SessionMetric(
                id: "session-\(i)",
                rolloutPath: tempCodexHome.appendingPathComponent("sessions/rollout-\(i).jsonl").path,
                projectPath: "/Users/developer/Projects/Project-\(i % 15)",
                title: "Optimized Feature Implementation #\(i)",
                source: "cli",
                originator: "Codex Desktop",
                provider: "openai",
                createdAt: sessionDate.addingTimeInterval(-1800),
                updatedAt: sessionDate,
                model: (i % 2 == 0) ? "gpt-5.6-luna" : "gpt-5.6-nova",
                reasoningEffort: nil,
                gitBranch: "main",
                cliVersion: "1.0.0",
                archived: false,
                usage: usage,
                usageEvents: [
                    UsageEvent(date: sessionDate.addingTimeInterval(-900), usage: TokenUsage(input: 250, output: 50), model: "gpt-5.6-luna"),
                    UsageEvent(date: sessionDate, usage: TokenUsage(input: inputTokens - 250, output: outputTokens - 50), model: "gpt-5.6-luna")
                ],
                turns: [
                    TurnMetric(completedAt: sessionDate.addingTimeInterval(-900), duration: 2.4, timeToFirstToken: 0.18, completed: true),
                    TurnMetric(completedAt: sessionDate, duration: 4.1, timeToFirstToken: 0.22, completed: true)
                ],
                toolCalls: 4,
                toolCallEvents: [
                    ToolCallEvent(date: sessionDate, name: "grep_search", model: "gpt-5.6-luna", attributedUsage: usage),
                    ToolCallEvent(date: sessionDate, name: "replace_file_content", model: "gpt-5.6-luna", attributedUsage: usage)
                ],
                enrichmentAvailable: true
            )
            generatedSessions.append(session)
        }

        // Record 1,000 sessions into SQLite and build index
        _ = try await historicalStore.record(generatedSessions)
        _ = try await historicalStore.metricsIndex(for: generatedSessions)
        await historicalStore.releaseMemory()
        malloc_zone_pressure_relief(nil, 0)

        // Baseline measurement
        let baselineFootprint = getPhysicalFootprintMB()

        // -------------------------------------------------------------
        // SCENARIO 1: App Launch in Menu-Bar Only Mode (Dashboard Closed)
        // -------------------------------------------------------------
        let store = DashboardStore(userHome: tempUserHome, defaults: defaults)
        store.loadMenuBar()
        // Wait for menu-bar load task to finish
        for _ in 0..<500 { // 10 seconds maximum
            if !store.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.isLoading, "loadMenuBar timed out")

        let menuBarFootprint = getPhysicalFootprintMB()
        let menuBarDelta = menuBarFootprint - baselineFootprint

        XCTAssertFalse(store.dashboardDataIsResident)
        XCTAssertEqual(store.sessions.count, 0, "No full session arrays should be resident in Menu-Bar mode")
        XCTAssertEqual(store.filteredSessions.count, 0)
        XCTAssertEqual(store.allProjects.count, 0)
        XCTAssertEqual(store.historySessionCount, 0, "Closed menu-bar mode should not retain history metadata")

        // -------------------------------------------------------------
        // SCENARIO 2: Dashboard Window Opened (Summaries & Analytics Loaded)
        // -------------------------------------------------------------
        store.activateDashboard()
        for _ in 0..<100 {
            if store.sessions.count == 1000 && !store.isUpdatingAnalytics && !store.isLoading {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let openDashboardFootprint = getPhysicalFootprintMB()
        let openDashboardDelta = openDashboardFootprint - baselineFootprint

        XCTAssertTrue(store.dashboardDataIsResident)
        XCTAssertEqual(store.sessions.count, 1000, "1,000 lightweight summaries loaded")
        XCTAssertEqual(store.allProjects.count, 15)
        XCTAssertGreaterThan(store.usage.total, 0)
        XCTAssertGreaterThan(store.estimatedCost, 0)

        // -------------------------------------------------------------
        // SCENARIO 3: Single Session Detail Hydrated On-Demand
        // -------------------------------------------------------------
        let detailSession = try await store.sessionMetric(withID: "session-42")
        XCTAssertNotNil(detailSession)
        XCTAssertEqual(detailSession?.id, "session-42")
        XCTAssertEqual(detailSession?.turns.count, 2)
        XCTAssertEqual(detailSession?.toolCallEvents?.count, 2)

        let sessionDetailFootprint = getPhysicalFootprintMB()

        // -------------------------------------------------------------
        // SCENARIO 4: Dashboard Window Closed (Memory Released)
        // -------------------------------------------------------------
        store.releaseDashboardMemory()
        try await Task.sleep(for: .milliseconds(150))
        malloc_zone_pressure_relief(nil, 0)

        let closedFootprint = getPhysicalFootprintMB()
        let closedDelta = closedFootprint - baselineFootprint

        XCTAssertFalse(store.dashboardDataIsResident)
        XCTAssertEqual(store.sessions.count, 0, "All session arrays released from memory")
        XCTAssertEqual(store.filteredSessions.count, 0)
        XCTAssertEqual(store.allProjects.count, 0)

        // The popover hydrates its compact projection only while visible.
        store.loadMenuBarPopover()
        for _ in 0..<100 {
            if store.historySessionCount >= 1000 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.menuBarDataIsResident)
        XCTAssertTrue(store.historySessionCount >= 1000)
        store.releaseMenuBarMemory()

        print("""
        =======================================================================
        MEMORY FOOTPRINT BENCHMARK REPORT (1,000 Sessions):
        -----------------------------------------------------------------------
        Baseline Test Runner Memory    : \(String(format: "%.2f", baselineFootprint)) MB
        Scenario 1: Menu-Bar Mode Only : \(String(format: "%.2f", menuBarFootprint)) MB (Δ +\(String(format: "%.2f", menuBarDelta)) MB)
        Scenario 2: Dashboard Opened   : \(String(format: "%.2f", openDashboardFootprint)) MB (Δ +\(String(format: "%.2f", openDashboardDelta)) MB)
        Scenario 3: Single Session View: \(String(format: "%.2f", sessionDetailFootprint)) MB
        Scenario 4: Dashboard Closed   : \(String(format: "%.2f", closedFootprint)) MB (Δ +\(String(format: "%.2f", closedDelta)) MB)
        =======================================================================
        """)

        // Assert that Menu-Bar / Closed delta is minimal (< 25MB above baseline test runner)
        XCTAssertLessThan(menuBarDelta, 25.0)
        XCTAssertLessThan(closedDelta, 25.0)
    }
}
