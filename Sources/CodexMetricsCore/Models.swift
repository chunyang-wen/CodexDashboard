import Foundation
#if canImport(Darwin)
import Darwin
#endif
import os

/// Opt-in process memory tracing for diagnosing first-open and tab-switch peaks.
/// Enable with `defaults write com.chunyangwen.CodexDashboard.shared CodexDashboard.MemoryTrace -bool YES`
/// or by setting `CODEX_DASHBOARD_MEMORY_TRACE=1` before launching the binary.
public enum CodexMemoryTrace {
    private static let key = "CodexDashboard.MemoryTrace"
    private static let logger = Logger(subsystem: "com.chunyangwen.CodexDashboard", category: "memory")
    private static let enabled = ProcessInfo.processInfo.environment["CODEX_DASHBOARD_MEMORY_TRACE"] == "1"
        || UserDefaults.standard.bool(forKey: key)
        || UserDefaults(suiteName: "com.chunyangwen.CodexDashboard.shared")?.bool(forKey: key) == true

    public static func mark(_ stage: String, details: String = "") {
        guard enabled else { return }
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            logger.notice("stage=\(stage, privacy: .public) memory=unavailable details=\(details, privacy: .public)")
            return
        }
        let current = Double(info.phys_footprint) / 1_048_576
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        let peak = usageResult == 0 ? Double(usage.ri_lifetime_max_phys_footprint) / 1_048_576 : current
        let resident = Double(info.resident_size) / 1_048_576
        logger.notice(
            "stage=\(stage, privacy: .public) physical=\(current, format: .fixed(precision: 1))MB peak=\(peak, format: .fixed(precision: 1))MB resident=\(resident, format: .fixed(precision: 1))MB details=\(details, privacy: .public)"
        )
        #else
        logger.notice("stage=\(stage, privacy: .public) memory=unsupported details=\(details, privacy: .public)")
        #endif
    }
}

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
    /// Most recent quota snapshot observed while incrementally parsing this rollout.
    /// Optional so existing archives and parser checkpoints remain decodable.
    public let subscription: SubscriptionSnapshot?
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
        subscription: SubscriptionSnapshot? = nil,
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
        self.subscription = subscription
        self.enrichmentAvailable = enrichmentAvailable
    }

    public var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent.isEmpty ? projectPath : URL(fileURLWithPath: projectPath).lastPathComponent
    }
    public var displayTitle: String { SessionTitleFormatter.displayTitle(title) }
    public var displaySource: String { originator ?? source }
    public var sessionSpan: TimeInterval { max(0, updatedAt.timeIntervalSince(createdAt)) }
    public var activeRuntime: TimeInterval { turns.reduce(0) { $0 + $1.duration } }
    public var completedTurns: Int { turns.filter(\.completed).count }
    public var averageTTFT: TimeInterval? {
        let values = turns.compactMap(\.timeToFirstToken)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    public var summary: SessionSummary { SessionSummary(session: self) }
}

public struct SessionSummary: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let rolloutPath: String
    public let projectPath: String
    public let title: String
    public let source: String
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
    public let toolCalls: Int
    public let skillCalls: Int
    public let userMessages: Int
    public let completedTurns: Int
    public let abortedTurns: Int
    public let activeRuntime: TimeInterval
    public let averageTTFT: TimeInterval?
    public let subscription: SubscriptionSnapshot?
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
        reasoningEffort: String? = nil,
        gitBranch: String? = nil,
        cliVersion: String? = nil,
        archived: Bool = false,
        usage: TokenUsage,
        toolCalls: Int = 0,
        skillCalls: Int = 0,
        userMessages: Int = 0,
        completedTurns: Int = 0,
        abortedTurns: Int = 0,
        activeRuntime: TimeInterval = 0,
        averageTTFT: TimeInterval? = nil,
        subscription: SubscriptionSnapshot? = nil,
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
        self.toolCalls = toolCalls
        self.skillCalls = skillCalls
        self.userMessages = userMessages
        self.completedTurns = completedTurns
        self.abortedTurns = abortedTurns
        self.activeRuntime = activeRuntime
        self.averageTTFT = averageTTFT
        self.subscription = subscription
        self.enrichmentAvailable = enrichmentAvailable
    }

    public init(session: SessionMetric) {
        self.init(
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
            toolCalls: session.toolCalls,
            skillCalls: session.skillCallEvents?.count ?? 0,
            userMessages: session.userMessages,
            completedTurns: session.completedTurns,
            abortedTurns: session.abortedTurns,
            activeRuntime: session.activeRuntime,
            averageTTFT: session.averageTTFT,
            subscription: session.subscription,
            enrichmentAvailable: session.enrichmentAvailable
        )
    }

    public var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent.isEmpty ? projectPath : URL(fileURLWithPath: projectPath).lastPathComponent
    }
    public var displayTitle: String { SessionTitleFormatter.displayTitle(title) }
    public var displaySource: String { originator ?? source }
    public var sessionSpan: TimeInterval { max(0, updatedAt.timeIntervalSince(createdAt)) }
}

