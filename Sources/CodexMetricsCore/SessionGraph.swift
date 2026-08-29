import Foundation

public struct SessionGraph: Sendable, Equatable {
    public let nodes: [SessionGraphNode]
    public let edges: [SessionGraphEdge]
    public let projectNodeCount: Int
    public let requestedLimit: Int
    public let isTruncated: Bool

    public init(
        nodes: [SessionGraphNode],
        edges: [SessionGraphEdge],
        projectNodeCount: Int,
        requestedLimit: Int,
        isTruncated: Bool
    ) {
        self.nodes = nodes
        self.edges = edges
        self.projectNodeCount = projectNodeCount
        self.requestedLimit = requestedLimit
        self.isTruncated = isTruncated
    }

    public static let empty = SessionGraph(
        nodes: [],
        edges: [],
        projectNodeCount: 0,
        requestedLimit: 0,
        isTruncated: false
    )
}

public struct SessionGraphPresentation: Sendable, Equatable {
    public let workflows: [SessionGraphWorkflow]
    public let standaloneNodes: [SessionGraphNode]

    public init(graph: SessionGraph, maximumVisibleNodesPerWorkflow: Int = 40) {
        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let validEdges = graph.edges.filter {
            nodesByID[$0.sourceID] != nil && nodesByID[$0.targetID] != nil
        }
        let incidentIDs = Set(validEdges.flatMap { [$0.sourceID, $0.targetID] })
        standaloneNodes = graph.nodes.filter { !incidentIDs.contains($0.id) }.sorted(by: Self.nodeOrder)

        var adjacency: [String: Set<String>] = [:]
        for edge in validEdges {
            adjacency[edge.sourceID, default: []].insert(edge.targetID)
            adjacency[edge.targetID, default: []].insert(edge.sourceID)
        }

        var remaining = incidentIDs
        var components: [SessionGraphWorkflow] = []
        while let start = remaining.sorted().first {
            var queue = [start]
            var componentIDs = Set<String>()
            while !queue.isEmpty {
                let id = queue.removeFirst()
                guard componentIDs.insert(id).inserted else { continue }
                remaining.remove(id)
                queue.append(contentsOf: adjacency[id, default: []].filter { !componentIDs.contains($0) }.sorted())
            }
            let nodes = componentIDs.compactMap { nodesByID[$0] }
            let edges = validEdges.filter {
                componentIDs.contains($0.sourceID) && componentIDs.contains($0.targetID)
            }
            components.append(SessionGraphWorkflow(
                nodes: nodes,
                edges: edges,
                sourceGraphIsTruncated: graph.isTruncated,
                maximumVisibleNodes: maximumVisibleNodesPerWorkflow
            ))
        }
        workflows = components.sorted {
            if $0.latestActivity != $1.latestActivity { return $0.latestActivity > $1.latestActivity }
            return $0.id < $1.id
        }
    }

    private static func nodeOrder(_ lhs: SessionGraphNode, _ rhs: SessionGraphNode) -> Bool {
        let left = lhs.updatedAt ?? .distantPast
        let right = rhs.updatedAt ?? .distantPast
        return left == right ? lhs.id < rhs.id : left > right
    }
}

