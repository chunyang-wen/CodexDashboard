import Foundation
import CoreGraphics

public struct SessionGraphLayoutConfiguration: Sendable {
    public let nodeSize: CGSize
    public let horizontalSpacing: CGFloat
    public let verticalSpacing: CGFloat
    public let sectionSpacing: CGFloat
    public let margin: CGFloat
    public let maximumUnlinkedColumns: Int
    public let maximumNodesPerColumn: Int

    public init(
        nodeSize: CGSize = CGSize(width: 220, height: 72),
        horizontalSpacing: CGFloat = 72,
        verticalSpacing: CGFloat = 24,
        sectionSpacing: CGFloat = 72,
        margin: CGFloat = 40,
        maximumUnlinkedColumns: Int = 4,
        maximumNodesPerColumn: Int = 8
    ) {
        self.nodeSize = nodeSize
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.sectionSpacing = sectionSpacing
        self.margin = margin
        self.maximumUnlinkedColumns = max(1, maximumUnlinkedColumns)
        self.maximumNodesPerColumn = max(1, maximumNodesPerColumn)
    }

    public static let standard = SessionGraphLayoutConfiguration()
}

public struct SessionGraphLayoutResult: Sendable {
    public let nodeFrames: [String: CGRect]
    public let linkedNodeIDs: [String]
    public let unlinkedNodeIDs: [String]
    public let excludedEdgeIDs: Set<String>
    public let bounds: CGRect
    public let unlinkedOriginY: CGFloat?

    public init(
        nodeFrames: [String: CGRect],
        linkedNodeIDs: [String],
        unlinkedNodeIDs: [String],
        excludedEdgeIDs: Set<String>,
        bounds: CGRect,
        unlinkedOriginY: CGFloat?
    ) {
        self.nodeFrames = nodeFrames
        self.linkedNodeIDs = linkedNodeIDs
        self.unlinkedNodeIDs = unlinkedNodeIDs
        self.excludedEdgeIDs = excludedEdgeIDs
        self.bounds = bounds
        self.unlinkedOriginY = unlinkedOriginY
    }

    public static let empty = SessionGraphLayoutResult(
        nodeFrames: [:], linkedNodeIDs: [], unlinkedNodeIDs: [],
        excludedEdgeIDs: [], bounds: .zero, unlinkedOriginY: nil
    )
}