public struct ProjectMetric: Identifiable, Hashable, Sendable {
    public var id: String { kind == .standalone ? "standalone-sessions" : path }
    public let path: String
    /// All source paths represented by this project. A project can have more
    /// than one checkout (for example, a main worktree and a Codex worktree).
    public let paths: [String]
    public let kind: ProjectMetricKind
    public let sessions: [SessionSummary]
    private let aggregateUsage: TokenUsage?
    private let aggregateRuntime: TimeInterval?
    private let aggregateSessionCount: Int?
    private let aggregateLastActivity: Date?

    public init(path: String, sessions: [SessionSummary], kind: ProjectMetricKind = .project) {
        self.path = path
        self.paths = [path]
        self.kind = kind
        self.sessions = sessions
        self.aggregateUsage = nil
        self.aggregateRuntime = nil
        self.aggregateSessionCount = nil
        self.aggregateLastActivity = nil
    }

    public init(path: String, fullSessions: [SessionMetric], kind: ProjectMetricKind = .project) {
        self.path = path
        self.paths = [path]
        self.kind = kind
        self.sessions = fullSessions.map(\.summary)
        self.aggregateUsage = nil
        self.aggregateRuntime = nil
        self.aggregateSessionCount = nil
        self.aggregateLastActivity = nil
    }

    public init(path: String, paths: [String], sessions: [SessionSummary], kind: ProjectMetricKind = .project) {
        self.path = path
        self.paths = paths
        self.kind = kind
        self.sessions = sessions
        self.aggregateUsage = nil
        self.aggregateRuntime = nil
        self.aggregateSessionCount = nil
        self.aggregateLastActivity = nil
    }

    public init(
        path: String,
        paths: [String],
        sessions: [SessionSummary],
        usage: TokenUsage,
        activeRuntime: TimeInterval,
        sessionCount: Int,
        lastActivity: Date,
        kind: ProjectMetricKind = .project
    ) {
        self.path = path
        self.paths = paths
        self.kind = kind
        self.sessions = sessions
        self.aggregateUsage = usage
        self.aggregateRuntime = activeRuntime
        self.aggregateSessionCount = sessionCount
        self.aggregateLastActivity = lastActivity
    }

    public init(
        path: String,
        paths: [String],
        usage: TokenUsage,
        activeRuntime: TimeInterval,
        sessionCount: Int,
        lastActivity: Date,
        kind: ProjectMetricKind = .project
    ) {
        self.path = path
        self.paths = paths
        self.kind = kind
        self.sessions = []
        self.aggregateUsage = usage
        self.aggregateRuntime = activeRuntime
        self.aggregateSessionCount = sessionCount
        self.aggregateLastActivity = lastActivity
    }

