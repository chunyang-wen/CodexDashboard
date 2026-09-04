import Foundation

public struct IndexedSessionMetrics: Codable, Hashable, Sendable {
    public let sessionID: String
    public let sourceRevision: String
    public let projectPath: String
    public let updatedAt: Date
    public let usage: TokenUsage
    public let estimatedCost: Decimal
    public let coveredTokens: Int64
    public let activeRuntime: TimeInterval
    public let models: [ModelMetric]
    public let tools: [ToolMetric]
    public let skills: [SkillMetric]
    public let turnDurations: [TimeInterval]
    public let firstTokenTimes: [TimeInterval]
    public let toolCalls: Int
    public let skillCalls: Int
    public let completedTurns: Int
    public let abortedTurns: Int
}

/// One session's contribution to one calendar day. Keeping the session ID in the
/// primary key lets a growing session replace only its own historical contributions.
public struct IndexedDailyMetrics: Codable, Hashable, Sendable {
    public let sessionID: String
    public let projectPath: String
    public let day: Date
    public let usage: TokenUsage
    public let estimatedCost: Decimal
    public let coveredTokens: Int64
    public let activeRuntime: TimeInterval
    public let models: [ModelMetric]
    public let tools: [ToolMetric]
    public let skills: [SkillMetric]
    public let turnDurations: [TimeInterval]
    public let firstTokenTimes: [TimeInterval]
    public let toolCalls: Int
    public let skillCalls: Int
    public let completedTurns: Int
}

public struct MetricsIndexAggregate: Sendable {
    public let usage: TokenUsage
    public let estimatedCost: Decimal
    public let costCoverage: Double
    public let activeRuntime: TimeInterval
    public let models: [ModelMetric]
    public let tools: [ToolMetric]
    public let skills: [SkillMetric]
    public let turnDurations: [TimeInterval]
    public let firstTokenTimes: [TimeInterval]
    public let activeDays: Int
    public let toolCalls: Int
    public let skillCalls: Int
    public let completedTurns: Int
    public let abortedTurns: Int
}

public struct MetricsIndexSnapshot: Sendable {
    public let sessions: [IndexedSessionMetrics]
    public let days: [IndexedDailyMetrics]

    public init(sessions: [IndexedSessionMetrics], days: [IndexedDailyMetrics]) {
        self.sessions = sessions
        self.days = days
    }

    public static let empty = MetricsIndexSnapshot(sessions: [], days: [])

