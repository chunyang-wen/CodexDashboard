import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#endif

public enum CodexStoreError: LocalizedError {
    case databaseNotFound
    case openFailed(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound: "Could not find state_5.sqlite under the Codex data directory."
        case .openFailed(let message): "Could not open Codex database: \(message)"
        case .queryFailed(let message): "Could not read Codex sessions: \(message)"
        }
    }
}

public final class CodexStore: @unchecked Sendable {
    public let codexHome: URL
    private let userHome: URL

    public init(codexHome: URL? = nil, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.userHome = userHome
        self.codexHome = codexHome ?? userHome.appendingPathComponent(".codex", isDirectory: true)
    }

    public func loadSessions(enrich: Bool = true) throws -> [SessionMetric] {
        let sessions = try loadIndexedSessions()
        return enrich ? enrichSessions(sessions) : sessions
    }

    /// Loads the compact Codex index without scanning rollout JSONL files.
    public func loadIndexedSessions(reconcile: Bool = false) throws -> [SessionMetric] {
        // Keep a durable mirror of the source index. After the first successful
        // load, normal starts and FSEvent refreshes read only newly inserted rows
        // or the small inclusive updated-at tail instead of scanning all threads.
        if let cache = try? MetricsDatabase(userHome: userHome) {
            return try loadIndexedSessions(using: cache, reconcile: reconcile)
        }
        return try loadIndexedSessionsWithoutCache()
    }

    /// Loads only source-index rows discovered after the durable checkpoint.
    /// The caller owns the already loaded snapshot and can patch these rows in place.
    public func loadIndexedSessionChanges() throws -> [SessionMetric] {
        if let cache = try? MetricsDatabase(userHome: userHome) {
            return try loadIndexedSessionChanges(using: cache)
        }
        return try loadIndexedSessionsWithoutCache()
    }

    /// Loads compact index rows for the supplied rollout files without scanning
    /// the full source index or advancing its checkpoint.
    public func loadIndexedSessions(forRolloutPaths paths: Set<String>) throws -> [SessionMetric] {
        guard !paths.isEmpty else { return [] }
        let databaseURLs = try locateDatabases()
        var lastFailure: DatabaseReadFailure?
        for (candidateIndex, databaseURL) in databaseURLs.enumerated() {
            let attemptCount = candidateIndex == 0 ? 6 : 2
            for attempt in 0..<attemptCount {
                do {
                    return try readIndexedSessions(
                        from: databaseURL,
                        after: nil,
                        rolloutPaths: paths
                    ).sessions.map(\.metric).sorted { $0.updatedAt > $1.updatedAt }
                } catch let failure as DatabaseReadFailure {
                    lastFailure = failure
                    guard failure.isTransient, attempt < attemptCount - 1 else { break }
                    Thread.sleep(forTimeInterval: 0.05 * pow(2, Double(attempt)))
                }
            }
        }
        throw lastFailure?.publicError ?? CodexStoreError.openFailed("Unknown error")
    }

    private func loadIndexedSessions(using cache: MetricsDatabase, reconcile: Bool) throws -> [SessionMetric] {
        let sourceKey = codexHome.standardizedFileURL.path
        let checkpoint = reconcile ? nil : try cache.sourceIndexCheckpoint(for: sourceKey)
        let databaseURLs = try locateDatabases()
        var lastFailure: DatabaseReadFailure?
        for (candidateIndex, databaseURL) in databaseURLs.enumerated() {
            let attemptCount = candidateIndex == 0 ? 6 : 2
            for attempt in 0..<attemptCount {
                do {
                    let delta = try readIndexedSessions(from: databaseURL, after: checkpoint)
                    let nextCheckpoint = MetricsDatabase.SourceIndexCheckpoint(
                        maxRowID: max(checkpoint?.maxRowID ?? 0, delta.maxRowID),
                        maxUpdatedAt: max(checkpoint?.maxUpdatedAt ?? 0, delta.maxUpdatedAt)
                    )
                    try cache.updateSourceIndex(
                        sourceKey: sourceKey,
                        sessions: delta.sessions,
                        checkpoint: nextCheckpoint,
                        replacing: reconcile
                    )
                    return try cache.sourceSessions(for: sourceKey)
                } catch let failure as DatabaseReadFailure {
                    lastFailure = failure
                    guard failure.isTransient, attempt < attemptCount - 1 else { break }
                    Thread.sleep(forTimeInterval: 0.05 * pow(2, Double(attempt)))
                }
            }
        }
        throw lastFailure?.publicError ?? CodexStoreError.openFailed("Unknown error")
    }

