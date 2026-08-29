@testable import CodexMetricsCore
import Foundation
import XCTest

final class SessionGraphLayoutTests: XCTestCase {
    func testPlacesSpawnDescendantsAtIncreasingDepth() {
        let graph = makeGraph(
            ids: ["root", "child", "grandchild"],
            edges: [("root", "child"), ("child", "grandchild")]
        )

        let layout = SessionGraphLayout.make(graph: graph)

        XCTAssertLessThan(layout.nodeFrames["root"]!.minX, layout.nodeFrames["child"]!.minX)
        XCTAssertLessThan(layout.nodeFrames["child"]!.minX, layout.nodeFrames["grandchild"]!.minX)
        XCTAssertTrue(layout.unlinkedNodeIDs.isEmpty)
    }

    func testSiblingOrderUsesCreationTimeThenID() {
        let graph = SessionGraph(
            nodes: [
                node("root", createdAt: 1),
                node("later", createdAt: 3),
                node("a", createdAt: 2),
                node("b", createdAt: 2)
            ],
            edges: [edge("root", "later"), edge("root", "b"), edge("root", "a")],
            projectNodeCount: 4,
            requestedLimit: 100,
            isTruncated: false
        )

        let layout = SessionGraphLayout.make(graph: graph)

        XCTAssertLessThan(layout.nodeFrames["a"]!.minY, layout.nodeFrames["b"]!.minY)
        XCTAssertLessThan(layout.nodeFrames["b"]!.minY, layout.nodeFrames["later"]!.minY)
    }

    func testUnlinkedNodesUseSeparateLane() {
        let graph = makeGraph(ids: ["root", "child", "unlinked"], edges: [("root", "child")])

        let layout = SessionGraphLayout.make(graph: graph)

        XCTAssertEqual(layout.unlinkedNodeIDs, ["unlinked"])
        XCTAssertGreaterThan(layout.nodeFrames["unlinked"]!.minY, layout.nodeFrames["child"]!.maxY)
        XCTAssertEqual(layout.unlinkedOriginY, layout.nodeFrames["unlinked"]!.minY)
    }

    func testCycleBreakKeepsEveryNodeAndReportsExcludedEdge() {
        let graph = makeGraph(ids: ["a", "b", "c"], edges: [("a", "b"), ("b", "c"), ("c", "a")])

        let first = SessionGraphLayout.make(graph: graph)
        let second = SessionGraphLayout.make(graph: graph)

        XCTAssertEqual(first.nodeFrames, second.nodeFrames)
        XCTAssertEqual(first.excludedEdgeIDs, second.excludedEdgeIDs)
        XCTAssertEqual(Set(first.nodeFrames.keys), ["a", "b", "c"])
        XCTAssertEqual(first.excludedEdgeIDs.count, 1)
        XCTAssertTrue(first.unlinkedNodeIDs.isEmpty)
    }

    func testWideFanOutWrapsAcrossBoundedHeightColumns() {
        let childIDs = (0..<20).map { "child-\($0)" }
        let graph = makeGraph(
            ids: ["root"] + childIDs,
            edges: childIDs.map { ("root", $0) }
        )
        let configuration = SessionGraphLayoutConfiguration(maximumNodesPerColumn: 6)

        let layout = SessionGraphLayout.make(graph: graph, configuration: configuration)
        let childFrames = childIDs.compactMap { layout.nodeFrames[$0] }

        XCTAssertEqual(Set(childFrames.map(\.minX)).count, 4)
        XCTAssertLessThanOrEqual(Set(childFrames.map(\.minY)).count, 6)
    }

    private func makeGraph(ids: [String], edges: [(String, String)]) -> SessionGraph {
        SessionGraph(
            nodes: ids.enumerated().map { node($0.element, createdAt: TimeInterval($0.offset)) },
            edges: edges.map { edge($0.0, $0.1) },
            projectNodeCount: ids.count,
            requestedLimit: 100,
            isTruncated: false
        )
    }

    private func node(_ id: String, createdAt: TimeInterval) -> SessionGraphNode {
        SessionGraphNode(
            id: id,
            projectPath: "/project",
            title: id,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: createdAt),
            kind: .user,
            scope: .project,
            model: nil,
            agentNickname: nil,
            rolloutPath: nil
        )
    }

    private func edge(_ source: String, _ target: String) -> SessionGraphEdge {
        SessionGraphEdge(
            id: "spawn:\(source):\(target)",
            sourceID: source,
            targetID: target,
            kind: .spawn,
            confidence: .explicit
        )
    }
}
