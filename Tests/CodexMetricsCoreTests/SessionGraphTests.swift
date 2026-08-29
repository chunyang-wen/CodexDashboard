@testable import CodexMetricsCore
import Foundation
import SQLite3
import XCTest

final class SessionGraphTests: XCTestCase {
    func testPresentationSeparatesWorkflowsFromStandaloneAndBoundsDenseWorkflow() {
        let root = graphNode("root", updatedAt: 100)
        let children = (0..<45).map { graphNode("child-\($0)", updatedAt: TimeInterval($0)) }
        let standalone = graphNode("standalone", updatedAt: 200)
        let graph = SessionGraph(
            nodes: [root, standalone] + children,
            edges: children.map {
                SessionGraphEdge(
                    id: "spawn:root:\($0.id)", sourceID: "root", targetID: $0.id,
                    kind: .spawn, confidence: .explicit
                )
            },
            projectNodeCount: 47,
            requestedLimit: 100,
            isTruncated: false
        )

        let presentation = SessionGraphPresentation(graph: graph, maximumVisibleNodesPerWorkflow: 20)

        XCTAssertEqual(presentation.workflows.count, 1)
        XCTAssertEqual(presentation.standaloneNodes.map(\.id), ["standalone"])
        XCTAssertEqual(presentation.workflows[0].nodeCount, 46)
        XCTAssertEqual(presentation.workflows[0].graph.nodes.count, 20)
        XCTAssertEqual(presentation.workflows[0].hiddenNodeCount, 26)
        XCTAssertEqual(presentation.workflows[0].title, "root")
    }

    func testLoadsBoundedProjectGraphAndOneHopExternalEndpoint() throws {
        let fixture = try GraphDatabaseFixture()
        defer { fixture.remove() }
        try fixture.execute("""
            CREATE TABLE threads (
                id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT, title TEXT,
                source TEXT, created_at INTEGER, updated_at INTEGER, model TEXT,
                agent_nickname TEXT
            );
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT NOT NULL PRIMARY KEY,
                status TEXT NOT NULL
            );
            INSERT INTO threads VALUES
                ('root', '/tmp/root.jsonl', '/project', 'Root', 'cli', 10, 30, 'gpt-root', NULL),
                ('child', '/tmp/child.jsonl', '/project', 'Child', 'subagent', 20, 40, 'gpt-child', 'worker'),
                ('older', '/tmp/older.jsonl', '/project', 'Older', 'cli', 5, 10, NULL, NULL),
                ('external', '/tmp/external.jsonl', '/worktree', 'External', 'subagent', 25, 50, NULL, 'outside'),
                ('unrelated', '/tmp/unrelated.jsonl', '/other', 'Unrelated', 'cli', 30, 60, NULL, NULL);
            INSERT INTO thread_spawn_edges VALUES
                ('root', 'child', 'closed'),
                ('child', 'external', 'closed'),
                ('external', 'unrelated', 'closed');
            """)

        let graph = try fixture.store.loadSessionGraph(forProjectPaths: ["/project"], limit: 2)

        XCTAssertEqual(graph.projectNodeCount, 2)
        XCTAssertTrue(graph.isTruncated)
        XCTAssertEqual(Set(graph.nodes.map(\.id)), ["root", "child", "external"])
        XCTAssertEqual(Set(graph.edges.map(\.id)), ["spawn:root:child", "spawn:child:external"])
        XCTAssertEqual(graph.nodes.first { $0.id == "external" }?.scope, .external)
        XCTAssertEqual(graph.nodes.first { $0.id == "child" }?.kind, .subagent)
        XCTAssertFalse(graph.nodes.contains { $0.id == "unrelated" })
    }

    func testMissingExternalRowBecomesPlaceholder() throws {
        let fixture = try GraphDatabaseFixture()
        defer { fixture.remove() }
        try fixture.execute("""
            CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, updated_at INTEGER);
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT NOT NULL PRIMARY KEY,
                status TEXT NOT NULL
            );
            INSERT INTO threads VALUES ('root', '/project', 10);
            INSERT INTO thread_spawn_edges VALUES ('root', 'missing-child', 'open');
            """)

        let graph = try fixture.store.loadSessionGraph(forProjectPaths: ["/project"])
        let placeholder = try XCTUnwrap(graph.nodes.first { $0.id == "missing-child" })

        XCTAssertEqual(placeholder.scope, .external)
        XCTAssertEqual(placeholder.kind, .subagent)
        XCTAssertNil(placeholder.updatedAt)
        XCTAssertNil(placeholder.rolloutPath)
    }

    func testGraphPrefersCanonicalThreadNameOverRawTitle() throws {
        let fixture = try GraphDatabaseFixture()
        defer { fixture.remove() }
        try fixture.execute("""
            CREATE TABLE threads (
                id TEXT PRIMARY KEY, cwd TEXT, title TEXT, name TEXT, updated_at INTEGER
            );
            INSERT INTO threads VALUES (
                'named', '/project', 'Raw request with attachment metadata',
                'Fix project overview visibility', 10
            );
            """)

        let graph = try fixture.store.loadSessionGraph(forProjectPaths: ["/project"])

        XCTAssertEqual(graph.nodes.first?.title, "Fix project overview visibility")
    }

    func testLegacyThreadsTableWithoutEdgeTableStillLoads() throws {
        let fixture = try GraphDatabaseFixture()
        defer { fixture.remove() }
        try fixture.execute("""
            CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, updated_at INTEGER);
            INSERT INTO threads VALUES ('legacy', '/project', 10);
            """)

        let graph = try fixture.store.loadSessionGraph(forProjectPaths: ["/project"])

        XCTAssertEqual(graph.nodes.map(\.id), ["legacy"])
        XCTAssertTrue(graph.edges.isEmpty)
        XCTAssertEqual(graph.nodes[0].title, "Untitled session")
        XCTAssertEqual(graph.nodes[0].status, .unknown)
    }

    func testEmptyProjectPathsDoesNotOpenDatabase() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let graph = try CodexStore(codexHome: home, userHome: home)
            .loadSessionGraph(forProjectPaths: [])

        XCTAssertTrue(graph.nodes.isEmpty)
        XCTAssertEqual(graph.requestedLimit, 100)
    }

    private func graphNode(_ id: String, updatedAt: TimeInterval) -> SessionGraphNode {
        SessionGraphNode(
            id: id, projectPath: "/project", title: id,
            createdAt: Date(timeIntervalSince1970: updatedAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            kind: .user, scope: .project, model: nil, agentNickname: nil, rolloutPath: nil
        )
    }
}

private final class GraphDatabaseFixture {
    let root: URL
    let codexHome: URL
    let store: CodexStore
    private var database: OpaquePointer?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw NSError(domain: "SessionGraphTests", code: 1)
        }
        store = CodexStore(codexHome: codexHome, userHome: root)
    }

    deinit { if let database { sqlite3_close(database) } }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "SessionGraphTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"]
            )
        }
    }

    func remove() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        try? FileManager.default.removeItem(at: root)
    }
}
