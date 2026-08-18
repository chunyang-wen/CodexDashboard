import Foundation

public struct TokenUsage: Codable, Hashable, Sendable {
    public var input: Int64
    public var cachedInput: Int64
    public var cacheWriteInput: Int64
    public var output: Int64
    public var reasoningOutput: Int64
    public var total: Int64

    public init(
        input: Int64 = 0,
        cachedInput: Int64 = 0,
        cacheWriteInput: Int64 = 0,
        output: Int64 = 0,
        reasoningOutput: Int64 = 0,
        total: Int64 = 0
    ) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.output = output
        self.reasoningOutput = reasoningOutput
        self.total = total == 0 ? input + output : total
    }

    public static let zero = TokenUsage()
    public var uncachedInput: Int64 { max(0, input - cachedInput - cacheWriteInput) }
    public var cacheHitRate: Double { input > 0 ? Double(cachedInput) / Double(input) : 0 }

    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(
            input: lhs.input + rhs.input,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            cacheWriteInput: lhs.cacheWriteInput + rhs.cacheWriteInput,
            output: lhs.output + rhs.output,
            reasoningOutput: lhs.reasoningOutput + rhs.reasoningOutput,
            total: lhs.total + rhs.total
        )
    }

    public static func - (lhs: Self, rhs: Self) -> Self {
        .init(
            input: max(0, lhs.input - rhs.input),
            cachedInput: max(0, lhs.cachedInput - rhs.cachedInput),
            cacheWriteInput: max(0, lhs.cacheWriteInput - rhs.cacheWriteInput),
            output: max(0, lhs.output - rhs.output),
            reasoningOutput: max(0, lhs.reasoningOutput - rhs.reasoningOutput),
            total: max(0, lhs.total - rhs.total)
        )
    }
}

public struct UsageEvent: Codable, Hashable, Sendable {
    public let date: Date
    public let usage: TokenUsage
    public let model: String?

    public init(date: Date, usage: TokenUsage, model: String? = nil) {
        self.date = date
        self.usage = usage
        self.model = model
    }
}

public struct TurnMetric: Codable, Hashable, Sendable {
    public let completedAt: Date
    public let duration: TimeInterval
    public let timeToFirstToken: TimeInterval?
    public let completed: Bool

    public init(completedAt: Date, duration: TimeInterval, timeToFirstToken: TimeInterval?, completed: Bool) {
        self.completedAt = completedAt
        self.duration = duration
        self.timeToFirstToken = timeToFirstToken
        self.completed = completed
    }
}

public struct ToolCallEvent: Codable, Hashable, Sendable {
    public let date: Date
    public let name: String
    public let model: String?
    public let attributedUsage: TokenUsage

    public init(date: Date, name: String, model: String?, attributedUsage: TokenUsage = .zero) {
        self.date = date
        self.name = name
        self.model = model
        self.attributedUsage = attributedUsage
    }
}

public struct SkillCallEvent: Codable, Hashable, Sendable {
    public let date: Date
    public let name: String
    public let model: String?
    public let attributedUsage: TokenUsage

    public init(date: Date, name: String, model: String?, attributedUsage: TokenUsage = .zero) {
        self.date = date
        self.name = name
        self.model = model
        self.attributedUsage = attributedUsage
    }
}