    private func loadIndexedSessionChanges(using cache: MetricsDatabase) throws -> [SessionMetric] {
        let sourceKey = codexHome.standardizedFileURL.path
        let checkpoint = try cache.sourceIndexCheckpoint(for: sourceKey)
        let databaseURLs = try locateDatabases()
        var lastFailure: DatabaseReadFailure?
        for (candidateIndex, databaseURL) in databaseURLs.enumerated() {
            let attemptCount = candidateIndex == 0 ? 6 : 2
            for attempt in 0..<attemptCount {
                do {
                    let delta = try readIndexedSessions(from: databaseURL, after: checkpoint)
                    let nextCheckpoint = MetricsDatabase.SourceIndexCheckpoint(
                        maxRowID: max(checkpoint?.maxRowID ?? 0, delta.maxRowID),
                        maxUpdatedAt: max(checkpoint?.maxUpdatedAt ?? 0, delta.maxUpdatedAt)
                    )
                    let changed = try cache.changedSourceSessions(
                        sourceKey: sourceKey,
                        sessions: delta.sessions
                    )
                    try cache.updateSourceIndex(
                        sourceKey: sourceKey,
                        sessions: delta.sessions,
                        checkpoint: nextCheckpoint
                    )
                    return changed.map(\.metric).sorted { $0.updatedAt > $1.updatedAt }
                } catch let failure as DatabaseReadFailure {
                    lastFailure = failure
                    guard failure.isTransient, attempt < attemptCount - 1 else { break }
                    Thread.sleep(forTimeInterval: 0.05 * pow(2, Double(attempt)))
                }
            }
        }
        throw lastFailure?.publicError ?? CodexStoreError.openFailed("Unknown error")
    }

    private func loadIndexedSessionsWithoutCache() throws -> [SessionMetric] {
        let databaseURLs = try locateDatabases()
        var lastFailure: DatabaseReadFailure?
        for (candidateIndex, databaseURL) in databaseURLs.enumerated() {
            let attemptCount = candidateIndex == 0 ? 6 : 2
            for attempt in 0..<attemptCount {
                do {
                    return try readIndexedSessions(from: databaseURL, after: nil).sessions
                        .map(\.metric)
                        .sorted { $0.updatedAt > $1.updatedAt }
                } catch let failure as DatabaseReadFailure {
                    lastFailure = failure
                    guard failure.isTransient, attempt < attemptCount - 1 else { break }
                    // Codex replaces and checkpoints its live database atomically. Give
                    // that replacement time to settle, then reopen from a fresh handle.
                    Thread.sleep(forTimeInterval: 0.05 * pow(2, Double(attempt)))
                }
            }
        }
        throw lastFailure?.publicError ?? CodexStoreError.openFailed("Unknown error")
    }

    private struct SourceIndexDelta {
        let sessions: [(metric: SessionMetric, sourceUpdatedAt: Int64)]
        let maxRowID: Int64
        let maxUpdatedAt: Int64
    }

