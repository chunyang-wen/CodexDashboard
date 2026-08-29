import Foundation
import SQLite3

public extension CodexStore {
    /// Loads a bounded, index-only graph for one project. Rollout and history
    /// databases are intentionally outside this path.
    func loadSessionGraph(
        forProjectPaths paths: Set<String>,
        limit: Int = 100
    ) throws -> SessionGraph {
        let requestedLimit = max(1, limit)
        guard !paths.isEmpty else {
            return SessionGraph(
                nodes: [], edges: [], projectNodeCount: 0,
                requestedLimit: requestedLimit, isTruncated: false
            )
        }

        let candidates = [
            codexHome.appendingPathComponent("state_5.sqlite"),
            codexHome.appendingPathComponent("sqlite/state_5.sqlite")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !candidates.isEmpty else { throw CodexStoreError.databaseNotFound }

        var lastError: Error?
        for (candidateIndex, url) in candidates.enumerated() {
            let attempts = candidateIndex == 0 ? 6 : 2
            for attempt in 0..<attempts {
                do {
                    return try SessionGraphIndexReader(databaseURL: url).load(
                        projectPaths: paths,
                        limit: requestedLimit
                    )
                } catch let error as SessionGraphReadError {
                    lastError = error
                    guard error.isTransient, attempt < attempts - 1 else { break }
                    Thread.sleep(forTimeInterval: 0.05 * pow(2, Double(attempt)))
                } catch {
                    lastError = error
                    break
                }
            }
        }
        if let error = lastError as? SessionGraphReadError {
            throw error.publicError
        }
        throw lastError ?? CodexStoreError.openFailed("Unknown error")
    }
}

private final class SessionGraphIndexReader {
    private struct Row {
        let id: String
        let cwd: String?
        let title: String?
        let createdAt: Date?
        let updatedAt: Date?
        let model: String?
        let agentNickname: String?
        let rolloutPath: String?
        let source: String?
    }

    private let database: OpaquePointer