    public func aggregate(
        projectPath: String? = nil,
        since startDate: Date? = nil,
        before endDate: Date? = nil
    ) -> MetricsIndexAggregate {
        let selectedSessions = sessions.filter { projectPath == nil || $0.projectPath == projectPath }
        let selectedIDs = selectedSessions.isEmpty && sessions.isEmpty
            ? Set(days.lazy.filter { projectPath == nil || $0.projectPath == projectPath }.map(\.sessionID))
            : Set(selectedSessions.map(\.sessionID))
        let startDay = startDate.map { Calendar.current.startOfDay(for: $0) }
        let selectedDays = days.filter { contribution in
            selectedIDs.contains(contribution.sessionID)
                && (startDay.map { contribution.day >= $0 } ?? true)
                && (endDate.map { contribution.day < $0 } ?? true)
        }

        let usage: TokenUsage
        let cost: Decimal
        let covered: Int64
        let runtime: TimeInterval
        let models: [ModelMetric]
        let tools: [ToolMetric]
        let skills: [SkillMetric]
        let turnDurations: [TimeInterval]
        let firstTokenTimes: [TimeInterval]
        let toolCalls: Int
        let skillCalls: Int
        let completedTurns: Int
        let abortedTurns: Int

        if startDate == nil {
            usage = selectedSessions.reduce(.zero) { $0 + $1.usage }
            cost = selectedSessions.reduce(Decimal.zero) { $0 + $1.estimatedCost }
            covered = selectedSessions.reduce(0) { $0 + $1.coveredTokens }
            runtime = selectedSessions.reduce(0) { $0 + $1.activeRuntime }
            models = Self.mergeModels(selectedSessions.flatMap { summary in
                summary.models.map { (summary.sessionID, $0) }
            })
            tools = Self.mergeTools(selectedSessions.flatMap { summary in
                summary.tools.map { (summary.sessionID, $0) }
            })
            skills = Self.mergeSkills(selectedSessions.flatMap { summary in
                summary.skills.map { (summary.sessionID, $0) }
            })
            turnDurations = selectedSessions.flatMap(\.turnDurations)
            firstTokenTimes = selectedSessions.flatMap(\.firstTokenTimes)
            toolCalls = selectedSessions.reduce(0) { $0 + $1.toolCalls }
            skillCalls = selectedSessions.reduce(0) { $0 + $1.skillCalls }
            completedTurns = selectedSessions.reduce(0) { $0 + $1.completedTurns }
            abortedTurns = selectedSessions.reduce(0) { $0 + $1.abortedTurns }
        } else {
            usage = selectedDays.reduce(.zero) { $0 + $1.usage }
            cost = selectedDays.reduce(Decimal.zero) { $0 + $1.estimatedCost }
            covered = selectedDays.reduce(0) { $0 + $1.coveredTokens }
            runtime = selectedDays.reduce(0) { $0 + $1.activeRuntime }
            models = Self.mergeModels(selectedDays.flatMap { day in day.models.map { (day.sessionID, $0) } })
            tools = Self.mergeTools(selectedDays.flatMap { day in day.tools.map { (day.sessionID, $0) } })
            skills = Self.mergeSkills(selectedDays.flatMap { day in day.skills.map { (day.sessionID, $0) } })
            turnDurations = selectedDays.flatMap(\.turnDurations)
            firstTokenTimes = selectedDays.flatMap(\.firstTokenTimes)
            toolCalls = selectedDays.reduce(0) { $0 + $1.toolCalls }
            skillCalls = selectedDays.reduce(0) { $0 + $1.skillCalls }
            completedTurns = selectedDays.reduce(0) { $0 + $1.completedTurns }
            abortedTurns = selectedSessions.lazy.filter { session in
                session.updatedAt >= startDate!
                    && (endDate.map { session.updatedAt < $0 } ?? true)
            }.reduce(0) { $0 + $1.abortedTurns }
        }

        return MetricsIndexAggregate(
            usage: usage,
            estimatedCost: cost,
            costCoverage: usage.total > 0 ? Double(covered) / Double(usage.total) : 0,
            activeRuntime: runtime,
            models: models,
            tools: tools,
            skills: skills,
            turnDurations: turnDurations,
            firstTokenTimes: firstTokenTimes,
            activeDays: Set(selectedDays.map(\.day)).count,
            toolCalls: toolCalls,
            skillCalls: skillCalls,
            completedTurns: completedTurns,
            abortedTurns: abortedTurns
        )
    }

    public func aggregate(projectPath: String? = nil, in interval: DateInterval) -> MetricsIndexAggregate {
        aggregate(projectPath: projectPath, since: interval.start, before: interval.end)
    }

    public func periods(
        granularity: PeriodGranularity,
        projectPath: String? = nil,
        since startDate: Date? = nil,
        calendar: Calendar = .current
    ) -> [PeriodMetric] {
        struct Bucket {
            var usage = TokenUsage.zero
            var sessions = Set<String>()
            var runtime: TimeInterval = 0
            var cost = Decimal.zero
        }
        let startDay = startDate.map { calendar.startOfDay(for: $0) }
        var buckets: [Date: Bucket] = [:]
        for contribution in days where
            (projectPath == nil || contribution.projectPath == projectPath)
                && (startDay.map { contribution.day >= $0 } ?? true) {
            let start = Self.periodStart(contribution.day, granularity: granularity, calendar: calendar)
            var bucket = buckets[start, default: Bucket()]
            bucket.usage = bucket.usage + contribution.usage
            bucket.sessions.insert(contribution.sessionID)
            bucket.runtime += contribution.activeRuntime
            bucket.cost += contribution.estimatedCost
            buckets[start] = bucket
        }
        return buckets.map { start, bucket in
            PeriodMetric(
                start: start,
                usage: bucket.usage,
                sessions: bucket.sessions.count,
                activeRuntime: bucket.runtime,
                estimatedCost: bucket.cost
            )
        }.sorted { $0.start < $1.start }
    }

