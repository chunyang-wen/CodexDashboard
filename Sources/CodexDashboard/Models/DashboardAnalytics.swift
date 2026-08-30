import AppKit
import CodexMetricsCore
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DashboardAnalytics: Sendable {
    let filteredSessions: [SessionSummary]
    let allProjects: [ProjectMetric]
    let projects: [ProjectMetric]
    let usage: TokenUsage
    let estimatedCost: Decimal
    let costCoverage: Double
    let runtime: TimeInterval
    let models: [ModelMetric]
    let allTimeModels: [ModelMetric]
    let tools: [ToolMetric]
    let skills: [SkillMetric]
    let daily: [PeriodMetric]
    let weekly: [PeriodMetric]
    let monthly: [PeriodMetric]
    let yearly: [PeriodMetric]
    let modelDaily: [ModelPeriodMetric]
    let modelWeekly: [ModelPeriodMetric]
    let modelMonthly: [ModelPeriodMetric]
    let modelYearly: [ModelPeriodMetric]
    let medianTurnDuration: TimeInterval?
    let p95TurnDuration: TimeInterval?
    let averageTTFT: TimeInterval?
    let activeDays: Int
    let toolCalls: Int
    let skillCalls: Int
    let completedTurns: Int
    var abortedTurns: Int

    static let empty = DashboardAnalytics(
        filteredSessions: [], allProjects: [], projects: [],
        usage: .zero, estimatedCost: 0, costCoverage: 0, runtime: 0,
        models: [], allTimeModels: [], tools: [], skills: [], daily: [], weekly: [], monthly: [], yearly: [],
        modelDaily: [], modelWeekly: [], modelMonthly: [], modelYearly: [],
        medianTurnDuration: nil, p95TurnDuration: nil,
        averageTTFT: nil, activeDays: 0, toolCalls: 0, skillCalls: 0, completedTurns: 0,
        abortedTurns: 0
    )

    /// Builds analytics from pre-fetched SQL results instead of iterating an
    /// in-memory MetricsIndexSnapshot. The active dashboard path keeps only
    /// scalar duration summaries and typed SQLite projections.
    static func fromSQLResults(
        sessions: [SessionSummary],
        startDate: Date?,
        aggregate: DailyAggregateResult,
        periods: [PeriodMetric],
        modelPeriods: [ModelPeriodMetric],
        models: [ModelMetric],
        allTimeModels: [ModelMetric],
        tools: [ToolMetric],
        skills: [SkillMetric],
        granularity: PeriodGranularity = .month,
        medianTurnDuration: TimeInterval? = nil,
        p95TurnDuration: TimeInterval? = nil,
        averageTTFT: TimeInterval? = nil
    ) -> DashboardAnalytics {
        let filtered = sessions.filter { session in
            startDate.map { session.updatedAt >= $0 } ?? true
        }
        // Keep only the projection selected by the dashboard. Building all four
        // granularities here multiplied the chart data retained by the store,
        // even though each page renders one granularity at a time.
        let usage = aggregate.usage
        return DashboardAnalytics(
            filteredSessions: filtered,
            allProjects: Analytics.projects(from: sessions),
            projects: Analytics.projects(from: filtered),
            usage: usage,
            estimatedCost: Decimal(aggregate.estimatedCost),
            costCoverage: usage.total > 0 ? Double(aggregate.coveredTokens) / Double(usage.total) : 0,
            runtime: aggregate.activeRuntime,
            models: models,
            allTimeModels: allTimeModels,
            tools: tools,
            skills: skills,
            daily: granularity == .day ? periods : [],
            weekly: granularity == .week ? periods : [],
            monthly: granularity == .month ? periods : [],
            yearly: granularity == .year ? periods : [],
            modelDaily: granularity == .day ? modelPeriods : [],
            modelWeekly: granularity == .week ? modelPeriods : [],
            modelMonthly: granularity == .month ? modelPeriods : [],
            modelYearly: granularity == .year ? modelPeriods : [],
            medianTurnDuration: medianTurnDuration,
            p95TurnDuration: p95TurnDuration,
            averageTTFT: averageTTFT,
            activeDays: aggregate.activeDays,
            toolCalls: aggregate.toolCalls,
            skillCalls: aggregate.skillCalls,
            completedTurns: aggregate.completedTurns,
            abortedTurns: 0
        )
    }

    static func calculate(
        sessions: [SessionSummary],
        startDate: Date?,
        index: MetricsIndexSnapshot
    ) -> DashboardAnalytics {
        let filtered = sessions.filter { session in
            startDate.map { session.updatedAt >= $0 } ?? true
        }

        let summary = index.aggregate(since: startDate)
        let allTimeModels = startDate == nil ? summary.models : index.aggregate().models
        let averageTTFT = summary.firstTokenTimes.isEmpty
            ? nil
            : summary.firstTokenTimes.reduce(0, +) / Double(summary.firstTokenTimes.count)
        let calendar = Calendar.current

        return DashboardAnalytics(
            filteredSessions: filtered,
            allProjects: Analytics.projects(from: sessions),
            projects: Analytics.projects(from: filtered),
            usage: summary.usage,
            estimatedCost: summary.estimatedCost,
            costCoverage: summary.costCoverage,
            runtime: summary.activeRuntime,
            models: summary.models,
            allTimeModels: allTimeModels,
            tools: summary.tools,
            skills: summary.skills,
            daily: index.periods(granularity: .day, since: startDate, calendar: calendar),
            weekly: index.periods(granularity: .week, since: startDate, calendar: calendar),
            monthly: index.periods(granularity: .month, since: startDate, calendar: calendar),
            yearly: index.periods(granularity: .year, since: startDate, calendar: calendar),
            modelDaily: index.modelPeriods(granularity: .day, since: startDate, calendar: calendar),
            modelWeekly: index.modelPeriods(granularity: .week, since: startDate, calendar: calendar),
            modelMonthly: index.modelPeriods(granularity: .month, since: startDate, calendar: calendar),
            modelYearly: index.modelPeriods(granularity: .year, since: startDate, calendar: calendar),
            medianTurnDuration: Analytics.percentile(summary.turnDurations, 0.5),
            p95TurnDuration: Analytics.percentile(summary.turnDurations, 0.95),
            averageTTFT: averageTTFT,
            activeDays: summary.activeDays,
            toolCalls: summary.toolCalls,
            skillCalls: summary.skillCalls,
            completedTurns: summary.completedTurns,
            abortedTurns: summary.abortedTurns
        )
    }

    /// The menu bar only consumes today's usage, cost, tool calls, and skill calls.
    /// Avoid rebuilding every project/model/period breakdown a second time for it.
    static func calculateToday(
        startDate: Date,
        index: MetricsIndexSnapshot
    ) -> DashboardAnalytics {
        let summary = index.aggregate(since: startDate)

        return DashboardAnalytics(
            filteredSessions: [], allProjects: [], projects: [],
            usage: summary.usage,
            estimatedCost: summary.estimatedCost,
            costCoverage: 0,
            runtime: 0,
            models: [], allTimeModels: [], tools: [], skills: [], daily: [], weekly: [], monthly: [], yearly: [],
            modelDaily: [], modelWeekly: [], modelMonthly: [], modelYearly: [],
            medianTurnDuration: nil, p95TurnDuration: nil, averageTTFT: nil, activeDays: 0,
            toolCalls: summary.toolCalls, skillCalls: summary.skillCalls,
            completedTurns: 0, abortedTurns: 0
        )
    }
}

