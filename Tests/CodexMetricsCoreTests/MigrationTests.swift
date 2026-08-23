import SQLite3
import XCTest
@testable import CodexMetricsCore

final class MigrationTests: XCTestCase {
    func testTypedMigrationPopulatesDailyTables() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = HistoricalStore(userHome: home)
        let day = Date(timeIntervalSince1970: 1_700_000_000)

        let session = SessionMetric(
            id: "test-session-1",
            rolloutPath: "/tmp/fake.jsonl",
            projectPath: "/tmp/project",
            title: "Test",
            source: "codex",
            originator: nil,
            provider: "openai",
            createdAt: day,
            updatedAt: day.addingTimeInterval(3600),
            model: "gpt-4o",
            reasoningEffort: nil,
            gitBranch: nil,
            cliVersion: nil,
            archived: false,
            usage: .init(input: 100, cachedInput: 50, cacheWriteInput: 0, output: 200, reasoningOutput: 20, total: 300),
            turns: [TurnMetric(completedAt: day.addingTimeInterval(3600), duration: 60, timeToFirstToken: 1.2, completed: true)],
            toolCalls: 3,
            userMessages: 5,
            enrichmentAvailable: true
        )
        _ = try await store.record([session], pricing: .bundled)
        let index = try await store.metricsIndex(for: [session])
        XCTAssertFalse(index.days.isEmpty, "metricsIndex should produce daily rows")