public struct SessionGraphWorkflow: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let nodeCount: Int
    public let hiddenNodeCount: Int
    public let latestActivity: Date
    public let graph: SessionGraph

    fileprivate init(
        nodes: [SessionGraphNode],
        edges: [SessionGraphEdge],
        sourceGraphIsTruncated: Bool,
        maximumVisibleNodes: Int
    ) {
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let incomingIDs = Set(edges.map(\.targetID))
        let roots = nodes.filter { !incomingIDs.contains($0.id) }.sorted(by: Self.nodeOrder)
        let titleNode = roots.first ?? nodes.sorted(by: Self.nodeOrder).first!
        let limit = max(1, maximumVisibleNodes)

        var adjacency: [String: Set<String>] = [:]
        for edge in edges {
            adjacency[edge.sourceID, default: []].insert(edge.targetID)
            adjacency[edge.targetID, default: []].insert(edge.sourceID)
        }
        var queue = roots.map(\.id)
        if queue.isEmpty { queue = [titleNode.id] }
        var orderedIDs: [String] = []
        var visited = Set<String>()
        while !queue.isEmpty, orderedIDs.count < limit {
            let id = queue.removeFirst()
            guard visited.insert(id).inserted else { continue }
            orderedIDs.append(id)
            let neighbors = adjacency[id, default: []].compactMap { nodesByID[$0] }.sorted(by: Self.nodeOrder)
            queue.append(contentsOf: neighbors.map(\.id).filter { !visited.contains($0) })
        }
        if orderedIDs.count < min(limit, nodes.count) {
            orderedIDs.append(contentsOf: nodes.sorted(by: Self.nodeOrder).map(\.id).filter { !visited.contains($0) }.prefix(limit - orderedIDs.count))
        }

        let visibleIDs = Set(orderedIDs)
        let visibleNodes = orderedIDs.compactMap { nodesByID[$0] }
        let visibleEdges = edges.filter {
            visibleIDs.contains($0.sourceID) && visibleIDs.contains($0.targetID)
        }
        id = nodes.map(\.id).min() ?? titleNode.id
        title = titleNode.title
        nodeCount = nodes.count
        hiddenNodeCount = max(0, nodes.count - visibleNodes.count)
        latestActivity = nodes.compactMap(\.updatedAt).max() ?? .distantPast
        graph = SessionGraph(
            nodes: visibleNodes,
            edges: visibleEdges,
            projectNodeCount: visibleNodes.filter { $0.scope == .project }.count,
            requestedLimit: limit,
            isTruncated: sourceGraphIsTruncated || hiddenNodeCount > 0
        )
    }

    private static func nodeOrder(_ lhs: SessionGraphNode, _ rhs: SessionGraphNode) -> Bool {
        let left = lhs.updatedAt ?? .distantPast
        let right = rhs.updatedAt ?? .distantPast
        return left == right ? lhs.id < rhs.id : left > right
    }
}

public struct SessionGraphNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let projectPath: String?
    public let title: String
    public let createdAt: Date?
    public let updatedAt: Date?
    public let kind: SessionGraphNodeKind
    public let scope: SessionGraphNodeScope
    public let status: SessionGraphStatus
    public let model: String?
    public let agentNickname: String?
    public let rolloutPath: String?

    public init(
        id: String,
        projectPath: String?,
        title: String,
        createdAt: Date?,
        updatedAt: Date?,
        kind: SessionGraphNodeKind,
        scope: SessionGraphNodeScope,
        status: SessionGraphStatus = .unknown,
        model: String?,
        agentNickname: String?,
        rolloutPath: String?
    ) {
        self.id = id
        self.projectPath = projectPath
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.kind = kind
        self.scope = scope
        self.status = status
        self.model = model
        self.agentNickname = agentNickname
        self.rolloutPath = rolloutPath
    }
}

public struct SessionGraphEdge: Identifiable, Sendable, Equatable {
    public let id: String
    public let sourceID: String
    public let targetID: String
    public let kind: SessionGraphEdgeKind
    public let confidence: SessionGraphConfidence

    public init(
        id: String,
        sourceID: String,
        targetID: String,
        kind: SessionGraphEdgeKind,
        confidence: SessionGraphConfidence
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.confidence = confidence
    }
}

public enum SessionGraphNodeKind: Sendable, Equatable {
    case user
    case subagent
    case automation
    case agentCreatedThread
    case unknown
}

public enum SessionGraphNodeScope: Sendable, Equatable {
    case project
    case external
}

public enum SessionGraphStatus: Sendable, Equatable {
    case unknown
    case recentlyActive
    case completed
    case interrupted
    case failed
    case running
    case waiting
}

public enum SessionGraphEdgeKind: Sendable, Equatable {
    case spawn
    case fork
    case communication
}

public enum SessionGraphConfidence: Sendable, Equatable {
    case explicit
    case metadata
    case inferred
}