    private func readIndexedSessions(
        from databaseURL: URL,
        after checkpoint: MetricsDatabase.SourceIndexCheckpoint?,
        rolloutPaths: Set<String> = []
    ) throws -> SourceIndexDelta {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            let code = database.map(sqlite3_extended_errcode) ?? openResult
            if let database { sqlite3_close(database) }
            throw DatabaseReadFailure.open(code: code, message: message)
        }
        defer { sqlite3_close(database) }
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 250)

        let columns = try tableColumns(database)
        let names = ["id", "rollout_path", "cwd", "title", "source", "model_provider", "created_at", "updated_at", "tokens_used", "model", "reasoning_effort", "git_branch", "cli_version", "archived"]
        let selections = names.map { columns.contains($0) ? $0 : "NULL AS \($0)" }.joined(separator: ", ")
        let sql: String
        if !rolloutPaths.isEmpty {
            guard columns.contains("rollout_path") else {
                throw DatabaseReadFailure.query(code: SQLITE_ERROR, message: "threads.rollout_path is unavailable")
            }
            let placeholders = Array(repeating: "?", count: rolloutPaths.count).joined(separator: ",")
            sql = "SELECT rowid, \(selections) FROM threads WHERE rollout_path IN (\(placeholders))"
        } else if checkpoint == nil {
            sql = "SELECT rowid, \(selections) FROM threads"
        } else {
            // Keep the two high-water predicates as separate UNION branches.
            // SQLite can then use its rowid and updated_at indexes independently;
            // a single OR predicate degrades to a complete updated_at index scan.
            sql = """
                SELECT rowid, \(selections) FROM threads WHERE rowid > ?
                UNION
                SELECT rowid, \(selections) FROM threads WHERE updated_at >= ?
                """
        }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw DatabaseReadFailure.query(
                code: sqlite3_extended_errcode(database),
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        if !rolloutPaths.isEmpty {
            for (index, path) in rolloutPaths.sorted().enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), path, -1, Self.transient)
            }
        } else if let checkpoint {
            sqlite3_bind_int64(statement, 1, checkpoint.maxRowID)
            sqlite3_bind_int64(statement, 2, checkpoint.maxUpdatedAt)
        }

        var sessions: [(metric: SessionMetric, sourceUpdatedAt: Int64)] = []
        var maxRowID = checkpoint?.maxRowID ?? 0
        var maxUpdatedAt = checkpoint?.maxUpdatedAt ?? 0
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            let rowID = int(statement, 0)
            let sourceUpdatedAt = int(statement, 8)
            maxRowID = max(maxRowID, rowID)
            maxUpdatedAt = max(maxUpdatedAt, sourceUpdatedAt)
            let total = int(statement, 9)
            let metric = SessionMetric(
                id: text(statement, 1) ?? UUID().uuidString,
                rolloutPath: text(statement, 2) ?? "",
                projectPath: normalizedPath(text(statement, 3) ?? "Unknown"),
                title: text(statement, 4) ?? "",
                source: text(statement, 5) ?? "unknown",
                provider: text(statement, 6) ?? "unknown",
                createdAt: Date(timeIntervalSince1970: Double(int(statement, 7))),
                updatedAt: Date(timeIntervalSince1970: Double(sourceUpdatedAt)),
                model: text(statement, 10),
                reasoningEffort: text(statement, 11),
                gitBranch: text(statement, 12),
                cliVersion: text(statement, 13),
                archived: int(statement, 14) != 0,
                usage: .init(total: total)
            )
            sessions.append((metric, sourceUpdatedAt))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw DatabaseReadFailure.query(
                code: sqlite3_extended_errcode(database),
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        return SourceIndexDelta(sessions: sessions, maxRowID: maxRowID, maxUpdatedAt: maxUpdatedAt)
    }

    /// Enriches indexed sessions with token breakdown and turn timing. This may scan large files;
    /// callers should run it off the main actor. Progress is safely persisted every 10 rollouts.
    public func enrichSessions(_ sessions: [SessionMetric]) -> [SessionMetric] {
        enrichSessions(sessions, progress: nil)
    }

    /// Streams completed sessions in newest-first input order so a UI can publish useful
    /// metrics immediately instead of waiting for the entire rollout archive to finish.
    public func enrichmentStream(_ sessions: [SessionMetric]) -> AsyncStream<EnrichmentProgress> {
        AsyncStream { continuation in
            let worker = Task.detached(priority: .utility) { [self] in
                _ = enrichSessions(sessions) { progress in
                    continuation.yield(progress)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    public func enrichmentStream(_ sessions: [SessionSummary]) -> AsyncStream<EnrichmentProgress> {
        let minimal = sessions.map { summary in
            SessionMetric(
                id: summary.id,
                rolloutPath: summary.rolloutPath,
                projectPath: summary.projectPath,
                title: summary.title,
                source: summary.source,
                originator: summary.originator,
                provider: summary.provider,
                createdAt: summary.createdAt,
                updatedAt: summary.updatedAt,
                model: summary.model,
                reasoningEffort: summary.reasoningEffort,
                gitBranch: summary.gitBranch,
                cliVersion: summary.cliVersion,
                archived: summary.archived,
                usage: summary.usage,
                enrichmentAvailable: summary.enrichmentAvailable
            )
        }
        return enrichmentStream(minimal)
    }

    private func enrichSessions(
        _ sessions: [SessionMetric],
        progress: (@Sendable (EnrichmentProgress) -> Void)?
    ) -> [SessionMetric] {
        let cache = RolloutCache(home: userHome)
        var enriched: [SessionMetric] = []
        enriched.reserveCapacity(sessions.count)
        sessionLoop: for (index, session) in sessions.enumerated() {
            if currentTaskIsCancelled { break }
            guard !session.rolloutPath.isEmpty, FileManager.default.fileExists(atPath: session.rolloutPath) else {
                let completedSession = SessionMetric(
                    id: session.id,
                    rolloutPath: session.rolloutPath,
                    projectPath: session.projectPath,
                    title: session.title,
                    source: session.source,
                    originator: session.originator,
                    provider: session.provider,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt,
                    model: session.model,
                    reasoningEffort: session.reasoningEffort,
                    gitBranch: session.gitBranch,
                    cliVersion: session.cliVersion,
                    archived: session.archived,
                    usage: session.usage,
                    usageEvents: session.usageEvents,
                    turns: session.turns,
                    toolCalls: session.toolCalls,
                    toolCallEvents: session.toolCallEvents,
                    skillCallEvents: session.skillCallEvents,
                    userMessages: session.userMessages,
                    abortedTurns: session.abortedTurns,
                    subscription: session.subscription,
                    enrichmentAvailable: true
                )
                enriched.append(completedSession)
                progress?(.init(session: completedSession, completed: index + 1, total: sessions.count))
                continue
            }
            let details: RolloutEnrichment
            switch cache.lookup(session.rolloutPath) {
            case .complete(let cached):
                details = cached
            case .append(let cached, let offset):
                guard let parsed = autoreleasepool(invoking: {
                    RolloutParser.parseIncrementally(
                        path: session.rolloutPath,
                        fromOffset: offset,
                        initial: cached,
                        shouldCancel: { self.currentTaskIsCancelled }
                    )
                }) else { break sessionLoop }
                details = parsed.enrichment
                cache.store(details, for: session.rolloutPath, parsedBytes: parsed.parsedBytes)
            case .miss:
                guard let parsed = autoreleasepool(invoking: {
                    RolloutParser.parseIncrementally(
                        path: session.rolloutPath,
                        shouldCancel: { self.currentTaskIsCancelled }
                    )
                }) else { break sessionLoop }
                details = parsed.enrichment
                cache.store(details, for: session.rolloutPath, parsedBytes: parsed.parsedBytes)
#if canImport(Darwin)
                // Long rollout scans create many short-lived Data buffers. Darwin's
                // allocator otherwise keeps those freed pages resident for the process.
                malloc_zone_pressure_relief(nil, 0)
#endif
            }
            let detailedUsage = details.usage.total > 0 ? details.usage : session.usage
            let enrichedSession = SessionMetric(
                id: session.id,
                rolloutPath: session.rolloutPath,
                projectPath: session.projectPath,
                title: session.title,
                source: session.source,
                originator: details.originator ?? session.originator,
                provider: session.provider,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                model: session.model ?? details.model,
                reasoningEffort: session.reasoningEffort ?? details.reasoningEffort,
                gitBranch: session.gitBranch,
                cliVersion: session.cliVersion,
                archived: session.archived,
                usage: detailedUsage,
                usageEvents: details.usageEvents,
                turns: details.turns,
                toolCalls: details.toolCalls,
                toolCallEvents: details.toolCallEvents,
                skillCallEvents: details.skillCallEvents,
                userMessages: details.userMessages,
                abortedTurns: details.abortedTurns,
                subscription: details.subscription,
                enrichmentAvailable: true
            )
            enriched.append(enrichedSession)
            progress?(.init(session: enrichedSession, completed: index + 1, total: sessions.count))
            if (index + 1).isMultiple(of: 10) { cache.persist() }
        }
        cache.persist()
        return enriched
    }

    private var currentTaskIsCancelled: Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    private func locateDatabases() throws -> [URL] {
        let candidates = [
            codexHome.appendingPathComponent("state_5.sqlite"),
            codexHome.appendingPathComponent("sqlite/state_5.sqlite")
        ]
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            throw CodexStoreError.databaseNotFound
        }
        return existing
    }

    private func tableColumns(_ database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw DatabaseReadFailure.query(
                code: sqlite3_extended_errcode(database),
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if let name = text(statement, 1) { columns.insert(name) }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw DatabaseReadFailure.query(
                code: sqlite3_extended_errcode(database),
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        guard !columns.isEmpty else {
            throw DatabaseReadFailure.query(code: SQLITE_ERROR, message: "threads schema unavailable")
        }
        return columns
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func int(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}

private enum DatabaseReadFailure: Error {
    case open(code: Int32, message: String)
    case query(code: Int32, message: String)

    private var details: (code: Int32, message: String) {
        switch self {
        case .open(let code, let message), .query(let code, let message): (code, message)
        }
    }

    var isTransient: Bool {
        switch details.code & 0xff {
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_CANTOPEN, SQLITE_IOERR, SQLITE_PROTOCOL:
            true
        default:
            false
        }
    }

    var publicError: CodexStoreError {
        switch self {
        case .open(_, let message): .openFailed(message)
        case .query(_, let message): .queryFailed(message)
        }
    }
}

public struct EnrichmentProgress: Sendable {
    public let session: SessionMetric
    public let completed: Int
    public let total: Int

    public init(session: SessionMetric, completed: Int, total: Int) {
        self.session = session
        self.completed = completed
        self.total = total
    }

    public var fractionCompleted: Double {
        total > 0 ? Double(completed) / Double(total) : 1
    }
}