public enum SessionGraphLayout {
    public static func make(
        graph: SessionGraph,
        configuration: SessionGraphLayoutConfiguration = .standard
    ) -> SessionGraphLayoutResult {
        guard !graph.nodes.isEmpty else { return .empty }

        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let spawnEdges = graph.edges.filter {
            $0.kind == .spawn && nodesByID[$0.sourceID] != nil && nodesByID[$0.targetID] != nil
        }
        let incidentIDs = Set(spawnEdges.flatMap { [$0.sourceID, $0.targetID] })
        let linkedIDs = Set(nodesByID.keys).intersection(incidentIDs)
        let unlinkedNodes = graph.nodes.filter { !linkedIDs.contains($0.id) }.sorted(by: nodeOrder)

        var outgoing: [String: [SessionGraphEdge]] = [:]
        var incoming: [String: [SessionGraphEdge]] = [:]
        var indegree = Dictionary(uniqueKeysWithValues: linkedIDs.map { ($0, 0) })
        for edge in spawnEdges {
            outgoing[edge.sourceID, default: []].append(edge)
            incoming[edge.targetID, default: []].append(edge)
            indegree[edge.targetID, default: 0] += 1
        }
        for id in outgoing.keys { outgoing[id]?.sort { $0.id < $1.id } }

        var queue = Array(linkedIDs.filter { indegree[$0, default: 0] == 0 })
        sortIDs(&queue, nodesByID: nodesByID)
        var remaining = linkedIDs
        var ordered: [String] = []
        var depths = Dictionary(uniqueKeysWithValues: linkedIDs.map { ($0, 0) })
        var excludedEdgeIDs = Set<String>()

        while !remaining.isEmpty {
            if queue.isEmpty {
                let breakID = remaining.sorted { idOrder($0, $1, nodesByID: nodesByID) }.first!
                for edge in incoming[breakID, default: []] where remaining.contains(edge.sourceID) {
                    excludedEdgeIDs.insert(edge.id)
                    indegree[breakID, default: 0] -= 1
                }
                indegree[breakID] = 0
                queue.append(breakID)
            }

            let id = queue.removeFirst()
            guard remaining.remove(id) != nil else { continue }
            ordered.append(id)
            for edge in outgoing[id, default: []] where !excludedEdgeIDs.contains(edge.id) {
                guard remaining.contains(edge.targetID) else { continue }
                depths[edge.targetID] = max(depths[edge.targetID, default: 0], depths[id, default: 0] + 1)
                indegree[edge.targetID, default: 0] -= 1
                if indegree[edge.targetID] == 0 { queue.append(edge.targetID) }
            }
            sortIDs(&queue, nodesByID: nodesByID)
        }

        let linkedNodes = ordered.compactMap { nodesByID[$0] }
        let layers = Dictionary(grouping: linkedNodes) { depths[$0.id, default: 0] }
        let sortedDepths = layers.keys.sorted()
        var frames: [String: CGRect] = [:]
        var maximumY = configuration.margin
        var maximumX = configuration.margin

        var visualColumn = 0
        for depth in sortedDepths {
            let nodes = layers[depth, default: []].sorted(by: nodeOrder)
            let columnsAtDepth = max(1, Int(ceil(Double(nodes.count) / Double(configuration.maximumNodesPerColumn))))
            for (index, node) in nodes.enumerated() {
                let wrappedColumn = index / configuration.maximumNodesPerColumn
                let row = index % configuration.maximumNodesPerColumn
                let x = configuration.margin + CGFloat(visualColumn + wrappedColumn) * (configuration.nodeSize.width + configuration.horizontalSpacing)
                let y = configuration.margin + CGFloat(row) * (configuration.nodeSize.height + configuration.verticalSpacing)
                let frame = CGRect(origin: CGPoint(x: x, y: y), size: configuration.nodeSize)
                frames[node.id] = frame
                maximumX = max(maximumX, frame.maxX)
                maximumY = max(maximumY, frame.maxY)
            }
            visualColumn += columnsAtDepth
        }

        let unlinkedOriginY: CGFloat?
        if unlinkedNodes.isEmpty {
            unlinkedOriginY = nil
        } else {
            let originY = linkedNodes.isEmpty ? configuration.margin : maximumY + configuration.sectionSpacing
            unlinkedOriginY = originY
            let linkedColumnCount = max(1, (sortedDepths.max() ?? 0) + 1)
            let columns = min(configuration.maximumUnlinkedColumns, linkedColumnCount)
            for (index, node) in unlinkedNodes.enumerated() {
                let column = index % columns
                let row = index / columns
                let x = configuration.margin + CGFloat(column) * (configuration.nodeSize.width + configuration.horizontalSpacing)
                let y = originY + CGFloat(row) * (configuration.nodeSize.height + configuration.verticalSpacing)
                let frame = CGRect(origin: CGPoint(x: x, y: y), size: configuration.nodeSize)
                frames[node.id] = frame
                maximumX = max(maximumX, frame.maxX)
                maximumY = max(maximumY, frame.maxY)
            }
        }

        let bounds = CGRect(
            origin: .zero,
            size: CGSize(width: maximumX + configuration.margin, height: maximumY + configuration.margin)
        )
        return SessionGraphLayoutResult(
            nodeFrames: frames,
            linkedNodeIDs: linkedNodes.map(\.id),
            unlinkedNodeIDs: unlinkedNodes.map(\.id),
            excludedEdgeIDs: excludedEdgeIDs,
            bounds: bounds,
            unlinkedOriginY: unlinkedOriginY
        )
    }

    private static func sortIDs(_ ids: inout [String], nodesByID: [String: SessionGraphNode]) {
        ids.sort { idOrder($0, $1, nodesByID: nodesByID) }
    }

    private static func idOrder(
        _ lhs: String,
        _ rhs: String,
        nodesByID: [String: SessionGraphNode]
    ) -> Bool {
        guard let left = nodesByID[lhs], let right = nodesByID[rhs] else { return lhs < rhs }
        return nodeOrder(left, right)
    }

    private static func nodeOrder(_ lhs: SessionGraphNode, _ rhs: SessionGraphNode) -> Bool {
        let leftDate = lhs.createdAt ?? .distantPast
        let rightDate = rhs.createdAt ?? .distantPast
        return leftDate == rightDate ? lhs.id < rhs.id : leftDate < rightDate
    }
}
