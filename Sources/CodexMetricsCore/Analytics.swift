import Foundation

public enum PeriodGranularity: String, CaseIterable, Sendable {
    case day, week, month
}

public enum Analytics {
    public static func projects(from sessions: [SessionMetric]) -> [ProjectMetric] {
        Dictionary(grouping: sessions, by: \.projectPath)
            .map { ProjectMetric(path: $0.key, sessions: $0.value) }
            .sorted { $0.lastActivity > $1.lastActivity }
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
                        subtotal + (pricing.estimate(usage: event.usage, model: event.model ?? session.model, on: event.date) ?? 0)
                    }
            }
            guard startDate.map({ session.updatedAt >= $0 }) ?? true else { return total }
            return total + (pricing.estimate(usage: session.usage, model: session.model, on: session.updatedAt) ?? 0)
        }
    }

    public static func costCoverage(
        _ sessions: [SessionMetric],
        pricing: PricingHistory = .bundled,
        since startDate: Date? = nil
    ) -> Double {
        let total = totalUsage(sessions, since: startDate).total
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
                bucket.cost += pricing.estimate(usage: event.usage, model: event.model ?? session.model, on: event.date) ?? 0
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
                    buckets[model, default: Bucket()].cost += pricing.estimate(usage: event.usage, model: model, on: event.date) ?? 0
                }
            } else if startDate.map({ session.updatedAt >= $0 }) ?? true {
                let model = session.model ?? "Unknown"
                buckets[model, default: Bucket()].usage = buckets[model, default: Bucket()].usage + session.usage
                buckets[model, default: Bucket()].sessionIDs.insert(session.id)
                buckets[model, default: Bucket()].cost += pricing.estimate(usage: session.usage, model: model, on: session.updatedAt) ?? 0
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

    public static func currency(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