struct QuotaWeekAnalytics: Sendable {
    let interval: DateInterval?
    let usage: TokenUsage
    let estimatedCost: Decimal

    static let empty = QuotaWeekAnalytics(interval: nil, usage: .zero, estimatedCost: 0)

    static func calculate(
        index: MetricsIndexSnapshot,
        window: UsageQuotaWindow?
    ) -> QuotaWeekAnalytics {
        guard let window else { return .empty }
        let interval = DateInterval(
            start: window.resetsAt.addingTimeInterval(-TimeInterval(window.windowMinutes * 60)),
            end: window.resetsAt
        )
        let agg = index.aggregate(in: interval)
        return QuotaWeekAnalytics(
            interval: interval,
            usage: agg.usage,
            estimatedCost: agg.estimatedCost
        )
    }
}

/// Aggregate result from typed SQL tables, matching the MetricsIndexAggregate
/// fields consumed by ContentView.
struct SQLProjectAggregate: Sendable {
    let usage: TokenUsage
    let estimatedCost: Decimal
    let costCoverage: Double
    let activeRuntime: TimeInterval
    let toolCalls: Int
    let skillCalls: Int
    let activeDays: Int
    let medianTurnDuration: TimeInterval?
    let p95TurnDuration: TimeInterval?
    let averageFirstTokenTime: TimeInterval?
    let tools: [ToolMetric]
    let skills: [SkillMetric]

    static let empty = SQLProjectAggregate(
        usage: .zero, estimatedCost: 0, costCoverage: 0, activeRuntime: 0,
        toolCalls: 0, skillCalls: 0, activeDays: 0,
        medianTurnDuration: nil, p95TurnDuration: nil, averageFirstTokenTime: nil,
        tools: [], skills: []
    )
}

/// Per-session cost extracted from typed tables for project drill-down.
struct IndexedSessionCost: Sendable {
    let estimatedCost: Decimal
    let coveredTokens: Int64
    let totalTokens: Int64
}