public struct SessionMetric: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let rolloutPath: String
    public let projectPath: String
    public let title: String
    public let source: String
    /// Human-readable client recorded by the rollout, such as "Codex Desktop".
    /// Optional because the compact Codex thread index and older archives omit it.
    public let originator: String?
    public let provider: String
    public let createdAt: Date
    public let updatedAt: Date
    public let model: String?
    public let reasoningEffort: String?
    public let gitBranch: String?
    public let cliVersion: String?
    public let archived: Bool
    public let usage: TokenUsage
    public let usageEvents: [UsageEvent]
    public let turns: [TurnMetric]
    public let toolCalls: Int
    /// Optional so historical archives written before tool-level metrics remain decodable.
    public let toolCallEvents: [ToolCallEvent]?
    /// Skill activations inferred from explicit reads of a skill's SKILL.md.
    public let skillCallEvents: [SkillCallEvent]?
    public let userMessages: Int
    public let abortedTurns: Int
    public let enrichmentAvailable: Bool

    public init(
        id: String,
        rolloutPath: String,
        projectPath: String,
        title: String,
        source: String,
        originator: String? = nil,
        provider: String,
        createdAt: Date,
        updatedAt: Date,
        model: String?,
        reasoningEffort: String?,
        gitBranch: String?,
        cliVersion: String?,
        archived: Bool,
        usage: TokenUsage,
        usageEvents: [UsageEvent] = [],
        turns: [TurnMetric] = [],
        toolCalls: Int = 0,
        toolCallEvents: [ToolCallEvent]? = [],
        skillCallEvents: [SkillCallEvent]? = [],
        userMessages: Int = 0,
        abortedTurns: Int = 0,
        enrichmentAvailable: Bool = false
    ) {
        self.id = id
        self.rolloutPath = rolloutPath
        self.projectPath = projectPath
        self.title = title
        self.source = source
        self.originator = originator
        self.provider = provider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.gitBranch = gitBranch
        self.cliVersion = cliVersion
        self.archived = archived
        self.usage = usage
        self.usageEvents = usageEvents
        self.turns = turns
        self.toolCalls = toolCalls
        self.toolCallEvents = toolCallEvents
        self.skillCallEvents = skillCallEvents
        self.userMessages = userMessages
        self.abortedTurns = abortedTurns
        self.enrichmentAvailable = enrichmentAvailable
    }

    public var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent.isEmpty ? projectPath : URL(fileURLWithPath: projectPath).lastPathComponent
    }
    public var displayTitle: String { title.isEmpty ? "Untitled session" : title }
    public var displaySource: String { originator ?? source }
    public var sessionSpan: TimeInterval { max(0, updatedAt.timeIntervalSince(createdAt)) }
    public var activeRuntime: TimeInterval { turns.reduce(0) { $0 + $1.duration } }
    public var completedTurns: Int { turns.filter(\.completed).count }
    public var averageTTFT: TimeInterval? {
        let values = turns.compactMap(\.timeToFirstToken)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

public struct ProjectMetric: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let sessions: [SessionMetric]

    public init(path: String, sessions: [SessionMetric]) {
        self.path = path
        self.sessions = sessions
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var usage: TokenUsage { sessions.reduce(.zero) { $0 + $1.usage } }
    public var activeRuntime: TimeInterval { sessions.reduce(0) { $0 + $1.activeRuntime } }
    public var sessionCount: Int { sessions.count }
    public var lastActivity: Date { sessions.map(\.updatedAt).max() ?? .distantPast }
    public var activeDays: Int { Set(sessions.map { Calendar.current.startOfDay(for: $0.updatedAt) }).count }
    public var dominantModel: String? {
        Dictionary(grouping: sessions.compactMap(\.model), by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
}

public struct PeriodMetric: Identifiable, Hashable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let usage: TokenUsage
    public let sessions: Int
    public let activeRuntime: TimeInterval
    public let estimatedCost: Decimal
}

public struct ModelMetric: Identifiable, Hashable, Sendable {
    public var id: String { model }
    public let model: String
    public let sessions: Int
    public let usage: TokenUsage
    public let activeRuntime: TimeInterval
    public let estimatedCost: Decimal
}

public struct ToolMetric: Identifiable, Hashable, Sendable {
    public var id: String { tool }
    public let tool: String
    public let calls: Int
    public let attributedCalls: Int
    public let sessions: Int
    public let attributedUsage: TokenUsage
    public let estimatedCost: Decimal

    public init(
        tool: String,
        calls: Int,
        attributedCalls: Int,
        sessions: Int,
        attributedUsage: TokenUsage,
        estimatedCost: Decimal
    ) {
        self.tool = tool
        self.calls = calls
        self.attributedCalls = attributedCalls
        self.sessions = sessions
        self.attributedUsage = attributedUsage
        self.estimatedCost = estimatedCost
    }
}

public struct SkillMetric: Identifiable, Hashable, Sendable {
    public var id: String { skill }
    public let skill: String
    public let calls: Int
    public let attributedCalls: Int
    public let sessions: Int
    public let attributedUsage: TokenUsage
    public let estimatedCost: Decimal

    public init(
        skill: String,
        calls: Int,
        attributedCalls: Int,
        sessions: Int,
        attributedUsage: TokenUsage,
        estimatedCost: Decimal
    ) {
        self.skill = skill
        self.calls = calls
        self.attributedCalls = attributedCalls
        self.sessions = sessions
        self.attributedUsage = attributedUsage
        self.estimatedCost = estimatedCost
    }
}