    public func modelPeriods(
        granularity: PeriodGranularity,
        projectPath: String? = nil,
        since startDate: Date? = nil,
        calendar: Calendar = .current
    ) -> [ModelPeriodMetric] {
        struct Bucket {
            var usage = TokenUsage.zero
            var sessions = Set<String>()
            var runtime: TimeInterval = 0
            var cost = Decimal.zero
        }

        let startDay = startDate.map { calendar.startOfDay(for: $0) }
        var buckets: [String: [Date: Bucket]] = [:]
        for contribution in days where
            (projectPath == nil || contribution.projectPath == projectPath)
                && (startDay.map { contribution.day >= $0 } ?? true)
        {
            let start = Self.periodStart(contribution.day, granularity: granularity, calendar: calendar)
            for model in contribution.models {
                var modelBuckets = buckets[model.model, default: [:]]
                var bucket = modelBuckets[start, default: Bucket()]
                bucket.usage = bucket.usage + model.usage
                bucket.sessions.insert(contribution.sessionID)
                bucket.runtime += model.activeRuntime
                bucket.cost += model.estimatedCost
                modelBuckets[start] = bucket
                buckets[model.model] = modelBuckets
            }
        }

        return buckets.flatMap { model, modelBuckets in
            modelBuckets.map { start, bucket in
                ModelPeriodMetric(
                    start: start,
                    model: model,
                    usage: bucket.usage,
                    sessions: bucket.sessions.count,
                    activeRuntime: bucket.runtime,
                    estimatedCost: bucket.cost
                )
            }
        }
        .sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.model.localizedStandardCompare($1.model) == .orderedAscending
        }
    }

    private static func periodStart(_ date: Date, granularity: PeriodGranularity, calendar: Calendar) -> Date {
        switch granularity {
        case .day: calendar.startOfDay(for: date)
        case .week: calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month: calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        case .year: calendar.dateInterval(of: .year, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    private static func mergeModels(_ values: [(String, ModelMetric)]) -> [ModelMetric] {
        struct Bucket { var usage = TokenUsage.zero; var sessions = Set<String>(); var runtime = 0.0; var cost = Decimal.zero }
        var buckets: [String: Bucket] = [:]
        for (sessionID, value) in values {
            buckets[value.model, default: Bucket()].usage = buckets[value.model, default: Bucket()].usage + value.usage
            buckets[value.model, default: Bucket()].sessions.insert(sessionID)
            buckets[value.model, default: Bucket()].runtime += value.activeRuntime
            buckets[value.model, default: Bucket()].cost += value.estimatedCost
        }
        return buckets.map { ModelMetric(model: $0.key, sessions: $0.value.sessions.count, usage: $0.value.usage, activeRuntime: $0.value.runtime, estimatedCost: $0.value.cost) }
            .sorted { $0.usage.total > $1.usage.total }
    }

    private static func mergeTools(_ values: [(String, ToolMetric)]) -> [ToolMetric] {
        struct Bucket { var calls = 0; var attributedCalls = 0; var sessions = Set<String>(); var usage = TokenUsage.zero; var cost = Decimal.zero }
        var buckets: [String: Bucket] = [:]
        for (sessionID, value) in values {
            buckets[value.tool, default: Bucket()].calls += value.calls
            buckets[value.tool, default: Bucket()].attributedCalls += value.attributedCalls
            buckets[value.tool, default: Bucket()].sessions.insert(sessionID)
            buckets[value.tool, default: Bucket()].usage = buckets[value.tool, default: Bucket()].usage + value.attributedUsage
            buckets[value.tool, default: Bucket()].cost += value.estimatedCost
        }
        return buckets.map { ToolMetric(tool: $0.key, calls: $0.value.calls, attributedCalls: $0.value.attributedCalls, sessions: $0.value.sessions.count, attributedUsage: $0.value.usage, estimatedCost: $0.value.cost) }
            .sorted { $0.calls != $1.calls ? $0.calls > $1.calls : $0.tool.localizedStandardCompare($1.tool) == .orderedAscending }
    }

    private static func mergeSkills(_ values: [(String, SkillMetric)]) -> [SkillMetric] {
        struct Bucket { var calls = 0; var attributedCalls = 0; var sessions = Set<String>(); var usage = TokenUsage.zero; var cost = Decimal.zero }
        var buckets: [String: Bucket] = [:]
        for (sessionID, value) in values {
            buckets[value.skill, default: Bucket()].calls += value.calls
            buckets[value.skill, default: Bucket()].attributedCalls += value.attributedCalls
            buckets[value.skill, default: Bucket()].sessions.insert(sessionID)
            buckets[value.skill, default: Bucket()].usage = buckets[value.skill, default: Bucket()].usage + value.attributedUsage
            buckets[value.skill, default: Bucket()].cost += value.estimatedCost
        }
        return buckets.map { SkillMetric(skill: $0.key, calls: $0.value.calls, attributedCalls: $0.value.attributedCalls, sessions: $0.value.sessions.count, attributedUsage: $0.value.usage, estimatedCost: $0.value.cost) }
            .sorted { $0.calls != $1.calls ? $0.calls > $1.calls : $0.skill.localizedStandardCompare($1.skill) == .orderedAscending }
    }
}

/// Compact persisted projection consumed by the always-running menu-bar process.
/// It deliberately excludes per-session, model, tool-name, and timing detail.
public struct MenuBarDayMetrics: Codable, Hashable, Sendable {
    public let day: Date
    public let usage: TokenUsage
    public let estimatedCost: Decimal
    public let toolCalls: Int
    public let skillCalls: Int
    public let sessions: Int
    public let activeRuntime: TimeInterval

    public init(
        day: Date,
        usage: TokenUsage,
        estimatedCost: Decimal,
        toolCalls: Int,
        skillCalls: Int,
        sessions: Int,
        activeRuntime: TimeInterval
    ) {
        self.day = day
        self.usage = usage
        self.estimatedCost = estimatedCost
        self.toolCalls = toolCalls
        self.skillCalls = skillCalls
        self.sessions = sessions
        self.activeRuntime = activeRuntime
    }
}

public struct MenuBarMetricsSnapshot: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let days: [MenuBarDayMetrics]

    public init(generatedAt: Date = .now, days: [MenuBarDayMetrics]) {
        self.generatedAt = generatedAt
        self.days = days
    }

    public static let empty = MenuBarMetricsSnapshot(generatedAt: .distantPast, days: [])
}

public enum MetricsIndexBuilder {
    private struct DailyBuilder {
        var usage = TokenUsage.zero
        var cost = Decimal.zero
        var coveredTokens: Int64 = 0
        var runtime: TimeInterval = 0
        var models: [String: (TokenUsage, TimeInterval, Decimal)] = [:]
        var tools: [String: (Int, Int, TokenUsage, Decimal)] = [:]
        var skills: [String: (Int, Int, TokenUsage, Decimal)] = [:]
        var turnDurations: [TimeInterval] = []
        var firstTokenTimes: [TimeInterval] = []
        var toolCalls = 0
        var skillCalls = 0
        var completedTurns = 0
    }

    public static func build(
        session: SessionMetric,
        pricing: PricingHistory = .bundled,
        calendar: Calendar = .current
    ) -> (session: IndexedSessionMetrics, days: [IndexedDailyMetrics]) {
        var buckets: [Date: DailyBuilder] = [:]
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }

        for event in session.usageEvents {
            let key = day(event.date)
            let model = event.model ?? session.model ?? "Unknown"
            let cost = pricing.estimate(usage: event.usage, model: model, serviceTier: event.serviceTier ?? session.serviceTier, on: event.date) ?? 0
            var bucket = buckets[key, default: DailyBuilder()]
            bucket.usage = bucket.usage + event.usage
            bucket.cost += cost
            if pricing.price(for: model, on: event.date) != nil, event.usage.input > 0 {
                bucket.coveredTokens += event.usage.total
            }
            var modelBucket = bucket.models[model] ?? (.zero, 0, 0)
            modelBucket.0 = modelBucket.0 + event.usage
            modelBucket.2 += cost
            bucket.models[model] = modelBucket
            buckets[key] = bucket
        }

        // Some custom model providers update `threads.tokens_used` but do not
        // emit Codex's cumulative token_count timeline. Enrichment can still
        // succeed for turns and tools in that case, so preserve the indexed
        // total and attribute it to the session's latest activity day. Without
        // this fallback, marking the session enriched turns nonzero provider
        // usage into zero in the dashboard and menu bar.
        if session.usageEvents.isEmpty, session.usage.total > 0 {
            let key = day(session.updatedAt)
            let model = session.model ?? "Unknown"
            let cost = pricing.estimate(usage: session.usage, model: model, serviceTier: session.serviceTier, on: session.updatedAt) ?? 0
            var bucket = buckets[key, default: DailyBuilder()]
            bucket.usage = bucket.usage + session.usage
            bucket.cost += cost
            if pricing.price(for: model, on: session.updatedAt) != nil, session.usage.input > 0 {
                bucket.coveredTokens += session.usage.total
            }
            var modelBucket = bucket.models[model] ?? (.zero, 0, 0)
            modelBucket.0 = modelBucket.0 + session.usage
            modelBucket.2 += cost
            bucket.models[model] = modelBucket
            buckets[key] = bucket
        }

        for turn in session.turns where turn.completed {
            let key = day(turn.completedAt)
            let model = session.model ?? "Unknown"
            var bucket = buckets[key, default: DailyBuilder()]
            bucket.runtime += turn.duration
            bucket.turnDurations.append(turn.duration)
            if let ttft = turn.timeToFirstToken { bucket.firstTokenTimes.append(ttft) }
            bucket.completedTurns += 1
            var modelBucket = bucket.models[model] ?? (.zero, 0, 0)
            modelBucket.1 += turn.duration
            bucket.models[model] = modelBucket
            buckets[key] = bucket
        }

        for event in session.toolCallEvents ?? [] {
            let key = day(event.date)
            var bucket = buckets[key, default: DailyBuilder()]
            bucket.toolCalls += 1
            var value = bucket.tools[event.name] ?? (0, 0, .zero, 0)
            value.0 += 1
            value.2 = value.2 + event.attributedUsage
            if event.attributedUsage.total > 0 {
                value.1 += 1
                value.3 += pricing.estimate(usage: event.attributedUsage, model: event.model ?? session.model, serviceTier: event.serviceTier ?? session.serviceTier, on: event.date) ?? 0
            }
            bucket.tools[event.name] = value
            buckets[key] = bucket
        }
        if (session.toolCallEvents ?? []).isEmpty, session.toolCalls > 0 {
            buckets[day(session.updatedAt), default: DailyBuilder()].toolCalls += session.toolCalls
        }

        for event in session.skillCallEvents ?? [] {
            let key = day(event.date)
            var bucket = buckets[key, default: DailyBuilder()]
            bucket.skillCalls += 1
            var value = bucket.skills[event.name] ?? (0, 0, .zero, 0)
            value.0 += 1
            value.2 = value.2 + event.attributedUsage
            if event.attributedUsage.total > 0 {
                value.1 += 1
                value.3 += pricing.estimate(usage: event.attributedUsage, model: event.model ?? session.model, serviceTier: event.serviceTier ?? session.serviceTier, on: event.date) ?? 0
            }
            bucket.skills[event.name] = value
            buckets[key] = bucket
        }
        if buckets.isEmpty { buckets[day(session.updatedAt)] = DailyBuilder() }

        let daily = buckets.map { key, bucket in
            IndexedDailyMetrics(
                sessionID: session.id,
                projectPath: session.projectPath,
                day: key,
                usage: bucket.usage,
                estimatedCost: bucket.cost,
                coveredTokens: bucket.coveredTokens,
                activeRuntime: bucket.runtime,
                models: bucket.models.map { ModelMetric(model: $0.key, sessions: 1, usage: $0.value.0, activeRuntime: $0.value.1, estimatedCost: $0.value.2) },
                tools: bucket.tools.map { ToolMetric(tool: $0.key, calls: $0.value.0, attributedCalls: $0.value.1, sessions: 1, attributedUsage: $0.value.2, estimatedCost: $0.value.3) },
                skills: bucket.skills.map { SkillMetric(skill: $0.key, calls: $0.value.0, attributedCalls: $0.value.1, sessions: 1, attributedUsage: $0.value.2, estimatedCost: $0.value.3) },
                turnDurations: bucket.turnDurations,
                firstTokenTimes: bucket.firstTokenTimes,
                toolCalls: bucket.toolCalls,
                skillCalls: bucket.skillCalls,
                completedTurns: bucket.completedTurns
            )
        }.sorted { $0.day < $1.day }

        let dailyAggregate = MetricsIndexSnapshot(sessions: [], days: daily).aggregate(since: .distantPast)
        let usage: TokenUsage
        let cost: Decimal
        let coveredTokens: Int64
        let models: [ModelMetric]
        if session.enrichmentAvailable {
            usage = daily.reduce(.zero) { $0 + $1.usage }
            cost = daily.reduce(Decimal.zero) { $0 + $1.estimatedCost }
            coveredTokens = daily.reduce(0) { $0 + $1.coveredTokens }
            models = dailyAggregate.models
        } else {
            usage = session.usage
            cost = pricing.estimate(usage: usage, model: session.model, serviceTier: session.serviceTier, on: session.updatedAt) ?? 0
            coveredTokens = pricing.price(for: session.model, on: session.updatedAt) != nil && usage.input > 0 ? usage.total : 0
            models = [ModelMetric(model: session.model ?? "Unknown", sessions: 1, usage: usage, activeRuntime: session.activeRuntime, estimatedCost: cost)]
        }
        let summary = IndexedSessionMetrics(
            sessionID: session.id,
            sourceRevision: sourceRevision(for: session),
            projectPath: session.projectPath,
            updatedAt: session.updatedAt,
            usage: usage,
            estimatedCost: cost,
            coveredTokens: coveredTokens,
            activeRuntime: session.activeRuntime,
            models: models,
            tools: dailyAggregate.tools,
            skills: dailyAggregate.skills,
            turnDurations: Array(session.turns.lazy.filter(\.completed).map(\.duration)),
            firstTokenTimes: Array(session.turns.lazy.filter(\.completed).compactMap(\.timeToFirstToken)),
            toolCalls: (session.toolCallEvents?.isEmpty == false) ? (session.toolCallEvents?.count ?? 0) : session.toolCalls,
            skillCalls: session.skillCallEvents?.count ?? 0,
            completedTurns: session.turns.lazy.filter(\.completed).count,
            abortedTurns: session.abortedTurns
        )
        return (summary, daily)
    }

    public static func sourceRevision(for session: SessionMetric) -> String {
        [
            String(session.updatedAt.timeIntervalSince1970),
            session.enrichmentAvailable ? "1" : "0",
            String(session.usage.total),
            String(session.usageEvents.count),
            String(session.turns.count),
            String(session.toolCallEvents?.count ?? -1),
            String(session.skillCallEvents?.count ?? -1),
            session.projectPath,
            session.model ?? "",
            session.serviceTier ?? "",
            (session.toolCallEvents ?? []).map(\.name).joined(separator: ","),
            (session.skillCallEvents ?? []).map(\.name).joined(separator: ",")
        ].joined(separator: ":")
    }
}