    init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let handle { sqlite3_close(handle) }
            throw SessionGraphReadError.open(code: result, message: message)
        }
        database = handle
        sqlite3_busy_timeout(database, 250)
    }

    deinit { sqlite3_close(database) }

    func load(projectPaths: Set<String>, limit: Int) throws -> SessionGraph {
        try checkCancellation()
        let columns = try tableColumns("threads")
        guard columns.contains("id"), columns.contains("cwd") else {
            throw SessionGraphReadError.query(code: SQLITE_ERROR, message: "threads.id or threads.cwd is unavailable")
        }

        let projectRows = try loadProjectRows(
            paths: projectPaths.map(normalizedPath),
            columns: columns,
            limit: limit + 1
        )
        let isTruncated = projectRows.count > limit
        let boundedRows = Array(projectRows.prefix(limit))
        let projectIDs = Set(boundedRows.map(\.id))
        try checkCancellation()

        let rawEdges = try loadSpawnEdges(connectedTo: projectIDs)
        let externalIDs = Set(rawEdges.flatMap { [$0.sourceID, $0.targetID] }).subtracting(projectIDs)
        let externalRows = try loadRows(ids: externalIDs, columns: columns)
        let externalByID = Dictionary(uniqueKeysWithValues: externalRows.map { ($0.id, $0) })
        let spawnChildIDs = Set(rawEdges.map(\.targetID))

        var nodes = boundedRows.map {
            node(from: $0, scope: .project, spawnChildIDs: spawnChildIDs)
        }
        nodes.append(contentsOf: externalIDs.sorted().map { id in
            if let row = externalByID[id] {
                return node(from: row, scope: .external, spawnChildIDs: spawnChildIDs)
            }
            return SessionGraphNode(
                id: id,
                projectPath: nil,
                title: "External session \(shortID(id))",
                createdAt: nil,
                updatedAt: nil,
                kind: spawnChildIDs.contains(id) ? .subagent : .unknown,
                scope: .external,
                model: nil,
                agentNickname: nil,
                rolloutPath: nil
            )
        })
        nodes.sort { lhs, rhs in
            if lhs.scope != rhs.scope { return lhs.scope == .project }
            let leftDate = lhs.updatedAt ?? .distantPast
            let rightDate = rhs.updatedAt ?? .distantPast
            return leftDate == rightDate ? lhs.id < rhs.id : leftDate > rightDate
        }

        return SessionGraph(
            nodes: nodes,
            edges: rawEdges.sorted { $0.id < $1.id },
            projectNodeCount: boundedRows.count,
            requestedLimit: limit,
            isTruncated: isTruncated
        )
    }

    private func loadProjectRows(paths: [String], columns: Set<String>, limit: Int) throws -> [Row] {
        let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ",")
        let orderColumn = columns.contains("updated_at") ? "updated_at" : "rowid"
        let sql = "SELECT \(selections(columns)) FROM threads WHERE cwd IN (\(placeholders)) ORDER BY \(orderColumn) DESC, rowid DESC LIMIT ?"
        return try queryRows(sql: sql) { statement in
            for (index, path) in paths.sorted().enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), path, -1, Self.transient)
            }
            sqlite3_bind_int64(statement, Int32(paths.count + 1), Int64(limit))
        }
    }

    private func loadRows(ids: Set<String>, columns: Set<String>) throws -> [Row] {
        guard !ids.isEmpty else { return [] }
        let sortedIDs = ids.sorted()
        let placeholders = Array(repeating: "?", count: sortedIDs.count).joined(separator: ",")
        let sql = "SELECT \(selections(columns)) FROM threads WHERE id IN (\(placeholders))"
        return try queryRows(sql: sql) { statement in
            for (index, id) in sortedIDs.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), id, -1, Self.transient)
            }
        }
    }

    private func loadSpawnEdges(connectedTo ids: Set<String>) throws -> [SessionGraphEdge] {
        guard !ids.isEmpty, try tableExists("thread_spawn_edges") else { return [] }
        let columns = try tableColumns("thread_spawn_edges")
        guard columns.contains("parent_thread_id"), columns.contains("child_thread_id") else { return [] }

        let sortedIDs = ids.sorted()
        let placeholders = Array(repeating: "?", count: sortedIDs.count).joined(separator: ",")
        let sql = """
            SELECT parent_thread_id, child_thread_id
            FROM thread_spawn_edges
            WHERE parent_thread_id IN (\(placeholders)) OR child_thread_id IN (\(placeholders))
            """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        guard let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        for offset in [0, sortedIDs.count] {
            for (index, id) in sortedIDs.enumerated() {
                sqlite3_bind_text(statement, Int32(offset + index + 1), id, -1, Self.transient)
            }
        }

        var edges: [SessionGraphEdge] = []
        var seen = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            try checkCancellation()
            guard let parent = text(statement, 0), let child = text(statement, 1) else {
                result = sqlite3_step(statement)
                continue
            }
            let id = "spawn:\(parent):\(child)"
            if seen.insert(id).inserted {
                edges.append(SessionGraphEdge(
                    id: id,
                    sourceID: parent,
                    targetID: child,
                    kind: .spawn,
                    confidence: .explicit
                ))
            }
            result = sqlite3_step(statement)
        }
        try requireDone(result)
        return edges
    }

    private func queryRows(sql: String, bind: (OpaquePointer) -> Void) throws -> [Row] {
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        guard let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement)

        var rows: [Row] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            try checkCancellation()
            guard let id = text(statement, 0) else {
                result = sqlite3_step(statement)
                continue
            }
            rows.append(Row(
                id: id,
                cwd: text(statement, 1),
                title: text(statement, 2),
                createdAt: date(statement, 3),
                updatedAt: date(statement, 4),
                model: text(statement, 5),
                agentNickname: text(statement, 6),
                rolloutPath: text(statement, 7),
                source: text(statement, 8)
            ))
            result = sqlite3_step(statement)
        }
        try requireDone(result)
        return rows
    }

    private func node(
        from row: Row,
        scope: SessionGraphNodeScope,
        spawnChildIDs: Set<String>
    ) -> SessionGraphNode {
        SessionGraphNode(
            id: row.id,
            projectPath: row.cwd,
            title: SessionTitleFormatter.displayTitle(row.title ?? ""),
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            kind: nodeKind(row: row, isSpawnChild: spawnChildIDs.contains(row.id)),
            scope: scope,
            model: row.model,
            agentNickname: row.agentNickname,
            rolloutPath: row.rolloutPath.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private func nodeKind(row: Row, isSpawnChild: Bool) -> SessionGraphNodeKind {
        if isSpawnChild || row.agentNickname != nil { return .subagent }
        let source = row.source?.lowercased() ?? ""
        if source.contains("automation") { return .automation }
        if source.contains("agent_created") { return .agentCreatedThread }
        if source.contains("subagent") || source.contains("thread_spawn") { return .subagent }
        return .user
    }

    private func selections(_ columns: Set<String>) -> String {
        let title: String
        if columns.contains("name"), columns.contains("title") {
            title = "COALESCE(NULLIF(TRIM(name), ''), title) AS title"
        } else if columns.contains("name") {
            title = "NULLIF(TRIM(name), '') AS title"
        } else {
            title = columns.contains("title") ? "title" : "NULL AS title"
        }
        return ["id", "cwd", title, "created_at", "updated_at", "model", "agent_nickname", "rollout_path", "source"]
            .map { $0 == title || columns.contains($0) ? $0 : "NULL AS \($0)" }
            .joined(separator: ", ")
    }

    private func tableExists(_ name: String) throws -> Bool {
        var statement: OpaquePointer?
        try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1", statement: &statement)
        guard let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, Self.transient)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        try requireDone(result)
        return false
    }

    private func tableColumns(_ table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        try prepare("PRAGMA table_info(\(table))", statement: &statement)
        guard let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = text(statement, 1) { columns.insert(name) }
            result = sqlite3_step(statement)
        }
        try requireDone(result)
        return columns
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw SessionGraphReadError.query(code: sqlite3_extended_errcode(database), message: errorMessage)
        }
    }

    private func requireDone(_ result: Int32) throws {
        guard result == SQLITE_DONE else {
            throw SessionGraphReadError.query(code: sqlite3_extended_errcode(database), message: errorMessage)
        }
    }

    private func checkCancellation() throws {
        let cancelled = withUnsafeCurrentTask { $0?.isCancelled ?? false }
        if cancelled { throw CancellationError() }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, index)))
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func shortID(_ id: String) -> String { String(id.prefix(8)) }
    private var errorMessage: String { String(cString: sqlite3_errmsg(database)) }
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}

private enum SessionGraphReadError: Error {
    case open(code: Int32, message: String)
    case query(code: Int32, message: String)

    var isTransient: Bool {
        let code: Int32 = switch self {
        case .open(let code, _), .query(let code, _): code
        }
        return code == SQLITE_BUSY || code == SQLITE_LOCKED || code == SQLITE_PROTOCOL
    }

    var publicError: CodexStoreError {
        switch self {
        case .open(_, let message): .openFailed(message)
        case .query(_, let message): .queryFailed(message)
        }
    }
}
