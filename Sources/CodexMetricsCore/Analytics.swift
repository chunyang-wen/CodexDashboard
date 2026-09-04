import Foundation

public enum PeriodGranularity: String, CaseIterable, Hashable, Sendable {
    case day, week, month, year
}

public enum Analytics {
    public static func projects(from sessions: [SessionSummary]) -> [ProjectMetric] {
        let projects: [ProjectMetric] = Dictionary(grouping: sessions, by: \.projectPath)
            .map { path, groupedSessions in
                ProjectMetric(
                    path: path,
                    paths: [path],
                    sessions: groupedSessions.sorted { $0.updatedAt > $1.updatedAt }
                )
            }
        return projects.sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            return lhs.path < rhs.path
        }
    }

    public static func projects(from sessions: [SessionMetric]) -> [ProjectMetric] {
        projects(from: sessions.map(\.summary))
    }

    public static func totalUsage(_ sessions: [SessionMetric], since startDate: Date? = nil) -> TokenUsage {
        guard let startDate else { return sessions.reduce(.zero) { $0 + $1.usage } }
        return sessions.reduce(.zero) { total, session in
            if session.enrichmentAvailable {
                return total + session.usageEvents.lazy
                    .filter { $0.date >= startDate }
                    .reduce(.zero) { $0 + $1.usage }
            }
            return session.updatedAt >= startDate ? total + session.usage : total
        }
    }

    /// Totals usage inside an exact, half-open time window. The end is excluded so
    /// an event recorded at a quota reset belongs to the next quota window.
    public static func totalUsage(_ sessions: [SessionMetric], in interval: DateInterval) -> TokenUsage {
        sessions.reduce(.zero) { total, session in
            if session.enrichmentAvailable {
                return total + session.usageEvents.lazy
                    .filter { $0.date >= interval.start && $0.date < interval.end }
                    .reduce(.zero) { $0 + $1.usage }
            }
            return session.updatedAt >= interval.start && session.updatedAt < interval.end
                ? total + session.usage
                : total
        }
    }

    public static func totalEstimatedCost(
        _ sessions: [SessionMetric],
        pricing: PricingHistory = .bundled,
        since startDate: Date? = nil
    ) -> Decimal {
        sessions.reduce(Decimal.zero) { total, session in
            if session.enrichmentAvailable {
                return total + session.usageEvents.lazy
                    .filter { event in startDate.map { event.date >= $0 } ?? true }
                    .reduce(Decimal.zero) { subtotal, event in
                        subtotal + (pricing.estimate(usage: event.usage, model: event.model ?? session.model, serviceTier: event.serviceTier ?? session.serviceTier, on: event.date) ?? 0)
                    }
            }
            guard startDate.map({ session.updatedAt >= $0 }) ?? true else { return total }
            return total + (pricing.estimate(usage: session.usage, model: session.model, serviceTier: session.serviceTier, on: session.updatedAt) ?? 0)
        }
    }

    /// Estimates cost inside the same exact, half-open interval used for quota usage.
    public static func totalEstimatedCost(
        _ sessions: [SessionMetric],
        pricing: PricingHistory = .bundled,
        in interval: DateInterval
    ) -> Decimal {
        sessions.reduce(Decimal.zero) { total, session in
            if session.enrichmentAvailable {
                return total + session.usageEvents.lazy
                    .filter { $0.date >= interval.start && $0.date < interval.end }
                    .reduce(Decimal.zero) { subtotal, event in
                        subtotal + (pricing.estimate(
                            usage: event.usage,
                            model: event.model ?? session.model,
                            serviceTier: event.serviceTier ?? session.serviceTier,
                            on: event.date
                        ) ?? 0)
                    }
            }
            guard session.updatedAt >= interval.start, session.updatedAt < interval.end else { return total }
            return total + (pricing.estimate(
                usage: session.usage,
                model: session.model,
                serviceTier: session.serviceTier,
                on: session.updatedAt
            ) ?? 0)
        }
    }

    public static func costCoverage(
        _ sessions: [SessionMetric],
        pricing: PricingHistory = .bundled,
        since startDate: Date? = nil,
        totalTokens knownTotal: Int64? = nil
    ) -> Double {
        let total = knownTotal ?? totalUsage(sessions, since: startDate).total
        guard total > 0 else { return 0 }
        let covered = sessions.reduce(Int64.zero) { subtotal, session in
            if session.enrichmentAvailable {
                return subtotal + session.usageEvents.lazy
                    .filter { event in startDate.map { event.date >= $0 } ?? true }
                    .filter { pricing.price(for: $0.model ?? session.model, on: $0.date) != nil && $0.usage.input > 0 }
                    .reduce(Int64.zero) { $0 + $1.usage.total }
            }
            guard startDate.map({ session.updatedAt >= $0 }) ?? true,
                  pricing.price(for: session.model, on: session.updatedAt) != nil,
                  session.usage.input > 0 else { return subtotal }
            return subtotal + session.usage.total
        }
        return Double(covered) / Double(total)
    }

    public static func periods(
        from sessions: [SessionMetric],
        granularity: PeriodGranularity,
        pricing: PricingHistory = .bundled,
        calendar: Calendar = .current,
        since startDate: Date? = nil
    ) -> [PeriodMetric] {
        struct Bucket {
            var usage = TokenUsage.zero
            var sessionIDs = Set<String>()
            var runtime: TimeInterval = 0
            var cost = Decimal.zero
        }
        var buckets: [Date: Bucket] = [:]

        for session in sessions {
            // Indexed session totals have no reliable time distribution. Only event-level
            // deltas belong on a trend; assigning a whole session to updatedAt creates a
            // misleading spike while background enrichment is still running.
            for event in session.usageEvents {
                guard startDate.map({ event.date >= $0 }) ?? true else { continue }
                let start = periodStart(event.date, granularity: granularity, calendar: calendar)
                var bucket = buckets[start, default: Bucket()]
                bucket.usage = bucket.usage + event.usage
                bucket.sessionIDs.insert(session.id)
                bucket.cost += pricing.estimate(usage: event.usage, model: event.model ?? session.model, serviceTier: event.serviceTier ?? session.serviceTier, on: event.date) ?? 0
                buckets[start] = bucket
            }
            for turn in session.turns where turn.completed {
                guard startDate.map({ turn.completedAt >= $0 }) ?? true else { continue }
                let start = periodStart(turn.completedAt, granularity: granularity, calendar: calendar)
                var bucket = buckets[start, default: Bucket()]
                bucket.runtime += turn.duration
                bucket.sessionIDs.insert(session.id)
                buckets[start] = bucket
            }
            if session.turns.isEmpty {
                let start = periodStart(session.updatedAt, granularity: granularity, calendar: calendar)
                buckets[start, default: Bucket()].sessionIDs.insert(session.id)
            }
        }
        return buckets.map { PeriodMetric(start: $0.key, usage: $0.value.usage, sessions: $0.value.sessionIDs.count, activeRuntime: $0.value.runtime, estimatedCost: $0.value.cost) }
            .sorted { $0.start < $1.start }
    }

    /// Builds every calendar breakdown in one traversal. Dashboard refreshes need
    /// all four series, so each event is priced once instead of four times.
    public static func periodBreakdowns(
        from sessions: [SessionMetric],
        pricing: PricingHistory = .bundled,
        calendar: Calendar = .current,
        since startDate: Date? = nil
    ) -> [PeriodGranularity: [PeriodMetric]] {
        struct Bucket {
            var usage = TokenUsage.zero
            var sessionIDs = Set<String>()
            var runtime: TimeInterval = 0
            var cost = Decimal.zero
        }
        var allBuckets = Dictionary(
            uniqueKeysWithValues: PeriodGranularity.allCases.map { ($0, [Date: Bucket]()) }
        )

        for session in sessions {
            for event in session.usageEvents {
                guard startDate.map({ event.date >= $0 }) ?? true else { continue }
                let cost = pricing.estimate(
                    usage: event.usage,
                    model: event.model ?? session.model,
                    serviceTier: event.serviceTier ?? session.serviceTier,
                    on: event.date
                ) ?? 0
                for granularity in PeriodGranularity.allCases {
                    let start = periodStart(event.date, granularity: granularity, calendar: calendar)
                    var bucket = allBuckets[granularity]![start, default: Bucket()]
                    bucket.usage = bucket.usage + event.usage
                    bucket.sessionIDs.insert(session.id)
                    bucket.cost += cost
                    allBuckets[granularity]![start] = bucket
                }
            }
            for turn in session.turns where turn.completed {
                guard startDate.map({ turn.completedAt >= $0 }) ?? true else { continue }
                for granularity in PeriodGranularity.allCases {
                    let start = periodStart(turn.completedAt, granularity: granularity, calendar: calendar)
                    var bucket = allBuckets[granularity]![start, default: Bucket()]
                    bucket.runtime += turn.duration
                    bucket.sessionIDs.insert(session.id)
                    allBuckets[granularity]![start] = bucket
                }
            }
            if session.turns.isEmpty {
                for granularity in PeriodGranularity.allCases {
                    let start = periodStart(session.updatedAt, granularity: granularity, calendar: calendar)
                    allBuckets[granularity]![start, default: Bucket()].sessionIDs.insert(session.id)
                }
            }
        }

        return allBuckets.mapValues { buckets in
            buckets.map {
                PeriodMetric(
                    start: $0.key,
                    usage: $0.value.usage,
                    sessions: $0.value.sessionIDs.count,
                    activeRuntime: $0.value.runtime,
                    estimatedCost: $0.value.cost
                )
            }
            .sorted { $0.start < $1.start }
        }
    }

    public static func models(
        from sessions: [SessionMetric],
        pricing: PricingHistory = .bundled,
        since startDate: Date? = nil
    ) -> [ModelMetric] {
        struct Bucket {
            var usage = TokenUsage.zero
            var sessionIDs = Set<String>()
            var activeRuntime: TimeInterval = 0
            var cost = Decimal.zero
        }
        var buckets: [String: Bucket] = [:]
        for session in sessions {
            if session.enrichmentAvailable {
                for event in session.usageEvents where startDate.map({ event.date >= $0 }) ?? true {
                    let model = event.model ?? session.model ?? "Unknown"
                    buckets[model, default: Bucket()].usage = buckets[model, default: Bucket()].usage + event.usage
                    buckets[model, default: Bucket()].sessionIDs.insert(session.id)
                    buckets[model, default: Bucket()].cost += pricing.estimate(usage: event.usage, model: model, serviceTier: event.serviceTier ?? session.serviceTier, on: event.date) ?? 0
                }
            } else if startDate.map({ session.updatedAt >= $0 }) ?? true {
                let model = session.model ?? "Unknown"
                buckets[model, default: Bucket()].usage = buckets[model, default: Bucket()].usage + session.usage
                buckets[model, default: Bucket()].sessionIDs.insert(session.id)
                buckets[model, default: Bucket()].cost += pricing.estimate(usage: session.usage, model: model, serviceTier: session.serviceTier, on: session.updatedAt) ?? 0
            }
            let runtimeModel = session.model ?? "Unknown"
            for turn in session.turns where turn.completed && (startDate.map({ turn.completedAt >= $0 }) ?? true) {
                buckets[runtimeModel, default: Bucket()].activeRuntime += turn.duration
                buckets[runtimeModel, default: Bucket()].sessionIDs.insert(session.id)
            }
        }
        return buckets.map { model, bucket in
            ModelMetric(
                model: model,
                sessions: bucket.sessionIDs.count,
                usage: bucket.usage,
                activeRuntime: bucket.activeRuntime,
                estimatedCost: bucket.cost
            )
        }.sorted { $0.usage.total > $1.usage.total }
    }

    public static func tools(
        from sessions: [SessionMetric],
        pricing: PricingHistory = .bundled,
        since startDate: Date? = nil
    ) -> [ToolMetric] {
        struct Bucket {
            var calls = 0
            var attributedCalls = 0
            var sessionIDs = Set<String>()
            var usage = TokenUsage.zero
            var cost = Decimal.zero
        }
        var buckets: [String: Bucket] = [:]
        for session in sessions {
            for event in session.toolCallEvents ?? [] where startDate.map({ event.date >= $0 }) ?? true {
                var bucket = buckets[event.name, default: Bucket()]
                bucket.calls += 1
                bucket.sessionIDs.insert(session.id)
                bucket.usage = bucket.usage + event.attributedUsage
                if event.attributedUsage.total > 0 {
                    bucket.attributedCalls += 1
                    bucket.cost += pricing.estimate(
                        usage: event.attributedUsage,
                        model: event.model ?? session.model,
                        serviceTier: event.serviceTier ?? session.serviceTier,
                        on: event.date
                    ) ?? 0
                }
                buckets[event.name] = bucket
            }
        }
        return buckets.map { name, bucket in
            ToolMetric(
                tool: name,
                calls: bucket.calls,
                attributedCalls: bucket.attributedCalls,
                sessions: bucket.sessionIDs.count,
                attributedUsage: bucket.usage,
                estimatedCost: bucket.cost
            )
        }.sorted {
            if $0.calls != $1.calls { return $0.calls > $1.calls }
            if $0.estimatedCost != $1.estimatedCost { return $0.estimatedCost > $1.estimatedCost }
            return $0.tool.localizedStandardCompare($1.tool) == .orderedAscending
        }
    }

    public static func skills(
        from sessions: [SessionMetric],
        pricing: PricingHistory = .bundled,
        since startDate: Date? = nil
    ) -> [SkillMetric] {
        struct Bucket {
            var calls = 0
            var attributedCalls = 0
            var sessionIDs = Set<String>()
            var usage = TokenUsage.zero
            var cost = Decimal.zero
        }
        var buckets: [String: Bucket] = [:]
        for session in sessions {
            for event in session.skillCallEvents ?? [] where startDate.map({ event.date >= $0 }) ?? true {
                var bucket = buckets[event.name, default: Bucket()]
                bucket.calls += 1
                bucket.sessionIDs.insert(session.id)
                bucket.usage = bucket.usage + event.attributedUsage
                if event.attributedUsage.total > 0 {
                    bucket.attributedCalls += 1
                    bucket.cost += pricing.estimate(
                        usage: event.attributedUsage,
                        model: event.model ?? session.model,
                        serviceTier: event.serviceTier ?? session.serviceTier,
                        on: event.date
                    ) ?? 0
                }
                buckets[event.name] = bucket
            }
        }
        return buckets.map { name, bucket in
            SkillMetric(
                skill: name,
                calls: bucket.calls,
                attributedCalls: bucket.attributedCalls,
                sessions: bucket.sessionIDs.count,
                attributedUsage: bucket.usage,
                estimatedCost: bucket.cost
            )
        }.sorted {
            if $0.calls != $1.calls { return $0.calls > $1.calls }
            if $0.estimatedCost != $1.estimatedCost { return $0.estimatedCost > $1.estimatedCost }
            return $0.skill.localizedStandardCompare($1.skill) == .orderedAscending
        }
    }

    public static func percentile(_ values: [TimeInterval], _ percentile: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * min(1, max(0, percentile))).rounded())
        return sorted[index]
    }

    private static func periodStart(_ date: Date, granularity: PeriodGranularity, calendar: Calendar) -> Date {
        switch granularity {
        case .day: return calendar.startOfDay(for: date)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month: return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        case .year: return calendar.dateInterval(of: .year, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }
}

public enum MetricFormatters {
    public static func compactNumber(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    public static func duration(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : interval >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? "—"
    }

    public static func age(since date: Date, relativeTo now: Date = .now) -> String {
        let interval = now.timeIntervalSince(date)
        return interval < 1 ? "now" : duration(interval)
    }

    public static func currency(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    public static func preciseCurrency(_ value: Decimal) -> String {
        let magnitude = abs(value.doubleValue)
        let digits = magnitude > 0 && magnitude < 0.01 ? 6 : 2
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2...digits)))
    }
}

private extension Decimal {
    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}
