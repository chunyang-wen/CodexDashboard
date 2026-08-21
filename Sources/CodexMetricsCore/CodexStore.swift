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
    public func loadIndexedSessions() throws -> [SessionMetric] {
        let databaseURLs = try locateDatabases()
        var lastFailure: DatabaseReadFailure?
        for (candidateIndex, databaseURL) in databaseURLs.enumerated() {
            let attemptCount = candidateIndex == 0 ? 6 : 2
            for attempt in 0..<attemptCount {
                do {
                    return try readIndexedSessions(from: databaseURL)
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

    private func readIndexedSessions(from databaseURL: URL) throws -> [SessionMetric] {
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
        let sql = "SELECT \(selections) FROM threads ORDER BY updated_at DESC"
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw DatabaseReadFailure.query(
                code: sqlite3_extended_errcode(database),
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [SessionMetric] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            let total = int(statement, 8)
            sessions.append(SessionMetric(
                id: text(statement, 0) ?? UUID().uuidString,
                rolloutPath: text(statement, 1) ?? "",
                projectPath: normalizedPath(text(statement, 2) ?? "Unknown"),
                title: text(statement, 3) ?? "",
                source: text(statement, 4) ?? "unknown",
                provider: text(statement, 5) ?? "unknown",
                createdAt: Date(timeIntervalSince1970: Double(int(statement, 6))),
                updatedAt: Date(timeIntervalSince1970: Double(int(statement, 7))),
                model: text(statement, 9),
                reasoningEffort: text(statement, 10),
                gitBranch: text(statement, 11),
                cliVersion: text(statement, 12),
                archived: int(statement, 13) != 0,
                usage: .init(total: total)
            ))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw DatabaseReadFailure.query(
                code: sqlite3_extended_errcode(database),
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        return sessions
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
                enriched.append(session)
                progress?(.init(session: session, completed: index + 1, total: sessions.count))
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
