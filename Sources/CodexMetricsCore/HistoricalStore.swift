import Foundation
import SQLite3

private struct MetricsIndexContext: Codable {
    let schemaVersion: Int
    let timeZone: String
    let pricing: PricingHistory
}

/// Private transactional store shared by rollout checkpoints and durable metrics.
/// It stores only Codable metric values; rollout conversation content never enters it.
final class MetricsDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    let url: URL

    init(userHome: URL) throws {
        let directory = userHome.appendingPathComponent("Library/Application Support/CodexDashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("metrics-v1.sqlite")
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw CodexStoreError.openFailed(message)
        }
        sqlite3_busy_timeout(handle, 2_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA cache_size=-2000")
        try execute("""
            CREATE TABLE IF NOT EXISTS rollout_checkpoint (
                path TEXT PRIMARY KEY,
                device_id INTEGER,
                file_id INTEGER,
                committed_offset INTEGER NOT NULL,
                modified_at REAL NOT NULL,
                boundary_hash INTEGER,
                enrichment BLOB NOT NULL
            )
            """)
        // Databases created by the first metrics-v1 development build are upgraded
        // in place. Check the schema before altering it so SQLite does not emit a
        // duplicate-column error on every app launch.
        if !tableHasColumn("rollout_checkpoint", named: "boundary_hash") {
            try execute("ALTER TABLE rollout_checkpoint ADD COLUMN boundary_hash INTEGER")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS historical_session (
                id TEXT PRIMARY KEY,
                updated_at REAL NOT NULL,
                metric BLOB NOT NULL,
                summary BLOB
            )
            """)
        if !tableHasColumn("historical_session", named: "summary") {
            try execute("ALTER TABLE historical_session ADD COLUMN summary BLOB")
        }
        if tableExists("daily_model") && !tableHasColumn("daily_model", named: "cached_input") {
            try execute("ALTER TABLE daily_model ADD COLUMN cached_input INTEGER NOT NULL DEFAULT 0")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS source_session_index (
                source_key TEXT NOT NULL,
                session_id TEXT NOT NULL,
                source_updated_at INTEGER NOT NULL,
                metric BLOB NOT NULL,
                PRIMARY KEY(source_key, session_id)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS source_index_checkpoint (
                source_key TEXT PRIMARY KEY,
                max_row_id INTEGER NOT NULL,
                max_updated_at INTEGER NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS metric_session_index (
                session_id TEXT PRIMARY KEY,
                source_revision TEXT NOT NULL,
                metric BLOB NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS metric_daily_index (
                session_id TEXT NOT NULL,
                day REAL NOT NULL,
                metric BLOB NOT NULL,
                PRIMARY KEY(session_id, day)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS menu_bar_daily (
                day REAL PRIMARY KEY,
                metric BLOB NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value BLOB NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS daily_contribution (
                session_id      TEXT NOT NULL,
                day             REAL NOT NULL,
                project_path    TEXT NOT NULL,
                input_tokens    INTEGER NOT NULL DEFAULT 0,
                cached_input    INTEGER NOT NULL DEFAULT 0,
                cache_write     INTEGER NOT NULL DEFAULT 0,
                output_tokens   INTEGER NOT NULL DEFAULT 0,
                reasoning       INTEGER NOT NULL DEFAULT 0,
                total_tokens    INTEGER NOT NULL DEFAULT 0,
                cost            REAL NOT NULL DEFAULT 0,
                covered_tokens  INTEGER NOT NULL DEFAULT 0,
                active_runtime  REAL NOT NULL DEFAULT 0,
                tool_calls      INTEGER NOT NULL DEFAULT 0,
                skill_calls     INTEGER NOT NULL DEFAULT 0,
                completed_turns INTEGER NOT NULL DEFAULT 0,
                aborted_turns   INTEGER NOT NULL DEFAULT 0,
                turn_durations  BLOB,
                first_token_times BLOB,
                PRIMARY KEY(session_id, day)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS daily_model (
                session_id      TEXT NOT NULL,
                day             REAL NOT NULL,
                model           TEXT NOT NULL,
                total_tokens    INTEGER NOT NULL DEFAULT 0,
                input_tokens    INTEGER NOT NULL DEFAULT 0,
                cached_input    INTEGER NOT NULL DEFAULT 0,
                output_tokens   INTEGER NOT NULL DEFAULT 0,
                cost            REAL NOT NULL DEFAULT 0,
                active_runtime  REAL NOT NULL DEFAULT 0,
                PRIMARY KEY(session_id, day, model),
                FOREIGN KEY(session_id, day) REFERENCES daily_contribution(session_id, day)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS tool_daily (
                session_id      TEXT NOT NULL,
                day             REAL NOT NULL,
                tool            TEXT NOT NULL,
                calls           INTEGER NOT NULL DEFAULT 0,
                attributed_calls INTEGER NOT NULL DEFAULT 0,
                cost            REAL NOT NULL DEFAULT 0,
                PRIMARY KEY(session_id, day, tool)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS skill_daily (
                session_id      TEXT NOT NULL,
                day             REAL NOT NULL,
                skill           TEXT NOT NULL,
                calls           INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(session_id, day, skill)
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_daily_day ON daily_contribution(day)")
        try execute("CREATE INDEX IF NOT EXISTS idx_daily_project_day ON daily_contribution(project_path, day)")
        try execute("CREATE INDEX IF NOT EXISTS idx_daily_model_model ON daily_model(model)")
        if !tableExists("daily_contribution_filled") {
            try migrateDailyIndexToTyped()
            try execute("CREATE TABLE IF NOT EXISTS daily_contribution_filled (done INTEGER)")
        }
        // Re-run the typed migration when daily_model gains new columns so existing
        // rows get backfilled with data that was not captured before.
        if tableExists("metric_daily_index") && !tableExists("daily_model_cached_input_filled") {
            try migrateDailyModelCachedInput()
            try execute("CREATE TABLE IF NOT EXISTS daily_model_cached_input_filled (done INTEGER)")
        }
    }


    /// One-time backfill: re-decode metric_daily_index blobs and update cached_input
    /// in daily_model rows that were written before that column existed.
    private func migrateDailyModelCachedInput() throws {
        // Collect all updates first so we never mutate daily_model while its
        // rows are being scanned by the open SELECT cursor.
        let decoder = Self.decoder()
        guard let select = prepare("""
            SELECT m.session_id, m.day, d.metric FROM daily_model m
            JOIN metric_daily_index d ON d.session_id = m.session_id AND d.day = m.day
            WHERE m.cached_input = 0 AND d.metric IS NOT NULL
            """) else { throw databaseError() }
        defer { sqlite3_finalize(select) }

        var updates: [(sessionID: String, day: Double, cachedInput: Int64)] = []
        while sqlite3_step(select) == SQLITE_ROW {
            guard let idBytes = sqlite3_column_text(select, 0),
                  let blob = data(select, 2),
                  let metric = try? decoder.decode(IndexedDailyMetrics.self, from: blob) else { continue }
            let sessionID = String(cString: idBytes)
            let dayKey = sqlite3_column_double(select, 1)
            for model in metric.models where model.usage.cachedInput > 0 {
                updates.append((sessionID, dayKey, model.usage.cachedInput))
            }
        }

        guard !updates.isEmpty,
              let update = prepare("UPDATE daily_model SET cached_input = ? WHERE session_id = ? AND day = ?") else { return }
        defer { sqlite3_finalize(update) }
        for entry in updates {
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
            sqlite3_bind_int64(update, 1, entry.cachedInput)
            bind(entry.sessionID, to: update, at: 2)
            sqlite3_bind_double(update, 3, entry.day)
            guard sqlite3_step(update) == SQLITE_DONE else { throw databaseError() }
        }
    }

    private func tableExists(_ name: String) -> Bool {
        guard let statement = prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?") else { return false }
        defer { sqlite3_finalize(statement) }
        bind(name, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// One-time migration: decode each metric_daily_index JSON blob and insert
    /// typed rows into daily_contribution + daily_model.
    private func migrateDailyIndexToTyped() throws {
        let decoder = Self.decoder()
        let rows: [(sessionID: String, day: Double, data: Data)] = try lockedThrowing {
            guard let statement = prepare("SELECT session_id, day, metric FROM metric_daily_index") else {
                throw databaseError()
            }
            defer { sqlite3_finalize(statement) }
            var result: [(String, Double, Data)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idBytes = sqlite3_column_text(statement, 0),
                      let blob = data(statement, 2) else { continue }
                result.append((String(cString: idBytes), sqlite3_column_double(statement, 1), blob))
            }
            return result
        }

        struct ContributionRow {
            var projectPath = ""
            var usage = TokenUsage.zero
            var estimatedCost = Decimal.zero
            var coveredTokens: Int64 = 0
            var activeRuntime: TimeInterval = 0
            var toolCalls = 0
            var skillCalls = 0
            var completedTurns = 0
            var turnDurations: [TimeInterval] = []
            var firstTokenTimes: [TimeInterval] = []
        }

        struct ModelRow {
            var model = ""
            var tokens: Int64 = 0
            var input: Int64 = 0
            var output: Int64 = 0
            var cost = 0.0
            var runtime = 0.0
        }

        var contributionRows: [(sessionID: String, day: Double, row: ContributionRow)] = []
        var modelRows: [(sessionID: String, day: Double, row: ModelRow)] = []

        for rowData in rows {
            guard let metric = try? decoder.decode(IndexedDailyMetrics.self, from: rowData.data) else { continue }
            var contribution = ContributionRow()
            contribution.projectPath = metric.projectPath
            contribution.usage = metric.usage
            contribution.estimatedCost = metric.estimatedCost
            contribution.coveredTokens = metric.coveredTokens
            contribution.activeRuntime = metric.activeRuntime
            contribution.toolCalls = metric.toolCalls
            contribution.skillCalls = metric.skillCalls
            contribution.completedTurns = metric.completedTurns
            contribution.turnDurations = metric.turnDurations
            contribution.firstTokenTimes = metric.firstTokenTimes

            for model in metric.models {
                var modelRow = ModelRow()
                modelRow.model = model.model
                modelRow.tokens = model.usage.total
                modelRow.input = model.usage.input
                modelRow.output = model.usage.output
                modelRow.cost = NSDecimalNumber(decimal: model.estimatedCost).doubleValue
                modelRow.runtime = model.activeRuntime
                modelRows.append((rowData.sessionID, rowData.day, modelRow))
            }
            contributionRows.append((rowData.sessionID, rowData.day, contribution))
        }

        let durationEncoder = JSONEncoder()
        try transaction {
            guard let insertContribution = prepare("""
                INSERT OR REPLACE INTO daily_contribution(
                    session_id, day, project_path,
                    input_tokens, cached_input, cache_write, output_tokens, reasoning, total_tokens,
                    cost, covered_tokens, active_runtime,
                    tool_calls, skill_calls, completed_turns, aborted_turns,
                    turn_durations, first_token_times
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """) else { throw databaseError() }
            defer { sqlite3_finalize(insertContribution) }

            for (sessionID, day, row) in contributionRows {
                bind(sessionID, to: insertContribution, at: 1)
                sqlite3_bind_double(insertContribution, 2, day)
                bind(row.projectPath, to: insertContribution, at: 3)
                sqlite3_bind_int64(insertContribution, 4, row.usage.input)
                sqlite3_bind_int64(insertContribution, 5, row.usage.cachedInput)
                sqlite3_bind_int64(insertContribution, 6, row.usage.cacheWriteInput)
                sqlite3_bind_int64(insertContribution, 7, row.usage.output)
                sqlite3_bind_int64(insertContribution, 8, row.usage.reasoningOutput)
                sqlite3_bind_int64(insertContribution, 9, row.usage.total)
                sqlite3_bind_double(insertContribution, 10, NSDecimalNumber(decimal: row.estimatedCost).doubleValue)
                sqlite3_bind_int64(insertContribution, 11, row.coveredTokens)
                sqlite3_bind_double(insertContribution, 12, row.activeRuntime)
                sqlite3_bind_int64(insertContribution, 13, Int64(row.toolCalls))
                sqlite3_bind_int64(insertContribution, 14, Int64(row.skillCalls))
                sqlite3_bind_int64(insertContribution, 15, Int64(row.completedTurns))
                // abortedTurns lives in the session-level record; not per-day.
                sqlite3_bind_int64(insertContribution, 16, 0)
                if !row.turnDurations.isEmpty {
                    bind(try durationEncoder.encode(row.turnDurations), to: insertContribution, at: 17)
                } else {
                    sqlite3_bind_null(insertContribution, 17)
                }
                if !row.firstTokenTimes.isEmpty {
                    bind(try durationEncoder.encode(row.firstTokenTimes), to: insertContribution, at: 18)
                } else {
                    sqlite3_bind_null(insertContribution, 18)
                }
                guard sqlite3_step(insertContribution) == SQLITE_DONE else { throw databaseError() }
                sqlite3_reset(insertContribution)
                sqlite3_clear_bindings(insertContribution)
            }

            guard let insertModel = prepare("""
                INSERT OR REPLACE INTO daily_model(
                    session_id, day, model, total_tokens, input_tokens, output_tokens, cost, active_runtime
                ) VALUES(?,?,?,?,?,?,?,?)
                """) else { throw databaseError() }
            defer { sqlite3_finalize(insertModel) }

            for (sessionID, day, row) in modelRows {
                bind(sessionID, to: insertModel, at: 1)
                sqlite3_bind_double(insertModel, 2, day)
                bind(row.model, to: insertModel, at: 3)
                sqlite3_bind_int64(insertModel, 4, row.tokens)
                sqlite3_bind_int64(insertModel, 5, row.input)
                sqlite3_bind_int64(insertModel, 6, row.output)
                sqlite3_bind_double(insertModel, 7, row.cost)
                sqlite3_bind_double(insertModel, 8, row.runtime)
                guard sqlite3_step(insertModel) == SQLITE_DONE else { throw databaseError() }
                sqlite3_reset(insertModel)
                sqlite3_clear_bindings(insertModel)
            }

            // Extract tool and skill data from the same decoded blobs
            let decoder2 = Self.decoder()
            var toolRows: [(sessionID: String, day: Double, tool: String, calls: Int32, attributedCalls: Int32, cost: Double)] = []
            var skillRows: [(sessionID: String, day: Double, skill: String, calls: Int32)] = []
            for rowData in rows {
                guard let metric = try? decoder2.decode(IndexedDailyMetrics.self, from: rowData.data) else { continue }
                for tool in metric.tools {
                    toolRows.append((
                        sessionID: rowData.sessionID,
                        day: rowData.day,
                        tool: tool.tool,
                        calls: Int32(tool.calls),
                        attributedCalls: Int32(tool.attributedCalls),
                        cost: NSDecimalNumber(decimal: tool.estimatedCost).doubleValue
                    ))
                }
                for skill in metric.skills {
                    skillRows.append((
                        sessionID: rowData.sessionID,
                        day: rowData.day,
                        skill: skill.skill,
                        calls: Int32(skill.calls)
                    ))
                }
            }

            if !toolRows.isEmpty {
                guard let insertTool = prepare("""
                    INSERT OR REPLACE INTO tool_daily(session_id, day, tool, calls, attributed_calls, cost)
                    VALUES(?,?,?,?,?,?)
                    """) else { throw databaseError() }
                defer { sqlite3_finalize(insertTool) }
                for row in toolRows {
                    bind(row.sessionID, to: insertTool, at: 1)
                    sqlite3_bind_double(insertTool, 2, row.day)
                    bind(row.tool, to: insertTool, at: 3)
                    sqlite3_bind_int64(insertTool, 4, Int64(row.calls))
                    sqlite3_bind_int64(insertTool, 5, Int64(row.attributedCalls))
                    sqlite3_bind_double(insertTool, 6, row.cost)
                    guard sqlite3_step(insertTool) == SQLITE_DONE else { throw databaseError() }
                    sqlite3_reset(insertTool)
                    sqlite3_clear_bindings(insertTool)
                }
            }

            if !skillRows.isEmpty {
                guard let insertSkill = prepare("""
                    INSERT OR REPLACE INTO skill_daily(session_id, day, skill, calls) VALUES(?,?,?,?)
                    """) else { throw databaseError() }
                defer { sqlite3_finalize(insertSkill) }
                for row in skillRows {
                    bind(row.sessionID, to: insertSkill, at: 1)
                    sqlite3_bind_double(insertSkill, 2, row.day)
                    bind(row.skill, to: insertSkill, at: 3)
                    sqlite3_bind_int64(insertSkill, 4, Int64(row.calls))
                    guard sqlite3_step(insertSkill) == SQLITE_DONE else { throw databaseError() }
                    sqlite3_reset(insertSkill)
                    sqlite3_clear_bindings(insertSkill)
                }
            }
        }
    }

    private func upsertTypedDaily(
        day: IndexedDailyMetrics,
        sessionID: String
    ) throws {
        let dayKey = day.day.timeIntervalSince1970

        guard let insertContribution = prepare("""
            INSERT OR REPLACE INTO daily_contribution(
                session_id, day, project_path,
                input_tokens, cached_input, cache_write, output_tokens, reasoning, total_tokens,
                cost, covered_tokens, active_runtime,
                tool_calls, skill_calls, completed_turns, aborted_turns,
                turn_durations, first_token_times
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """) else { throw databaseError() }
        defer { sqlite3_finalize(insertContribution) }

        let durationEncoder = JSONEncoder()
        bind(sessionID, to: insertContribution, at: 1)
        sqlite3_bind_double(insertContribution, 2, dayKey)
        bind(day.projectPath, to: insertContribution, at: 3)
        sqlite3_bind_int64(insertContribution, 4, day.usage.input)
        sqlite3_bind_int64(insertContribution, 5, day.usage.cachedInput)
        sqlite3_bind_int64(insertContribution, 6, day.usage.cacheWriteInput)
        sqlite3_bind_int64(insertContribution, 7, day.usage.output)
        sqlite3_bind_int64(insertContribution, 8, day.usage.reasoningOutput)
        sqlite3_bind_int64(insertContribution, 9, day.usage.total)
        sqlite3_bind_double(insertContribution, 10, NSDecimalNumber(decimal: day.estimatedCost).doubleValue)
        sqlite3_bind_int64(insertContribution, 11, day.coveredTokens)
        sqlite3_bind_double(insertContribution, 12, day.activeRuntime)
        sqlite3_bind_int64(insertContribution, 13, Int64(day.toolCalls))
        sqlite3_bind_int64(insertContribution, 14, Int64(day.skillCalls))
        sqlite3_bind_int64(insertContribution, 15, Int64(day.completedTurns))
        sqlite3_bind_int64(insertContribution, 16, 0)
        if !day.turnDurations.isEmpty {
            bind(try durationEncoder.encode(day.turnDurations), to: insertContribution, at: 17)
        } else {
            sqlite3_bind_null(insertContribution, 17)
        }
        if !day.firstTokenTimes.isEmpty {
            bind(try durationEncoder.encode(day.firstTokenTimes), to: insertContribution, at: 18)
        } else {
            sqlite3_bind_null(insertContribution, 18)
        }
        guard sqlite3_step(insertContribution) == SQLITE_DONE else { throw databaseError() }

        guard let deleteModel = prepare("DELETE FROM daily_model WHERE session_id = ? AND day = ?") else { throw databaseError() }
        defer { sqlite3_finalize(deleteModel) }
        bind(sessionID, to: deleteModel, at: 1)
        sqlite3_bind_double(deleteModel, 2, dayKey)
        guard sqlite3_step(deleteModel) == SQLITE_DONE else { throw databaseError() }

        guard let insertModel = prepare("""
            INSERT OR REPLACE INTO daily_model(
                session_id, day, model, total_tokens, input_tokens, output_tokens, cost, active_runtime
            ) VALUES(?,?,?,?,?,?,?,?)
            """) else { throw databaseError() }
        defer { sqlite3_finalize(insertModel) }

        for model in day.models {
            sqlite3_reset(insertModel)
            sqlite3_clear_bindings(insertModel)
            bind(sessionID, to: insertModel, at: 1)
            sqlite3_bind_double(insertModel, 2, dayKey)
            bind(model.model, to: insertModel, at: 3)
            sqlite3_bind_int64(insertModel, 4, model.usage.total)
            sqlite3_bind_int64(insertModel, 5, model.usage.input)
            sqlite3_bind_int64(insertModel, 6, model.usage.cachedInput)
            sqlite3_bind_int64(insertModel, 7, model.usage.output)
            sqlite3_bind_double(insertModel, 8, NSDecimalNumber(decimal: model.estimatedCost).doubleValue)
            sqlite3_bind_double(insertModel, 9, model.activeRuntime)
            guard sqlite3_step(insertModel) == SQLITE_DONE else { throw databaseError() }
        }

        // Tools and skills
        try executeUnlocked("DELETE FROM tool_daily WHERE session_id = '\(sessionID)' AND day = '\(dayKey)'")
        try executeUnlocked("DELETE FROM skill_daily WHERE session_id = '\(sessionID)' AND day = '\(dayKey)'")
        if !day.tools.isEmpty {
            guard let insertTool = prepare("""
                INSERT OR REPLACE INTO tool_daily(session_id, day, tool, calls, attributed_calls, cost)
                VALUES(?,?,?,?,?,?)
                """) else { throw databaseError() }
            defer { sqlite3_finalize(insertTool) }
            for tool in day.tools {
                sqlite3_reset(insertTool)
                sqlite3_clear_bindings(insertTool)
                bind(sessionID, to: insertTool, at: 1)
                sqlite3_bind_double(insertTool, 2, dayKey)
                bind(tool.tool, to: insertTool, at: 3)
                sqlite3_bind_int64(insertTool, 4, Int64(tool.calls))
                sqlite3_bind_int64(insertTool, 5, Int64(tool.attributedCalls))
                sqlite3_bind_double(insertTool, 6, NSDecimalNumber(decimal: tool.estimatedCost).doubleValue)
                guard sqlite3_step(insertTool) == SQLITE_DONE else { throw databaseError() }
            }
        }
        if !day.skills.isEmpty {
            guard let insertSkill = prepare("""
                INSERT OR REPLACE INTO skill_daily(session_id, day, skill, calls) VALUES(?,?,?,?)
                """) else { throw databaseError() }
            defer { sqlite3_finalize(insertSkill) }
            for skill in day.skills {
                sqlite3_reset(insertSkill)
                sqlite3_clear_bindings(insertSkill)
                bind(sessionID, to: insertSkill, at: 1)
                sqlite3_bind_double(insertSkill, 2, dayKey)
                bind(skill.skill, to: insertSkill, at: 3)
                sqlite3_bind_int64(insertSkill, 4, Int64(skill.calls))
                guard sqlite3_step(insertSkill) == SQLITE_DONE else { throw databaseError() }
            }
        }
    }

    // MARK: - Typed daily queries

    func aggregateDaily(
        projectPath: String?,
        since startDate: Date?,
        before endDate: Date?
    ) throws -> DailyAggregateResult {
        try lockedThrowing {
            var sql = """
                SELECT SUM(input_tokens), SUM(cached_input), SUM(cache_write),
                       SUM(output_tokens), SUM(reasoning), SUM(total_tokens),
                       SUM(cost), SUM(covered_tokens), SUM(active_runtime),
                       SUM(tool_calls), SUM(skill_calls), SUM(completed_turns),
                       COUNT(DISTINCT day)
                FROM daily_contribution WHERE 1=1
                """
            if projectPath != nil { sql += " AND project_path = ?" }
            if startDate != nil { sql += " AND day >= ?" }
            if endDate != nil { sql += " AND day < ?" }

            guard let statement = prepare(sql) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }

            var index: Int32 = 1
            if let projectPath { bind(projectPath, to: statement, at: index); index += 1 }
            if let startDate { sqlite3_bind_double(statement, index, startDate.timeIntervalSince1970); index += 1 }
            if let endDate { sqlite3_bind_double(statement, index, endDate.timeIntervalSince1970); index += 1 }

            guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
            var result = DailyAggregateResult()
            result.usage = TokenUsage(
                input: int64OrZero(statement, 0),
                cachedInput: int64OrZero(statement, 1),
                cacheWriteInput: int64OrZero(statement, 2),
                output: int64OrZero(statement, 3),
                reasoningOutput: int64OrZero(statement, 4),
                total: int64OrZero(statement, 5)
            )
            result.estimatedCost = doubleOrZero(statement, 6)
            result.coveredTokens = int64OrZero(statement, 7)
            result.activeRuntime = doubleOrZero(statement, 8)
            result.toolCalls = Int(int64OrZero(statement, 9))
            result.skillCalls = Int(int64OrZero(statement, 10))
            result.completedTurns = Int(int64OrZero(statement, 11))
            result.activeDays = Int(int64OrZero(statement, 12))
            return result
        }
    }

    func dailyPeriodRows(
        projectPath: String?,
        since startDate: Date?
    ) throws -> [DailyPeriodRow] {
        try lockedThrowing {
            var sql = """
                SELECT day,
                       SUM(input_tokens), SUM(cached_input), SUM(cache_write),
                       SUM(output_tokens), SUM(reasoning), SUM(total_tokens),
                       SUM(cost), SUM(active_runtime), COUNT(DISTINCT session_id)
                FROM daily_contribution WHERE 1=1
                """
            if projectPath != nil { sql += " AND project_path = ?" }
            if startDate != nil { sql += " AND day >= ?" }
            sql += " GROUP BY day ORDER BY day"

            guard let statement = prepare(sql) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }

            var index: Int32 = 1
            if let projectPath { bind(projectPath, to: statement, at: index); index += 1 }
            if let startDate { sqlite3_bind_double(statement, index, startDate.timeIntervalSince1970); index += 1 }

            var rows: [DailyPeriodRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let usage = TokenUsage(
                    input: int64OrZero(statement, 1),
                    cachedInput: int64OrZero(statement, 2),
                    cacheWriteInput: int64OrZero(statement, 3),
                    output: int64OrZero(statement, 4),
                    reasoningOutput: int64OrZero(statement, 5),
                    total: int64OrZero(statement, 6)
                )
                rows.append(DailyPeriodRow(
                    day: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    usage: usage,
                    estimatedCost: doubleOrZero(statement, 7),
                    activeRuntime: doubleOrZero(statement, 8),
                    sessions: Int(int64OrZero(statement, 9))
                ))
            }
            return rows
        }
    }

    func dailyModelRows(
        projectPath: String?,
        since startDate: Date?
    ) throws -> [DailyModelRow] {
        try lockedThrowing {
            var sql = """
                SELECT m.day, m.model,
                       SUM(m.input_tokens), SUM(m.cached_input), SUM(m.output_tokens), SUM(m.total_tokens),
                       SUM(m.cost), SUM(m.active_runtime), COUNT(DISTINCT m.session_id)
                FROM daily_model m
                JOIN daily_contribution c ON c.session_id = m.session_id AND c.day = m.day
                WHERE 1=1
                """
            if projectPath != nil { sql += " AND c.project_path = ?" }
            if startDate != nil { sql += " AND m.day >= ?" }
            sql += " GROUP BY m.day, m.model ORDER BY m.day, m.model"

            guard let statement = prepare(sql) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }

            var index: Int32 = 1
            if let projectPath { bind(projectPath, to: statement, at: index); index += 1 }
            if let startDate { sqlite3_bind_double(statement, index, startDate.timeIntervalSince1970); index += 1 }

            var rows: [DailyModelRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let day = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
                let model = textValue(statement, 1)
                let inputTotal = int64OrZero(statement, 2)
                let cachedTotal = int64OrZero(statement, 3)
                let outputTotal = int64OrZero(statement, 4)
                let grandTotal = int64OrZero(statement, 5)
                let usage = TokenUsage(
                    input: inputTotal,
                    cachedInput: cachedTotal,
                    cacheWriteInput: 0,
                    output: outputTotal,
                    reasoningOutput: 0,
                    total: grandTotal
                )
                rows.append(DailyModelRow(
                    day: day,
                    model: model ?? "",
                    usage: usage,
                    estimatedCost: doubleOrZero(statement, 6),
                    activeRuntime: doubleOrZero(statement, 7),
                    sessions: Int(int64OrZero(statement, 8))
                ))
            }
            return rows
        }
    }

    func mergedTools(
        projectPath: String?,
        since startDate: Date?
    ) throws -> [MergedToolResult] {
        try lockedThrowing {
            var sql = """
                SELECT t.tool, SUM(t.calls), SUM(t.attributed_calls), COUNT(DISTINCT t.session_id), SUM(t.cost)
                FROM tool_daily t
                JOIN daily_contribution c ON c.session_id = t.session_id AND c.day = t.day
                WHERE 1=1
                """
            if projectPath != nil { sql += " AND c.project_path = ?" }
            if startDate != nil { sql += " AND t.day >= ?" }
            sql += " GROUP BY t.tool ORDER BY SUM(t.calls) DESC"

            guard let statement = prepare(sql) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            if let projectPath { bind(projectPath, to: statement, at: index); index += 1 }
            if let startDate { sqlite3_bind_double(statement, index, startDate.timeIntervalSince1970); index += 1 }

            var results: [MergedToolResult] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_text(statement, 0) else { continue }
                results.append(MergedToolResult(
                    tool: String(cString: bytes),
                    calls: Int(int64OrZero(statement, 1)),
                    attributedCalls: Int(int64OrZero(statement, 2)),
                    sessions: Int(int64OrZero(statement, 3)),
                    estimatedCost: doubleOrZero(statement, 4)
                ))
            }
            return results
        }
    }

    func mergedSkills(
        projectPath: String?,
        since startDate: Date?
    ) throws -> [MergedSkillResult] {
        try lockedThrowing {
            var sql = """
                SELECT s.skill, SUM(s.calls), COUNT(DISTINCT s.session_id)
                FROM skill_daily s
                JOIN daily_contribution c ON c.session_id = s.session_id AND c.day = s.day
                WHERE 1=1
                """
            if projectPath != nil { sql += " AND c.project_path = ?" }
            if startDate != nil { sql += " AND s.day >= ?" }
            sql += " GROUP BY s.skill ORDER BY SUM(s.calls) DESC"

            guard let statement = prepare(sql) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            if let projectPath { bind(projectPath, to: statement, at: index); index += 1 }
            if let startDate { sqlite3_bind_double(statement, index, startDate.timeIntervalSince1970); index += 1 }

            var results: [MergedSkillResult] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_text(statement, 0) else { continue }
                results.append(MergedSkillResult(
                    skill: String(cString: bytes),
                    calls: Int(int64OrZero(statement, 1)),
                    sessions: Int(int64OrZero(statement, 2))
                ))
            }
            return results
        }
    }

    func durationArrays(
        projectPath: String?,
        since startDate: Date?,
        before endDate: Date?
    ) throws -> DurationArrays {
        try lockedThrowing {
            var sql = """
                SELECT turn_durations, first_token_times
                FROM daily_contribution WHERE turn_durations IS NOT NULL AND 1=1
                """
            if projectPath != nil { sql += " AND project_path = ?" }
            if startDate != nil { sql += " AND day >= ?" }
            if endDate != nil { sql += " AND day < ?" }

            guard let statement = prepare(sql) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            if let projectPath { bind(projectPath, to: statement, at: index); index += 1 }
            if let startDate { sqlite3_bind_double(statement, index, startDate.timeIntervalSince1970); index += 1 }
            if let endDate { sqlite3_bind_double(statement, index, endDate.timeIntervalSince1970) }

            let decoder = Self.decoder()
            var result = DurationArrays()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let data = data(statement, 0),
                   let durations = try? decoder.decode([TimeInterval].self, from: data) {
                    result.turnDurations.append(contentsOf: durations)
                }
                if let data = data(statement, 1),
                   let times = try? decoder.decode([TimeInterval].self, from: data) {
                    result.firstTokenTimes.append(contentsOf: times)
                }
            }
            return result
        }
    }

    func sessionCost(sessionID: String) throws -> (estimatedCost: Decimal, coveredTokens: Int64, totalTokens: Int64)? {
        try lockedThrowing {
            guard let statement = prepare(
                "SELECT SUM(cost), SUM(covered_tokens), SUM(total_tokens) FROM daily_contribution WHERE session_id = ?"
            ) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            bind(sessionID, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            let costDouble = doubleOrZero(statement, 0)
            let covered = int64OrZero(statement, 1)
            let total = int64OrZero(statement, 2)
            return (Decimal(costDouble), covered, total)
        }
    }

    func sessionCosts(projectPath: String) throws -> [String: (estimatedCost: Decimal, coveredTokens: Int64, totalTokens: Int64)] {
        try lockedThrowing {
            guard let statement = prepare("""
                SELECT session_id, SUM(cost), SUM(covered_tokens), SUM(total_tokens)
                FROM daily_contribution
                WHERE project_path = ?
                GROUP BY session_id
                """) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            bind(projectPath, to: statement, at: 1)

            var result: [String: (estimatedCost: Decimal, coveredTokens: Int64, totalTokens: Int64)] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idBytes = sqlite3_column_text(statement, 0) else { continue }
                result[String(cString: idBytes)] = (
                    Decimal(doubleOrZero(statement, 1)),
                    int64OrZero(statement, 2),
                    int64OrZero(statement, 3)
                )
            }
            return result
        }
    }

    private func int64OrZero(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? 0 : sqlite3_column_int64(statement, index)
    }
    private func doubleOrZero(_ statement: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? 0 : sqlite3_column_double(statement, index)
    }
    private func textValue(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func rollout(for path: String) -> CachedRollout? {
        locked {
            guard let statement = prepare("SELECT device_id, file_id, committed_offset, modified_at, boundary_hash, enrichment FROM rollout_checkpoint WHERE path = ?") else { return nil }
            defer { sqlite3_finalize(statement) }
            bind(path, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let enrichmentData = data(statement, 5),
                  let enrichment = try? JSONDecoder().decode(RolloutEnrichment.self, from: enrichmentData) else { return nil }
            return CachedRollout(
                fileSize: sqlite3_column_int64(statement, 2),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                enrichment: enrichment,
                deviceID: optionalUInt64(statement, 0),
                fileID: optionalUInt64(statement, 1),
                boundaryHash: optionalUInt64(statement, 4),
                parserVersion: enrichment.parserVersion
            )
        }
    }

    func storeRollout(_ rollout: CachedRollout, for path: String) throws {
        var enrichment = rollout.enrichment
        enrichment.parserVersion = rollout.parserVersion
        let encoded = try JSONEncoder().encode(enrichment)
        try lockedThrowing {
            guard let statement = prepare("""
                INSERT INTO rollout_checkpoint(path, device_id, file_id, committed_offset, modified_at, boundary_hash, enrichment)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    device_id=excluded.device_id, file_id=excluded.file_id,
                    committed_offset=excluded.committed_offset, modified_at=excluded.modified_at,
                    boundary_hash=excluded.boundary_hash, enrichment=excluded.enrichment
                """) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            bind(path, to: statement, at: 1)
            bind(rollout.deviceID, to: statement, at: 2)
            bind(rollout.fileID, to: statement, at: 3)
            sqlite3_bind_int64(statement, 4, rollout.fileSize)
            sqlite3_bind_double(statement, 5, rollout.modifiedAt.timeIntervalSince1970)
            bind(rollout.boundaryHash, to: statement, at: 6)
            bind(encoded, to: statement, at: 7)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        }
    }

    func historicalSessions() throws -> [SessionMetric] {
        try lockedThrowing {
            guard let statement = prepare("SELECT metric FROM historical_session ORDER BY updated_at DESC") else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            let decoder = Self.decoder()
            var result: [SessionMetric] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let encoded = data(statement, 0) else { continue }
                result.append(try decoder.decode(SessionMetric.self, from: encoded))
            }
            return result
        }
    }

    func historicalSession(id: String) throws -> SessionMetric? {
        try lockedThrowing {
            guard let statement = prepare("SELECT metric FROM historical_session WHERE id = ?") else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            bind(id, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW, let encoded = data(statement, 0) else { return nil }
            return try Self.decoder().decode(SessionMetric.self, from: encoded)
        }
    }

    func historicalSessionSummaries() throws -> [SessionSummary] {
        let rows: [(id: String, summary: SessionSummary?)] = try lockedThrowing {
            guard let statement = prepare("SELECT id, summary FROM historical_session ORDER BY updated_at DESC") else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            let decoder = Self.decoder()
            var result: [(id: String, summary: SessionSummary?)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idBytes = sqlite3_column_text(statement, 0) else { continue }
                let id = String(cString: idBytes)
                let summary = data(statement, 1).flatMap {
                    try? decoder.decode(SessionSummary.self, from: $0)
                }
                result.append((id, summary))
            }
            return result
        }

        var result: [SessionSummary] = []
        var backfill: [(String, Data)] = []
        let encoder = Self.encoder()
        for row in rows {
            if let summary = row.summary {
                result.append(summary)
            } else if let full = try historicalSession(id: row.id) {
                let summary = full.summary
                result.append(summary)
                backfill.append((row.id, try encoder.encode(summary)))
            }
        }
        if !backfill.isEmpty {
            try storeHistoricalSummaries(backfill)
        }
        return result
    }

    func historicalSessionCount() throws -> Int {
        try lockedThrowing {
            guard let statement = prepare("SELECT COUNT(*) FROM historical_session") else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func upsertHistoricalSessions(_ sessions: [SessionMetric]) throws {
        guard !sessions.isEmpty else { return }
        let encoder = Self.encoder()
        let encoded = try sessions.map {
            ($0, try encoder.encode($0), try encoder.encode($0.summary))
        }
        try transaction {
            guard let statement = prepare("""
                INSERT INTO historical_session(id, updated_at, metric, summary) VALUES(?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    updated_at=excluded.updated_at, metric=excluded.metric, summary=excluded.summary
                """) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            for (session, bytes, summaryBytes) in encoded {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(session.id, to: statement, at: 1)
                sqlite3_bind_double(statement, 2, session.updatedAt.timeIntervalSince1970)
                bind(bytes, to: statement, at: 3)
                bind(summaryBytes, to: statement, at: 4)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            }
        }
    }

    private func storeHistoricalSummaries(_ summaries: [(String, Data)]) throws {
        try transaction {
            guard let statement = prepare("""
                UPDATE historical_session SET summary = ?
                WHERE id = ? AND summary IS NULL
                """) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            for (id, bytes) in summaries {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(bytes, to: statement, at: 1)
                bind(id, to: statement, at: 2)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            }
        }
    }

    struct SourceIndexCheckpoint: Equatable, Sendable {
        let maxRowID: Int64
        let maxUpdatedAt: Int64
    }

    func sourceIndexCheckpoint(for sourceKey: String) throws -> SourceIndexCheckpoint? {
        try lockedThrowing {
            guard let statement = prepare("SELECT max_row_id, max_updated_at FROM source_index_checkpoint WHERE source_key = ?") else {
                throw databaseError()
            }
            defer { sqlite3_finalize(statement) }
            bind(sourceKey, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return SourceIndexCheckpoint(
                maxRowID: sqlite3_column_int64(statement, 0),
                maxUpdatedAt: sqlite3_column_int64(statement, 1)
            )
        }
    }

    /// Advances the durable mirror of Codex's thread table. The inclusive
    /// updated-at tail is deliberately reread by the source query, while the
    /// WHERE clause below prevents unchanged tail rows from touching SQLite/WAL.
    func updateSourceIndex(
        sourceKey: String,
        sessions: [(metric: SessionMetric, sourceUpdatedAt: Int64)],
        checkpoint: SourceIndexCheckpoint
    ) throws {
        let encoder = Self.encoder()
        let encoded = try sessions.map { ($0.metric, $0.sourceUpdatedAt, try encoder.encode($0.metric)) }
        try transaction {
            guard let upsert = prepare("""
                INSERT INTO source_session_index(source_key, session_id, source_updated_at, metric)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(source_key, session_id) DO UPDATE SET
                    source_updated_at=excluded.source_updated_at, metric=excluded.metric
                WHERE source_session_index.source_updated_at != excluded.source_updated_at
                   OR source_session_index.metric != excluded.metric
                """),
                let storeCheckpoint = prepare("""
                INSERT INTO source_index_checkpoint(source_key, max_row_id, max_updated_at)
                VALUES(?, ?, ?)
                ON CONFLICT(source_key) DO UPDATE SET
                    max_row_id=excluded.max_row_id, max_updated_at=excluded.max_updated_at
                WHERE source_index_checkpoint.max_row_id != excluded.max_row_id
                   OR source_index_checkpoint.max_updated_at != excluded.max_updated_at
                """) else { throw databaseError() }
            defer {
                sqlite3_finalize(upsert)
                sqlite3_finalize(storeCheckpoint)
            }
            for (session, updatedAt, bytes) in encoded {
                sqlite3_reset(upsert)
                sqlite3_clear_bindings(upsert)
                bind(sourceKey, to: upsert, at: 1)
                bind(session.id, to: upsert, at: 2)
                sqlite3_bind_int64(upsert, 3, updatedAt)
                bind(bytes, to: upsert, at: 4)
                guard sqlite3_step(upsert) == SQLITE_DONE else { throw databaseError() }
            }
            bind(sourceKey, to: storeCheckpoint, at: 1)
            sqlite3_bind_int64(storeCheckpoint, 2, checkpoint.maxRowID)
            sqlite3_bind_int64(storeCheckpoint, 3, checkpoint.maxUpdatedAt)
            guard sqlite3_step(storeCheckpoint) == SQLITE_DONE else { throw databaseError() }
        }
    }

    func sourceSessions(for sourceKey: String) throws -> [SessionMetric] {
        try lockedThrowing {
            guard let statement = prepare("SELECT metric FROM source_session_index WHERE source_key = ? ORDER BY source_updated_at DESC") else {
                throw databaseError()
            }
            defer { sqlite3_finalize(statement) }
            bind(sourceKey, to: statement, at: 1)
            let decoder = Self.decoder()
            var result: [SessionMetric] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = data(statement, 0) else { continue }
                result.append(try decoder.decode(SessionMetric.self, from: bytes))
            }
            return result
        }
    }

    func pricing() throws -> PricingHistory? {
        try metadata(PricingHistory.self, key: "pricing")
    }

    func storePricing(_ pricing: PricingHistory) throws {
        try storeMetadata(pricing, key: "pricing")
    }

    func subscription() throws -> SubscriptionSnapshot? {
        try metadata(SubscriptionSnapshot.self, key: "subscription")
    }

    func storeSubscription(_ subscription: SubscriptionSnapshot) throws {
        try storeMetadata(subscription, key: "subscription")
    }

    func menuBarMetrics() throws -> MenuBarMetricsSnapshot? {
        let days: [MenuBarDayMetrics] = try lockedThrowing {
            guard let statement = prepare("SELECT metric FROM menu_bar_daily ORDER BY day") else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            let decoder = Self.decoder()
            var result: [MenuBarDayMetrics] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = data(statement, 0) else { continue }
                result.append(try decoder.decode(MenuBarDayMetrics.self, from: bytes))
            }
            return result
        }
        if !days.isEmpty {
            let generatedAt = try metadata(Date.self, key: "menu_bar_generated_at") ?? .distantPast
            return MenuBarMetricsSnapshot(generatedAt: generatedAt, days: days)
        }
        // Compatibility read for databases created before the per-day projection.
        return try metadata(MenuBarMetricsSnapshot.self, key: "menu_bar_metrics")
    }

    func storeMenuBarMetrics(_ snapshot: MenuBarMetricsSnapshot) throws {
        let encoder = Self.encoder()
        let encoded = try snapshot.days.map { ($0, try encoder.encode($0)) }
        let generatedAt = try encoder.encode(snapshot.generatedAt)
        try transaction {
            guard let select = prepare("SELECT day, metric FROM menu_bar_daily"),
                  let delete = prepare("DELETE FROM menu_bar_daily WHERE day = ?"),
                  let upsert = prepare("""
                    INSERT INTO menu_bar_daily(day, metric) VALUES(?, ?)
                    ON CONFLICT(day) DO UPDATE SET metric=excluded.metric
                    WHERE menu_bar_daily.metric != excluded.metric
                    """),
                  let metadata = prepare("""
                    INSERT INTO metadata(key, value) VALUES('menu_bar_generated_at', ?)
                    ON CONFLICT(key) DO UPDATE SET value=excluded.value
                    """) else { throw databaseError() }
            defer {
                sqlite3_finalize(select)
                sqlite3_finalize(delete)
                sqlite3_finalize(upsert)
                sqlite3_finalize(metadata)
            }
            var stored: [Double: MenuBarDayMetrics] = [:]
            var step = sqlite3_step(select)
            let decoder = Self.decoder()
            while step == SQLITE_ROW {
                if let bytes = data(select, 1),
                   let metric = try? decoder.decode(MenuBarDayMetrics.self, from: bytes) {
                    stored[sqlite3_column_double(select, 0)] = metric
                }
                step = sqlite3_step(select)
            }
            guard step == SQLITE_DONE else { throw databaseError() }
            let replacementDays = Set(snapshot.days.map { $0.day.timeIntervalSince1970 })
            for day in stored.keys where !replacementDays.contains(day) {
                sqlite3_reset(delete)
                sqlite3_clear_bindings(delete)
                sqlite3_bind_double(delete, 1, day)
                guard sqlite3_step(delete) == SQLITE_DONE else { throw databaseError() }
            }
            for (day, bytes) in encoded {
                let key = day.day.timeIntervalSince1970
                guard stored[key] != day else { continue }
                sqlite3_reset(upsert)
                sqlite3_clear_bindings(upsert)
                sqlite3_bind_double(upsert, 1, key)
                bind(bytes, to: upsert, at: 2)
                guard sqlite3_step(upsert) == SQLITE_DONE else { throw databaseError() }
            }
            bind(generatedAt, to: metadata, at: 1)
            guard sqlite3_step(metadata) == SQLITE_DONE else { throw databaseError() }
        }
    }

    func sourceEventID(for key: String) throws -> UInt64? {
        try metadata(UInt64.self, key: key)
    }

    func storeSourceEventID(_ eventID: UInt64, for key: String) throws {
        try storeMetadata(eventID, key: key)
    }

    func loadMetricIndex() throws -> (context: Data?, sessions: [IndexedSessionMetrics], days: [IndexedDailyMetrics]) {
        try lockedThrowing {
            let decoder = Self.decoder()
            var context: Data?
            if let statement = prepare("SELECT value FROM metadata WHERE key = 'metric_index_context'") {
                defer { sqlite3_finalize(statement) }
                if sqlite3_step(statement) == SQLITE_ROW { context = data(statement, 0) }
            }

            guard let sessionStatement = prepare("SELECT session_id, metric FROM metric_session_index"),
                  let dayStatement = prepare("SELECT session_id, metric FROM metric_daily_index") else {
                throw databaseError()
            }
            defer {
                sqlite3_finalize(sessionStatement)
                sqlite3_finalize(dayStatement)
            }
            var sessions: [IndexedSessionMetrics] = []
            var invalidSessionIDs = Set<String>()
            while sqlite3_step(sessionStatement) == SQLITE_ROW {
                guard let idBytes = sqlite3_column_text(sessionStatement, 0) else { continue }
                let sessionID = String(cString: idBytes)
                guard let bytes = data(sessionStatement, 1),
                      let metric = try? decoder.decode(IndexedSessionMetrics.self, from: bytes) else {
                    invalidSessionIDs.insert(sessionID)
                    continue
                }
                sessions.append(metric)
            }
            var days: [IndexedDailyMetrics] = []
            while sqlite3_step(dayStatement) == SQLITE_ROW {
                guard let idBytes = sqlite3_column_text(dayStatement, 0) else { continue }
                let sessionID = String(cString: idBytes)
                guard let bytes = data(dayStatement, 1),
                      let metric = try? decoder.decode(IndexedDailyMetrics.self, from: bytes) else {
                    invalidSessionIDs.insert(sessionID)
                    continue
                }
                days.append(metric)
            }
            return (
                context,
                sessions.filter { !invalidSessionIDs.contains($0.sessionID) },
                days.filter { !invalidSessionIDs.contains($0.sessionID) }
            )
        }
    }

    func updateMetricIndex(
        _ records: [(IndexedSessionMetrics, [IndexedDailyMetrics])],
        context: Data,
        reset: Bool,
        removing sessionIDs: Set<String>
    ) throws {
        let encoder = Self.encoder()
        let encoded = try records.map { record in
            (
                summary: record.0,
                summaryBytes: try encoder.encode(record.0),
                days: try record.1.map { day in (day, try encoder.encode(day)) }
            )
        }
        try transaction {
            if reset {
                try executeUnlocked("DELETE FROM metric_daily_index")
                try executeUnlocked("DELETE FROM metric_session_index")
                try executeUnlocked("DELETE FROM daily_contribution")
                try executeUnlocked("DELETE FROM daily_model")
            }
            guard let deleteDays = prepare("DELETE FROM metric_daily_index WHERE session_id = ?"),
                  let existingDays = prepare("SELECT day, metric FROM metric_daily_index WHERE session_id = ?"),
                  let deleteDay = prepare("DELETE FROM metric_daily_index WHERE session_id = ? AND day = ?"),
                  let deleteSession = prepare("DELETE FROM metric_session_index WHERE session_id = ?"),
                  let upsertSession = prepare("""
                    INSERT INTO metric_session_index(session_id, source_revision, metric) VALUES(?, ?, ?)
                    ON CONFLICT(session_id) DO UPDATE SET source_revision=excluded.source_revision, metric=excluded.metric
                    WHERE metric_session_index.source_revision != excluded.source_revision
                       OR metric_session_index.metric != excluded.metric
                    """),
                  let insertDay = prepare("""
                    INSERT INTO metric_daily_index(session_id, day, metric) VALUES(?, ?, ?)
                    ON CONFLICT(session_id, day) DO UPDATE SET metric=excluded.metric
                    WHERE metric_daily_index.metric != excluded.metric
                    """) else {
                throw databaseError()
            }
            defer {
                sqlite3_finalize(deleteDays)
                sqlite3_finalize(existingDays)
                sqlite3_finalize(deleteDay)
                sqlite3_finalize(deleteSession)
                sqlite3_finalize(upsertSession)
                sqlite3_finalize(insertDay)
            }

            guard let deleteContributions = prepare("DELETE FROM daily_contribution WHERE session_id = ?"),
                  let deleteModels = prepare("DELETE FROM daily_model WHERE session_id = ?") else { throw databaseError() }
            defer {
                sqlite3_finalize(deleteContributions)
                sqlite3_finalize(deleteModels)
            }
            for sessionID in sessionIDs where !reset {
                sqlite3_reset(deleteDays)
                sqlite3_clear_bindings(deleteDays)
                bind(sessionID, to: deleteDays, at: 1)
                guard sqlite3_step(deleteDays) == SQLITE_DONE else { throw databaseError() }
                sqlite3_reset(deleteSession)
                sqlite3_clear_bindings(deleteSession)
                bind(sessionID, to: deleteSession, at: 1)
                guard sqlite3_step(deleteSession) == SQLITE_DONE else { throw databaseError() }
                sqlite3_reset(deleteContributions)
                sqlite3_clear_bindings(deleteContributions)
                bind(sessionID, to: deleteContributions, at: 1)
                guard sqlite3_step(deleteContributions) == SQLITE_DONE else { throw databaseError() }
                sqlite3_reset(deleteModels)
                sqlite3_clear_bindings(deleteModels)
                bind(sessionID, to: deleteModels, at: 1)
                guard sqlite3_step(deleteModels) == SQLITE_DONE else { throw databaseError() }
            }

            for record in encoded {
                let summary = record.summary
                let replacementDays = Set(record.days.map { $0.0.day.timeIntervalSince1970 })
                sqlite3_reset(existingDays)
                sqlite3_clear_bindings(existingDays)
                bind(summary.sessionID, to: existingDays, at: 1)
                var storedDays: [Double: IndexedDailyMetrics] = [:]
                var step = sqlite3_step(existingDays)
                while step == SQLITE_ROW {
                    let day = sqlite3_column_double(existingDays, 0)
                    if let bytes = data(existingDays, 1),
                       let metric = try? Self.decoder().decode(IndexedDailyMetrics.self, from: bytes) {
                        storedDays[day] = metric
                    }
                    step = sqlite3_step(existingDays)
                }
                guard step == SQLITE_DONE else { throw databaseError() }
                for day in storedDays.keys where !replacementDays.contains(day) {
                    sqlite3_reset(deleteDay)
                    sqlite3_clear_bindings(deleteDay)
                    bind(summary.sessionID, to: deleteDay, at: 1)
                    sqlite3_bind_double(deleteDay, 2, day)
                    guard sqlite3_step(deleteDay) == SQLITE_DONE else { throw databaseError() }
                }

                sqlite3_reset(upsertSession)
                sqlite3_clear_bindings(upsertSession)
                bind(summary.sessionID, to: upsertSession, at: 1)
                bind(summary.sourceRevision, to: upsertSession, at: 2)
                bind(record.summaryBytes, to: upsertSession, at: 3)
                guard sqlite3_step(upsertSession) == SQLITE_DONE else { throw databaseError() }

                for (day, bytes) in record.days {
                    let dayKey = day.day.timeIntervalSince1970
                    guard storedDays[dayKey] != day else { continue }
                    sqlite3_reset(insertDay)
                    sqlite3_clear_bindings(insertDay)
                    bind(summary.sessionID, to: insertDay, at: 1)
                    sqlite3_bind_double(insertDay, 2, day.day.timeIntervalSince1970)
                    bind(bytes, to: insertDay, at: 3)
                    guard sqlite3_step(insertDay) == SQLITE_DONE else { throw databaseError() }
                    try upsertTypedDaily(day: day, sessionID: summary.sessionID)
                }
            }

            guard let metadata = prepare("""
                INSERT INTO metadata(key, value) VALUES('metric_index_context', ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """) else { throw databaseError() }
            defer { sqlite3_finalize(metadata) }
            bind(context, to: metadata, at: 1)
            guard sqlite3_step(metadata) == SQLITE_DONE else { throw databaseError() }
        }
    }

    private func metadata<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        try lockedThrowing {
            guard let statement = prepare("SELECT value FROM metadata WHERE key = ?") else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            bind(key, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW, let encoded = data(statement, 0) else { return nil }
            return try Self.decoder().decode(type, from: encoded)
        }
    }

    private func storeMetadata<T: Encodable>(_ value: T, key: String) throws {
        let encoded = try Self.encoder().encode(value)
        try lockedThrowing {
            guard let statement = prepare("INSERT INTO metadata(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value") else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            bind(key, to: statement, at: 1)
            bind(encoded, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        }
    }

    func releaseMemory() {
        locked {
            guard let handle else { return }
            _ = sqlite3_db_release_memory(handle)
            _ = sqlite3_exec(handle, "PRAGMA shrink_memory", nil, nil, nil)
            // Do not force a WAL checkpoint here. This method runs after every
            // menu-bar refresh, and on APFS a passive checkpoint of even a tiny
            // WAL can be accounted as an almost full-database physical write.
            // SQLite's normal automatic checkpointing keeps the WAL bounded;
            // releasing decoded/cache memory does not require durable pages to
            // be copied back to the main database immediately.
        }
        _ = sqlite3_release_memory(Int32.max)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try lockedThrowing {
            try executeUnlocked("BEGIN IMMEDIATE")
            do {
                try body()
                try executeUnlocked("COMMIT")
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    private func execute(_ sql: String) throws { try lockedThrowing { try executeUnlocked(sql) } }

    private func tableHasColumn(_ table: String, named column: String) -> Bool {
        guard let statement = prepare("PRAGMA table_info(\(table))") else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == column { return true }
        }
        return false
    }

    private func executeUnlocked(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }
    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }
    private func databaseError() -> CodexStoreError {
        .queryFailed(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Metrics database unavailable")
    }
    private func locked<T>(_ body: () -> T) -> T { lock.withLock(body) }
    private func lockedThrowing<T>(_ body: () throws -> T) throws -> T { try lock.withLock(body) }
    private func optionalUInt64(_ statement: OpaquePointer, _ index: Int32) -> UInt64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : UInt64(bitPattern: sqlite3_column_int64(statement, index))
    }
    private func data(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }
    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
    }
    private func bind(_ value: UInt64?, to statement: OpaquePointer, at index: Int32) {
        if let value { sqlite3_bind_int64(statement, index, Int64(bitPattern: value)) }
        else { sqlite3_bind_null(statement, index) }
    }
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public struct HistoricalArchive: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let exportedAt: Date
    public let sessions: [SessionMetric]
    public let pricing: PricingHistory

    public init(
        schemaVersion: Int = HistoricalArchive.currentSchemaVersion,
        exportedAt: Date = .now,
        sessions: [SessionMetric],
        pricing: PricingHistory
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.sessions = sessions
        self.pricing = pricing
    }
}

public enum HistoricalStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case archiveTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "History archive schema \(version) is not supported."
        case .archiveTooLarge:
            "History archive exceeds the 500 MB import limit."
        }
    }
}

/// Durable, conversation-free metric history. Unlike the rollout parser cache, this
/// archive is never invalidated when source logs move, disappear, or parser versions change.

/// Aggregated metrics computed by SQLite directly from daily_contribution.
public struct DailyAggregateResult: Sendable {
    public init() {}
    public var usage = TokenUsage.zero
    public var estimatedCost: Double = 0
    public var coveredTokens: Int64 = 0
    public var activeRuntime: TimeInterval = 0
    public var toolCalls = 0
    public var skillCalls = 0
    public var completedTurns = 0
    public var activeDays = 0
}

/// One period bucket from a GROUP BY day query.
public struct DailyPeriodRow: Sendable {
    public let day: Date
    public let usage: TokenUsage
    public let estimatedCost: Double
    public let activeRuntime: TimeInterval
    public let sessions: Int
}

/// One model-day bucket from a GROUP BY day, model query.
public struct DailyModelRow: Sendable {
    public let day: Date
    public let model: String
    public let usage: TokenUsage
    public let estimatedCost: Double
    public let activeRuntime: TimeInterval
    public let sessions: Int
}

/// Merged tool usage across all days.
public struct MergedToolResult: Sendable {
    public let tool: String
    public let calls: Int
    public let attributedCalls: Int
    public let sessions: Int
    public let estimatedCost: Double
}

/// Merged skill usage across all days.
public struct MergedSkillResult: Sendable {
    public let skill: String
    public let calls: Int
    public let sessions: Int
}

/// Duration arrays extracted from typed daily blobs.
public struct DurationArrays: Sendable {
    public init() {}
    public var turnDurations: [TimeInterval] = []
    public var firstTokenTimes: [TimeInterval] = []
}

public actor HistoricalStore {
    public let url: URL
    private var archive: HistoricalArchive?
    private let database: MetricsDatabase?
    private var metricsIndexCache: MetricsIndexSnapshot?
    private var metricsIndexContext: Data?
    private var subscriptionCache: SubscriptionSnapshot?
    private var didLoadSubscription = false

    public init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let directory = userHome.appendingPathComponent("Library/Application Support/CodexDashboard", isDirectory: true)
        self.url = directory.appendingPathComponent("history-v1.json")
        self.database = try? MetricsDatabase(userHome: userHome)
    }

    public func pricingHistory() throws -> PricingHistory {
        if let archive { return archive.pricing.merging(.bundled) }
        if let stored = try database?.pricing() { return stored.merging(.bundled) }
        return try load().pricing.merging(.bundled)
    }

    /// Reads pricing without triggering legacy archive migration. Intended for
    /// the small resident menu process; a refresh worker performs migration.
    public func storedPricingHistory() throws -> PricingHistory {
        (try database?.pricing() ?? .bundled).merging(.bundled)
    }

    // MARK: - Typed daily aggregate queries

    public func aggregateDaily(
        projectPath: String? = nil,
        since startDate: Date? = nil,
        before endDate: Date? = nil
    ) throws -> DailyAggregateResult {
        guard let database else { return DailyAggregateResult() }
        return try database.aggregateDaily(projectPath: projectPath, since: startDate, before: endDate)
    }

    public func dailyPeriodRows(
        projectPath: String? = nil,
        since startDate: Date? = nil
    ) throws -> [DailyPeriodRow] {
        guard let database else { return [] }
        return try database.dailyPeriodRows(projectPath: projectPath, since: startDate)
    }

    public func dailyModelRows(
        projectPath: String? = nil,
        since startDate: Date? = nil
    ) throws -> [DailyModelRow] {
        guard let database else { return [] }
        return try database.dailyModelRows(projectPath: projectPath, since: startDate)
    }

    public func mergedTools(
        projectPath: String? = nil,
        since startDate: Date? = nil
    ) throws -> [MergedToolResult] {
        guard let database else { return [] }
        return try database.mergedTools(projectPath: projectPath, since: startDate)
    }

    public func mergedSkills(
        projectPath: String? = nil,
        since startDate: Date? = nil
    ) throws -> [MergedSkillResult] {
        guard let database else { return [] }
        return try database.mergedSkills(projectPath: projectPath, since: startDate)
    }

    public func durationArrays(
        projectPath: String? = nil,
        since startDate: Date? = nil,
        before endDate: Date? = nil
    ) throws -> DurationArrays {
        guard let database else { return DurationArrays() }
        return try database.durationArrays(projectPath: projectPath, since: startDate, before: endDate)
    }

    public func sessionCost(sessionID: String) throws -> (estimatedCost: Decimal, coveredTokens: Int64, totalTokens: Int64)? {
        guard let database else { return nil }
        return try database.sessionCost(sessionID: sessionID)
    }

    public func sessionCosts(projectPath: String) throws -> [String: (estimatedCost: Decimal, coveredTokens: Int64, totalTokens: Int64)] {
        guard let database else { return [:] }
        return try database.sessionCosts(projectPath: projectPath)
    }

    public func mergedSessions(with indexed: [SessionMetric]) throws -> [SessionMetric] {
        let stored = try load().sessions
        let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        var result = indexed.map { session in
            guard let historical = storedByID[session.id] else { return session }
            let canReuseEnrichment = historical.enrichmentAvailable
                && historical.updatedAt >= session.updatedAt
            return Self.combine(
                historical,
                session,
                enrichmentAvailable: canReuseEnrichment
            )
        }
        let indexedIDs = Set(indexed.map(\.id))
        result.append(contentsOf: stored.filter { !indexedIDs.contains($0.id) })
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func mergedSessionSummaries(with indexed: [SessionMetric]) throws -> [SessionSummary] {
        let storedSummaries = try sessionSummaries()
        let storedByID = Dictionary(uniqueKeysWithValues: storedSummaries.map { ($0.id, $0) })
        var result = indexed.map { session in
            guard let historical = storedByID[session.id] else { return session.summary }
            let canReuseEnrichment = historical.enrichmentAvailable
                && historical.updatedAt >= session.updatedAt
            return Self.combineSummaries(
                historical,
                session.summary,
                enrichmentAvailable: canReuseEnrichment
            )
        }
        let indexedIDs = Set(indexed.map(\.id))
        result.append(contentsOf: storedSummaries.filter { !indexedIDs.contains($0.id) })
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func combineSummaries(
        _ historical: SessionSummary,
        _ indexed: SessionSummary,
        enrichmentAvailable: Bool
    ) -> SessionSummary {
        let enriched = enrichmentAvailable ? historical : indexed
        let title = indexed.title.isEmpty ? historical.title : indexed.title
        let originator = enriched.originator ?? indexed.originator
        let updatedAt = max(historical.updatedAt, indexed.updatedAt)
        let model = enriched.model ?? indexed.model
        let reasoningEffort = enriched.reasoningEffort ?? indexed.reasoningEffort
        let gitBranch = indexed.gitBranch ?? historical.gitBranch
        let cliVersion = indexed.cliVersion ?? historical.cliVersion
        let usage = enriched.usage.total > 0 ? enriched.usage : indexed.usage
        let subscription = historical.subscription ?? indexed.subscription
        return SessionSummary(
            id: indexed.id,
            rolloutPath: indexed.rolloutPath,
            projectPath: indexed.projectPath,
            title: title,
            source: indexed.source,
            originator: originator,
            provider: indexed.provider,
            createdAt: indexed.createdAt,
            updatedAt: updatedAt,
            model: model,
            reasoningEffort: reasoningEffort,
            gitBranch: gitBranch,
            cliVersion: cliVersion,
            archived: indexed.archived,
            usage: usage,
            toolCalls: enriched.toolCalls,
            skillCalls: enriched.skillCalls,
            userMessages: enriched.userMessages,
            completedTurns: enriched.completedTurns,
            abortedTurns: enriched.abortedTurns,
            activeRuntime: enriched.activeRuntime,
            averageTTFT: enriched.averageTTFT,
            subscription: subscription,
            enrichmentAvailable: enrichmentAvailable
        )
    }

    @discardableResult
    public func record(_ sessions: [SessionMetric], pricing: PricingHistory = .bundled) throws -> Int {
        guard !sessions.isEmpty else { return 0 }
        if archive == nil, let database {
            var needsLegacyMigration = false
            if FileManager.default.fileExists(atPath: url.path) {
                needsLegacyMigration = try database.historicalSessionCount() == 0
            }
            if !needsLegacyMigration {
                return try recordIncrementally(sessions, pricing: pricing, database: database)
            }
        }
        let current = try load()
        var byID = Dictionary(uniqueKeysWithValues: current.sessions.map { ($0.id, $0) })
        var changed: [SessionMetric] = []
        for session in sessions where session.enrichmentAvailable {
            let existing = byID[session.id]
            let combined = existing.map {
                Self.combine($0, session, enrichmentAvailable: true)
            } ?? session
            guard combined != existing else { continue }

            // Do not replace a potentially large historical blob while its
            // source JSONL is still being appended. Keep the durable copy at
            // the previous settled checkpoint; the next refresh will retry and
            // persist the latest complete enrichment after the quiet period.
            if Self.shouldPersist(combined, existing: existing) {
                byID[session.id] = combined
                changed.append(combined)
            }
        }
        let mergedPricing = current.pricing.merging(pricing).merging(.bundled)
        archive = HistoricalArchive(
            sessions: byID.values.sorted { $0.updatedAt > $1.updatedAt },
            pricing: mergedPricing
        )
        try persist(
            changedSessions: changed,
            pricingChanged: mergedPricing != current.pricing
        )
        if !changed.isEmpty {
            // Keep the durable projection in step with the changed history rows.
            // Invalidating the whole cache here used to turn every 50-session
            // enrichment batch into a full historical index rebuild.
            _ = try updateMetricsIndex(for: changed, pricing: mergedPricing)
        }
        return byID.count
    }

    /// The menu-bar refresh normally changes one active session. Loading every
    /// historical blob just to discover that the active rollout is still too
    /// fresh to persist creates a large transient object graph on every event.
    /// Merge only the supplied rows while the archive is not already resident.
    private func recordIncrementally(
        _ sessions: [SessionMetric],
        pricing: PricingHistory,
        database: MetricsDatabase
    ) throws -> Int {
        var changed: [SessionMetric] = []
        for session in sessions where session.enrichmentAvailable {
            let existing = try database.historicalSession(id: session.id)
            let combined = existing.map {
                Self.combine($0, session, enrichmentAvailable: true)
            } ?? session
            guard combined != existing, Self.shouldPersist(combined, existing: existing) else {
                continue
            }
            changed.append(combined)
        }

        let storedPricing = (try database.pricing() ?? .bundled).merging(.bundled)
        let mergedPricing = storedPricing.merging(pricing).merging(.bundled)
        try database.upsertHistoricalSessions(changed)
        if mergedPricing != storedPricing {
            try database.storePricing(mergedPricing)
        }
        if !changed.isEmpty {
            _ = try updateMetricsIndex(for: changed, pricing: mergedPricing)
        }
        return try database.historicalSessionCount()
    }

    private static func shouldPersist(_ session: SessionMetric, existing: SessionMetric?) -> Bool {
        guard existing != nil else { return true }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: session.rolloutPath),
              let modified = attributes[.modificationDate] as? Date else {
            // Synthetic/imported sessions and unavailable source files should
            // retain the existing eager persistence behavior.
            return true
        }
        return Date.now.timeIntervalSince(modified) >= MetricsPersistencePolicy.activeRolloutQuietPeriod
    }

    public func export(to destination: URL) throws {
        let current = try load()
        let portable = HistoricalArchive(
            sessions: current.sessions.sorted { $0.updatedAt > $1.updatedAt },
            pricing: current.pricing.merging(.bundled)
        )
        try Self.encode(portable).write(to: destination, options: .atomic)
    }

    @discardableResult
    public func importArchive(from source: URL) throws -> Int {
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > 500_000_000 { throw HistoricalStoreError.archiveTooLarge }
        let imported = try Self.decode(Data(contentsOf: source))
        guard imported.schemaVersion == HistoricalArchive.currentSchemaVersion else {
            throw HistoricalStoreError.unsupportedSchema(imported.schemaVersion)
        }
        let current = try load()
        var byID = Dictionary(uniqueKeysWithValues: current.sessions.map { ($0.id, $0) })
        var changed: [SessionMetric] = []
        for session in imported.sessions {
            let existing = byID[session.id]
            let combined = existing.map {
                Self.combine($0, session, enrichmentAvailable: true)
            } ?? session
            byID[session.id] = combined
            if combined != existing { changed.append(combined) }
        }
        let mergedPricing = current.pricing.merging(imported.pricing).merging(.bundled)
        archive = HistoricalArchive(
            sessions: byID.values.sorted { $0.updatedAt > $1.updatedAt },
            pricing: mergedPricing
        )
        try persist(
            changedSessions: changed,
            pricingChanged: mergedPricing != current.pricing
        )
        return imported.sessions.count
    }

    public func sessionCount() throws -> Int {
        if let database { return try database.historicalSessionCount() }
        return try load().sessions.count
    }

    public func storedSessionCount() throws -> Int {
        if let database { return try database.historicalSessionCount() }
        return try load().sessions.count
    }

    public func requiresLegacyMigration() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try database?.historicalSessionCount() == 0
    }

    public func menuBarMetricsSnapshot() throws -> MenuBarMetricsSnapshot? {
        try database?.menuBarMetrics()
    }

    public func recordMenuBarMetrics(_ snapshot: MenuBarMetricsSnapshot) throws {
        // generatedAt changes on every refresh; compare the actual compact
        // metrics so an unchanged snapshot does not create another SQLite/WAL
        // transaction.
        if let existing = try database?.menuBarMetrics(), existing.days == snapshot.days {
            return
        }
        try database?.storeMenuBarMetrics(snapshot)
    }

    /// Drops decoded history and index values after a menu-bar refresh. SQLite
    /// remains the source of truth, so the next dashboard load can hydrate them
    /// again without keeping the largest object graphs resident while idle.
    public func releaseMemory() {
        archive = nil
        metricsIndexCache = nil
        metricsIndexContext = nil
        database?.releaseMemory()
    }

    public func session(withID id: String) throws -> SessionMetric? {
        if let memorySession = archive?.sessions.first(where: { $0.id == id }) {
            return memorySession
        }
        return try database?.historicalSession(id: id)
    }

    public func sessionSummaries() throws -> [SessionSummary] {
        if let archive {
            return archive.sessions.map(\.summary)
        }
        if let database {
            return try database.historicalSessionSummaries()
        }
        return try load().sessions.map(\.summary)
    }

    public func sessions(withIDs ids: Set<String>) throws -> [SessionMetric] {
        try load().sessions.filter { ids.contains($0.id) }
    }

    public func subscriptionSnapshot() throws -> SubscriptionSnapshot? {
        if didLoadSubscription { return subscriptionCache }
        subscriptionCache = try database?.subscription()
        didLoadSubscription = true
        return subscriptionCache
    }

    public func recordSubscription(_ snapshot: SubscriptionSnapshot) throws {
        guard snapshot.isUsable else { return }
        let existing = try subscriptionSnapshot()
        if let existing, existing.observedAt > snapshot.observedAt || existing == snapshot { return }
        if let database { try database.storeSubscription(snapshot) }
        subscriptionCache = snapshot
        didLoadSubscription = true
    }

    public func sourceEventID(for codexHome: URL) throws -> UInt64? {
        try database?.sourceEventID(for: sourceEventKey(codexHome))
    }

    public func recordSourceEventID(_ eventID: UInt64, for codexHome: URL) throws {
        let key = sourceEventKey(codexHome)
        let existing = try database?.sourceEventID(for: key)
        guard existing.map({ $0 < eventID }) ?? true else { return }
        if let database { try database.storeSourceEventID(eventID, for: key) }
    }

    private func sourceEventKey(_ codexHome: URL) -> String {
        "source_event_id:\(codexHome.standardizedFileURL.path)"
    }

    /// Returns the cached or stored metrics index without loading full session histories into memory.
    public func metricsIndex(
        pricing: PricingHistory = .bundled,
        calendar: Calendar = .current
    ) throws -> MetricsIndexSnapshot {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let contextValue = MetricsIndexContext(
            schemaVersion: 3,
            timeZone: calendar.timeZone.identifier,
            pricing: pricing
        )
        let context = try encoder.encode(contextValue)

        if metricsIndexCache == nil {
            if let database {
                let stored = try database.loadMetricIndex()
                metricsIndexContext = stored.context
                metricsIndexCache = MetricsIndexSnapshot(sessions: stored.sessions, days: stored.days)
            } else {
                metricsIndexCache = .empty
            }
        }
        if metricsIndexContext == context, let cached = metricsIndexCache {
            return cached
        }
        if let cached = metricsIndexCache,
           canAdvanceMetricsIndexContext(to: contextValue, current: cached) {
            try database?.updateMetricIndex([], context: context, reset: false, removing: [])
            metricsIndexContext = context
            return cached
        }
        if let archive {
            return try metricsIndex(for: archive.sessions, pricing: pricing, calendar: calendar)
        }
        if let database {
            let stored = try database.historicalSessions()
            return try metricsIndex(for: stored, pricing: pricing, calendar: calendar)
        }
        return .empty
    }

    /// Incrementally replaces only the metric-index contribution for the
    /// supplied sessions. This is intentionally separate from historical blob
    /// persistence: an active rollout can update the compact index immediately
    /// while its larger full-session archive remains at the last quiet checkpoint.
    public func updateMetricsIndex(
        for changedSessions: [SessionMetric],
        pricing: PricingHistory = .bundled,
        calendar: Calendar = .current
    ) throws -> MetricsIndexSnapshot {
        struct Context: Codable {
            let schemaVersion: Int
            let timeZone: String
            let pricing: PricingHistory
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let context = try encoder.encode(Context(
            schemaVersion: 3,
            timeZone: calendar.timeZone.identifier,
            pricing: pricing
        ))

        // Hydrate the cache from SQLite once, without decoding session histories.
        if metricsIndexCache == nil {
            if let database {
                let stored = try database.loadMetricIndex()
                metricsIndexContext = stored.context
                metricsIndexCache = MetricsIndexSnapshot(sessions: stored.sessions, days: stored.days)
            } else {
                metricsIndexCache = .empty
            }
        }
        guard metricsIndexContext == context, let current = metricsIndexCache else {
            // Pricing/timezone/schema changed: the full rebuild path owns this.
            return try metricsIndex(pricing: pricing, calendar: calendar)
        }

        // Compare only the supplied sessions against their stored contributions.
        let existingByID = Dictionary(uniqueKeysWithValues: current.sessions.map { ($0.sessionID, $0) })
        let changedRecords = changedSessions.compactMap { session -> (IndexedSessionMetrics, [IndexedDailyMetrics])? in
            guard existingByID[session.id]?.sourceRevision != MetricsIndexBuilder.sourceRevision(for: session) else {
                return nil
            }
            let built = MetricsIndexBuilder.build(session: session, pricing: pricing, calendar: calendar)
            return (built.session, built.days)
        }
        guard !changedRecords.isEmpty else { return current }

        let changedIDs = Set(changedRecords.map { $0.0.sessionID })
        let snapshot = MetricsIndexSnapshot(
            sessions: current.sessions.filter { !changedIDs.contains($0.sessionID) } + changedRecords.map { $0.0 },
            days: current.days.filter { !changedIDs.contains($0.sessionID) } + changedRecords.flatMap { $0.1 }
        )
        if let database {
            try database.updateMetricIndex(
                changedRecords,
                context: context,
                reset: false,
                removing: []
            )
        }
        metricsIndexCache = snapshot
        return snapshot
    }

    /// Returns a durable incremental index. Only new or advanced sessions are rebuilt;
    /// pricing or timezone changes reset the affected historical costs and day boundaries.
    public func metricsIndex(
        for sessions: [SessionMetric],
        pricing: PricingHistory = .bundled,
        calendar: Calendar = .current
    ) throws -> MetricsIndexSnapshot {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let contextValue = MetricsIndexContext(
            schemaVersion: 3,
            timeZone: calendar.timeZone.identifier,
            pricing: pricing
        )
        let context = try encoder.encode(contextValue)

        if metricsIndexCache == nil {
            if let database {
                let stored = try database.loadMetricIndex()
                metricsIndexContext = stored.context
                metricsIndexCache = MetricsIndexSnapshot(sessions: stored.sessions, days: stored.days)
            } else {
                metricsIndexCache = .empty
            }
        }

        let contextCanAdvance = canAdvanceMetricsIndexContext(
            to: contextValue,
            current: metricsIndexCache ?? .empty
        )
        let reset = metricsIndexContext != context && !contextCanAdvance
        let current = reset ? .empty : (metricsIndexCache ?? .empty)
        let validIDs = Set(sessions.map(\.id))
        let existing = Dictionary(uniqueKeysWithValues: current.sessions.map { ($0.sessionID, $0) })
        let changedSessions = sessions.filter { session in
            existing[session.id]?.sourceRevision != MetricsIndexBuilder.sourceRevision(for: session)
        }
        let changedRecords = changedSessions.map {
            MetricsIndexBuilder.build(session: $0, pricing: pricing, calendar: calendar)
        }
        let changedIDs = Set(changedRecords.map { $0.session.sessionID })
        let staleIDs = Set(current.sessions.map(\.sessionID)).subtracting(validIDs)

        let summaries = current.sessions.filter {
            validIDs.contains($0.sessionID) && !changedIDs.contains($0.sessionID)
        } + changedRecords.map(\.session)
        let daily = current.days.filter {
            validIDs.contains($0.sessionID) && !changedIDs.contains($0.sessionID)
        } + changedRecords.flatMap(\.days)
        let snapshot = MetricsIndexSnapshot(sessions: summaries, days: daily)

        if let database, reset || !changedRecords.isEmpty || !staleIDs.isEmpty {
            try database.updateMetricIndex(
                changedRecords.map { ($0.session, $0.days) },
                context: context,
                reset: reset,
                removing: staleIDs
            )
        }
        metricsIndexContext = context
        metricsIndexCache = snapshot
        return snapshot
    }

    /// An appended rate card whose effective date is later than every indexed
    /// session cannot change any stored cost. Advance only the context marker;
    /// future/changed sessions will naturally use the new schedule.
    private func canAdvanceMetricsIndexContext(
        to next: MetricsIndexContext,
        current: MetricsIndexSnapshot
    ) -> Bool {
        guard let encoded = metricsIndexContext else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let previous = try? decoder.decode(MetricsIndexContext.self, from: encoded),
              previous.schemaVersion == next.schemaVersion,
              previous.timeZone == next.timeZone else { return false }
        let previousSchedules = Set(previous.pricing.schedules)
        let nextSchedules = Set(next.pricing.schedules)
        guard previousSchedules.isSubset(of: nextSchedules) else { return false }
        let additions = nextSchedules.subtracting(previousSchedules)
        guard !additions.isEmpty else { return true }
        let latestIndexedDate = current.sessions.map(\.updatedAt).max() ?? .distantPast
        return additions.allSatisfy { $0.effectiveAt > latestIndexedDate }
    }

    public func recordPricing(_ pricing: PricingHistory) throws {
        let current = try load()
        let merged = current.pricing.merging(pricing).merging(.bundled)
        guard merged != current.pricing else { return }
        archive = HistoricalArchive(
            sessions: current.sessions,
            pricing: merged
        )
        if let database {
            try database.storePricing(archive!.pricing)
        } else {
            try persistJSON()
        }
    }

    private func load() throws -> HistoricalArchive {
        if let archive { return archive }
        if let database {
            let stored = try database.historicalSessions()
            let storedPricing = try database.pricing()
            if !stored.isEmpty || storedPricing != nil {
                let loaded = HistoricalArchive(sessions: stored, pricing: (storedPricing ?? .bundled).merging(.bundled))
                archive = loaded
                return loaded
            }
            // One-time migration from the former whole-file JSON archive.
            if FileManager.default.fileExists(atPath: url.path) {
                let decoded = try Self.decode(Data(contentsOf: url))
                guard decoded.schemaVersion == HistoricalArchive.currentSchemaVersion else {
                    throw HistoricalStoreError.unsupportedSchema(decoded.schemaVersion)
                }
                try database.upsertHistoricalSessions(decoded.sessions)
                try database.storePricing(decoded.pricing.merging(.bundled))
                archive = decoded
                let backup = url.deletingLastPathComponent().appendingPathComponent("history-v1.migrated.json")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.moveItem(at: url, to: backup)
                }
                return decoded
            }
            let empty = HistoricalArchive(sessions: [], pricing: .bundled)
            archive = empty
            return empty
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let empty = HistoricalArchive(sessions: [], pricing: .bundled)
            archive = empty
            return empty
        }
        let decoded = try Self.decode(Data(contentsOf: url))
        guard decoded.schemaVersion == HistoricalArchive.currentSchemaVersion else {
            throw HistoricalStoreError.unsupportedSchema(decoded.schemaVersion)
        }
        archive = decoded
        return decoded
    }

    private func persist(changedSessions: [SessionMetric], pricingChanged: Bool) throws {
        guard let archive else { return }
        if let database {
            try database.upsertHistoricalSessions(changedSessions)
            if pricingChanged { try database.storePricing(archive.pricing) }
            return
        }
        try persistJSON()
    }

    private func persistJSON() throws {
        guard let archive else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.encode(archive).write(to: url, options: .atomic)
    }

    private static func encode(_ archive: HistoricalArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    private static func decode(_ data: Data) throws -> HistoricalArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(HistoricalArchive.self, from: data)
    }

    private static func combine(
        _ older: SessionMetric,
        _ newer: SessionMetric,
        enrichmentAvailable: Bool
    ) -> SessionMetric {
        let preferred = newer.updatedAt >= older.updatedAt ? newer : older
        let fallback = newer.updatedAt >= older.updatedAt ? older : newer
        let events = Array(Set(older.usageEvents + newer.usageEvents)).sorted { $0.date < $1.date }
        let turns = Array(Set(older.turns + newer.turns)).sorted { $0.completedAt < $1.completedAt }
        let eventUsage = events.reduce(TokenUsage.zero) { $0 + $1.usage }
        let usage = eventUsage.total > 0 ? eventUsage : preferred.usage
        let toolCallEvents: [ToolCallEvent]?
        let skillCallEvents: [SkillCallEvent]?
        if enrichmentAvailable, newer.enrichmentAvailable {
            // A full parser pass is authoritative. Replacing detail prevents stale
            // parser labels (such as bare `exec`) from surviving cache upgrades.
            toolCallEvents = newer.toolCallEvents
            skillCallEvents = newer.skillCallEvents
        } else {
            toolCallEvents = Array(Set((older.toolCallEvents ?? []) + (newer.toolCallEvents ?? []))).sorted { $0.date < $1.date }
            skillCallEvents = Array(Set((older.skillCallEvents ?? []) + (newer.skillCallEvents ?? []))).sorted { $0.date < $1.date }
        }
        return SessionMetric(
            id: preferred.id,
            rolloutPath: preferred.rolloutPath.isEmpty ? fallback.rolloutPath : preferred.rolloutPath,
            projectPath: preferred.projectPath,
            title: preferred.title,
            source: preferred.source,
            originator: preferred.originator ?? fallback.originator,
            provider: preferred.provider,
            createdAt: min(older.createdAt, newer.createdAt),
            updatedAt: max(older.updatedAt, newer.updatedAt),
            model: preferred.model ?? fallback.model,
            reasoningEffort: preferred.reasoningEffort ?? fallback.reasoningEffort,
            gitBranch: preferred.gitBranch ?? fallback.gitBranch,
            cliVersion: preferred.cliVersion ?? fallback.cliVersion,
            archived: preferred.archived,
            usage: usage,
            usageEvents: events,
            turns: turns,
            toolCalls: max(older.toolCalls, newer.toolCalls),
            toolCallEvents: toolCallEvents,
            skillCallEvents: skillCallEvents,
            userMessages: max(older.userMessages, newer.userMessages),
            abortedTurns: max(older.abortedTurns, newer.abortedTurns),
            subscription: [older.subscription, newer.subscription]
                .compactMap { $0 }
                .max { $0.observedAt < $1.observedAt },
            enrichmentAvailable: enrichmentAvailable
        )
    }
}