        // Re-open and verify the data survives
        let reopened = HistoricalStore(userHome: home)
        let reloaded = try await reopened.metricsIndex()
        XCTAssertEqual(reloaded.sessions.count, 1)
    }

    func testMigrationOnExistingJSONBlobDatabase() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-existing-\(UUID().uuidString)")
        let dbDirectory = home.appendingPathComponent("Library/Application Support/CodexDashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let dbURL = dbDirectory.appendingPathComponent("metrics-v1.sqlite")
        let sqlite = try SQLiteTestHelper(url: dbURL)

        // Create the OLD schema with a JSON blob row
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS metric_daily_index (
                session_id TEXT NOT NULL,
                day REAL NOT NULL,
                metric BLOB NOT NULL,
                PRIMARY KEY(session_id, day)
            )
            """)
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS historical_session (
                id TEXT PRIMARY KEY,
                updated_at REAL NOT NULL,
                metric BLOB NOT NULL,
                summary BLOB
            )
            """)
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS source_session_index (
                source_key TEXT NOT NULL,
                session_id TEXT NOT NULL,
                source_updated_at INTEGER NOT NULL,
                metric BLOB NOT NULL,
                PRIMARY KEY(source_key, session_id)
            )
            """)
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS source_index_checkpoint (
                source_key TEXT PRIMARY KEY,
                max_row_id INTEGER NOT NULL,
                max_updated_at INTEGER NOT NULL
            )
            """)
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS metric_session_index (
                session_id TEXT PRIMARY KEY,
                source_revision TEXT NOT NULL,
                metric BLOB NOT NULL
            )
            """)
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS menu_bar_daily (
                day REAL PRIMARY KEY,
                metric BLOB NOT NULL
            )
            """)
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value BLOB NOT NULL
            )
            """)

        // Insert a JSON blob that matches the old format
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let dailyMetrics = IndexedDailyMetrics(
            sessionID: "old-session-1",
            projectPath: "/tmp/old-project",
            day: day,
            usage: .init(input: 100, cachedInput: 50, cacheWriteInput: 0, output: 200, reasoningOutput: 20, total: 300),
            estimatedCost: 0.05,
            coveredTokens: 50,
            activeRuntime: 120,
            models: [ModelMetric(model: "gpt-4o", sessions: 1, usage: .init(input: 100, cachedInput: 50, cacheWriteInput: 0, output: 200, reasoningOutput: 20, total: 300), activeRuntime: 120, estimatedCost: 0.05)],
            tools: [],
            skills: [],
            turnDurations: [60, 120],
            firstTokenTimes: [1.2],
            toolCalls: 3,
            skillCalls: 1,
            completedTurns: 2
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let blob = try encoder.encode(dailyMetrics)
        try sqlite.execute("INSERT INTO metric_daily_index(session_id, day, metric) VALUES(?,?,?)", bindings: { stmt in
            sqlite3_bind_text(stmt, 1, "old-session-1", -1, sqlite3_transient())
            sqlite3_bind_double(stmt, 2, day.timeIntervalSince1970)
            blob.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, 3, bytes.baseAddress, Int32(bytes.count), sqlite3_transient())
            }
        })

        // Opening HistoricalStore should trigger migration
        let store = HistoricalStore(userHome: home)

        // Verify the typed tables exist and have the migrated data
        let contributionCount = try sqlite.queryInt("SELECT COUNT(*) FROM daily_contribution")
        let modelCount = try sqlite.queryInt("SELECT COUNT(*) FROM daily_model")
        XCTAssertEqual(contributionCount, 1, "daily_contribution should have the migrated row")
        XCTAssertEqual(modelCount, 1, "daily_model should have the migrated model row")

        // Verify the data is correct
        let totalTokens = try sqlite.queryInt("SELECT total_tokens FROM daily_contribution WHERE session_id = 'old-session-1'")
        XCTAssertEqual(totalTokens, 300)
        let projectPath = try sqlite.queryText("SELECT project_path FROM daily_contribution WHERE session_id = 'old-session-1'")
        XCTAssertEqual(projectPath, "/tmp/old-project")
        let modelName = try sqlite.queryText("SELECT model FROM daily_model WHERE session_id = 'old-session-1'")
        XCTAssertEqual(modelName, "gpt-4o")

        // Verify the SQL aggregate queries return the same values
        let agg = try await store.aggregateDaily()
        XCTAssertEqual(agg.usage.total, 300)
        XCTAssertEqual(agg.activeDays, 1)

        let periods = try await store.dailyPeriodRows()
        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(periods[0].usage.total, 300)
        XCTAssertEqual(periods[0].sessions, 1)

        let modelRows = try await store.dailyModelRows()
        XCTAssertEqual(modelRows.count, 1)
        XCTAssertEqual(modelRows[0].model, "gpt-4o")
        XCTAssertEqual(modelRows[0].usage.total, 300)
        XCTAssertEqual(modelRows[0].usage.input, 100)
        XCTAssertEqual(modelRows[0].usage.cachedInput, 50)
        XCTAssertEqual(modelRows[0].usage.output, 200)
        XCTAssertEqual(modelRows[0].estimatedCost, 0.05)
        XCTAssertEqual(modelRows[0].activeRuntime, 120)
    }

    func testAggregateQueriesFilterByProjectAndDate() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("query-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = HistoricalStore(userHome: home)
        let dayA = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
        let dayB = Date(timeIntervalSince1970: 1_700_086_400 + 86_400 * 30) // ~30 days later

        var sessions: [SessionMetric] = []
        for (id, path, date, tokens) in [
            ("s1", "/proj/a", dayA, Int64(100)),
            ("s2", "/proj/b", dayA, Int64(200)),
            ("s3", "/proj/a", dayB, Int64(400)),
        ] {
            sessions.append(SessionMetric(
                id: id, rolloutPath: "/tmp/\(id).jsonl", projectPath: path,
                title: "T\(id)", source: "codex", originator: nil, provider: "openai",
                createdAt: date, updatedAt: date.addingTimeInterval(600),
                model: "gpt-4o", reasoningEffort: nil, gitBranch: nil, cliVersion: nil,
                archived: false,
                usage: .init(input: tokens, output: tokens, total: tokens),
                turns: [], toolCalls: 1, userMessages: 1,
                enrichmentAvailable: true
            ))
        }
        _ = try await store.record(sessions, pricing: .bundled)
        _ = try await store.metricsIndex(for: sessions)

        // All data
        let all = try await store.aggregateDaily()
        XCTAssertEqual(all.usage.total, 700)
        XCTAssertEqual(all.activeDays, 2)

        // Filter by project
        let projA = try await store.aggregateDaily(projectPath: "/proj/a")
        XCTAssertEqual(projA.usage.total, 500)

        // Filter by date range (only dayB onwards)
        let recent = try await store.aggregateDaily(since: dayA.addingTimeInterval(86_400))
        XCTAssertEqual(recent.usage.total, 400)
        XCTAssertEqual(recent.activeDays, 1)

        // Period rows respect filters too
        let projAPeriods = try await store.dailyPeriodRows(projectPath: "/proj/a")
        XCTAssertEqual(projAPeriods.count, 2)
        let projATokens = Set(projAPeriods.map(\.usage.total))
        XCTAssertEqual(projATokens, [100, 400])

        let projectCosts = try await store.sessionCosts(projectPath: "/proj/a")
        XCTAssertEqual(Set(projectCosts.keys), ["s1", "s3"])
        XCTAssertEqual(projectCosts["s1"]?.totalTokens, 100)
        XCTAssertEqual(projectCosts["s3"]?.totalTokens, 400)
    }
}

// Minimal SQLite test helper
final class SQLiteTestHelper {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, bindings: ((OpaquePointer) -> Void)? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
        defer { sqlite3_finalize(stmt) }
        bindings?(stmt!)
        guard sqlite3_step(stmt!) == SQLITE_DONE else {
            throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }

    func queryInt(_ sql: String) throws -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt!) == SQLITE_ROW else {
            throw NSError(domain: "test", code: 4)
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_column_int64(stmt!, 0)
    }

    func queryText(_ sql: String) throws -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt!) == SQLITE_ROW,
              let bytes = sqlite3_column_text(stmt!, 0) else {
            throw NSError(domain: "test", code: 5)
        }
        defer { sqlite3_finalize(stmt) }
        return String(cString: bytes)
    }
}

func sqlite3_transient() -> sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