    public var name: String {
        kind == .standalone ? "Standalone sessions" : URL(fileURLWithPath: path).lastPathComponent
    }
    public var usage: TokenUsage { aggregateUsage ?? sessions.reduce(.zero) { $0 + $1.usage } }
    public var activeRuntime: TimeInterval { aggregateRuntime ?? sessions.reduce(0) { $0 + $1.activeRuntime } }
    public var sessionCount: Int { aggregateSessionCount ?? sessions.count }
    public var lastActivity: Date { aggregateLastActivity ?? sessions.map(\.updatedAt).max() ?? .distantPast }
    public var activeDays: Int { Set(sessions.map { Calendar.current.startOfDay(for: $0.updatedAt) }).count }
    public var dominantModel: String? {
        Dictionary(grouping: sessions.compactMap(\.model), by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
}

public enum ProjectMetricKind: Hashable, Sendable {
    case project
    case standalone
}

public enum SessionTitleFormatter {
    public static func displayTitle(_ rawTitle: String) -> String {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Untitled session" }
        guard title.hasPrefix("<codex_delegation") else { return title }
        guard let data = title.data(using: .utf8) else { return "Delegated session" }

        let delegate = DelegationInputParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return "Delegated session" }
        let input = delegate.input.trimmingCharacters(in: .whitespacesAndNewlines)
        return input.isEmpty ? "Delegated session" : input
    }
}

private final class DelegationInputParser: NSObject, XMLParserDelegate {
    var input = ""
    private var isReadingInput = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "input" { isReadingInput = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingInput { input += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "input" { isReadingInput = false }
    }
}

public enum ProjectCatalogBuilder {
    public static func make(rows: [ProjectAggregateRow]) -> [ProjectMetric] {
        var grouped: [String: [ProjectAggregateRow]] = [:]
        var standalone: [ProjectAggregateRow] = []

        for row in rows {
            let cwd = row.path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cwd.isEmpty, cwd != "Unknown" {
                grouped[cwd, default: []].append(row)
            } else {
                standalone.append(row)
            }
        }

        var projects: [ProjectMetric] = grouped.map { cwd, rows in
            metric(path: cwd, rows: rows, kind: .project)
        }
        projects.sort { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            return lhs.path < rhs.path
        }

        if !standalone.isEmpty {
            let representative = standalone.max { $0.lastActivity < $1.lastActivity }!.path
            projects.append(metric(path: representative, rows: standalone, kind: .standalone))
        }
        return projects
    }

    private static func metric(
        path: String,
        rows: [ProjectAggregateRow],
        kind: ProjectMetricKind
    ) -> ProjectMetric {
        ProjectMetric(
            path: path,
            paths: Array(Set(rows.flatMap(\.paths))).sorted(),
            sessions: [],
            usage: rows.reduce(.zero) { $0 + $1.usage },
            activeRuntime: rows.reduce(0) { $0 + $1.activeRuntime },
            sessionCount: rows.reduce(0) { $0 + $1.sessionCount },
            lastActivity: rows.map(\.lastActivity).max() ?? .distantPast,
            kind: kind
        )
    }
}

public struct PeriodMetric: Identifiable, Codable, Hashable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let usage: TokenUsage
    public let sessions: Int
    public let activeRuntime: TimeInterval
    public let estimatedCost: Decimal

    public init(
        start: Date,
        usage: TokenUsage,
        sessions: Int,
        activeRuntime: TimeInterval,
        estimatedCost: Decimal
    ) {
        self.start = start
        self.usage = usage
        self.sessions = sessions
        self.activeRuntime = activeRuntime
        self.estimatedCost = estimatedCost
    }
}

public struct ModelPeriodMetric: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(model)|\(start.timeIntervalSinceReferenceDate)" }
    public let start: Date
    public let model: String
    public let usage: TokenUsage
    public let sessions: Int
    public let activeRuntime: TimeInterval
    public let estimatedCost: Decimal

    public init(
        start: Date,
        model: String,
        usage: TokenUsage,
        sessions: Int,
        activeRuntime: TimeInterval,
        estimatedCost: Decimal
    ) {
        self.start = start
        self.model = model
        self.usage = usage
        self.sessions = sessions
        self.activeRuntime = activeRuntime
        self.estimatedCost = estimatedCost
    }
}

public struct ModelMetric: Identifiable, Codable, Hashable, Sendable {
    public var id: String { model }
    public let model: String
    public let sessions: Int
    public let usage: TokenUsage
    public let activeRuntime: TimeInterval
    public let estimatedCost: Decimal

    public init(model: String, sessions: Int, usage: TokenUsage, activeRuntime: TimeInterval, estimatedCost: Decimal) {
        self.model = model
        self.sessions = sessions
        self.usage = usage
        self.activeRuntime = activeRuntime
        self.estimatedCost = estimatedCost
    }
}

public struct ToolMetric: Identifiable, Codable, Hashable, Sendable {
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

public struct SkillMetric: Identifiable, Codable, Hashable, Sendable {
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
