import CodexMetricsCore
import Foundation

enum CLIError: LocalizedError {
    case usage
    var errorDescription: String? { "Run codex-metrics help for usage." }
}

@main
struct CodexMetricsCommand {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "summary"
        if command == "help" || command == "--help" || command == "-h" {
            printHelp()
            return
        }
        let shouldEnrich = arguments.contains("--enrich")
        let homeValue = option("--codex-home", in: arguments)
        let home = homeValue.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let store = CodexStore(codexHome: home)
        var sessions = try store.loadIndexedSessions()
        if let project = option("--project", in: arguments) {
            sessions = sessions.filter { $0.projectPath.localizedCaseInsensitiveContains(project) }
        }
        if let value = option("--limit", in: arguments), let limit = Int(value), limit > 0 {
            sessions = Array(sessions.prefix(limit))
        }
        if shouldEnrich { sessions = store.enrichSessions(sessions) }

        switch command {
        case "summary": printSummary(sessions)
        case "projects": printProjects(sessions)
        case "sessions": printSessions(sessions, project: nil)
        case "models": printModels(sessions)
        case "periods": printPeriods(sessions, granularity: option("--by", in: arguments) ?? "month")
        case "subscription": printSubscription(SubscriptionReader.latest(from: sessions))
        case "export": try exportJSON(sessions, output: option("--output", in: arguments))
        default: throw CLIError.usage
        }
    }

    static func printSummary(_ sessions: [SessionMetric]) {
        let projects = Analytics.projects(from: sessions)
        let usage = Analytics.totalUsage(sessions)
        let runtime = sessions.reduce(0) { $0 + $1.activeRuntime }
        let turnDurations = sessions.flatMap(\.turns).filter(\.completed).map(\.duration)
        print("Projects           \(projects.count)")
        print("Sessions           \(sessions.count)")
        print("Total tokens       \(MetricFormatters.compactNumber(usage.total))")
        print("Input tokens       \(MetricFormatters.compactNumber(usage.input))")
        print("Cached input       \(MetricFormatters.compactNumber(usage.cachedInput))")
        print("Output tokens      \(MetricFormatters.compactNumber(usage.output))")
        print("Reasoning output   \(MetricFormatters.compactNumber(usage.reasoningOutput))")
        print("Agent runtime      \(MetricFormatters.duration(runtime))")
        print("Median turn        \(Analytics.percentile(turnDurations, 0.5).map(MetricFormatters.duration) ?? "—")")
        print("P95 turn           \(Analytics.percentile(turnDurations, 0.95).map(MetricFormatters.duration) ?? "—")")
        let coverage = Analytics.costCoverage(sessions)
        print("Estimated cost     \(coverage > 0 ? MetricFormatters.currency(Analytics.totalEstimatedCost(sessions)) : "—")")
        print("Cost coverage      \((coverage * 100).formatted(.number.precision(.fractionLength(1))))%")
        if coverage == 0 { print("Detail              Run again with --enrich for timing, token breakdown, and cost estimates.") }
    }

    static func printProjects(_ sessions: [SessionMetric]) {
        for project in Analytics.projects(from: sessions) {
            print([project.name, String(project.sessionCount), String(project.usage.total), MetricFormatters.duration(project.activeRuntime), project.path].joined(separator: "\t"))
        }
    }

    static func printSessions(_ sessions: [SessionMetric], project: String?) {
        let filtered = project.map { value in sessions.filter { $0.projectPath.localizedCaseInsensitiveContains(value) } } ?? sessions
        let date = ISO8601DateFormatter()
        for session in filtered {
            print([date.string(from: session.updatedAt), session.model ?? "Unknown", String(session.usage.total), MetricFormatters.duration(session.activeRuntime), session.projectName, session.displayTitle].joined(separator: "\t"))
        }
    }

    static func printModels(_ sessions: [SessionMetric]) {
        for model in Analytics.models(from: sessions) {
            print([model.model, String(model.sessions), String(model.usage.total), MetricFormatters.currency(model.estimatedCost)].joined(separator: "\t"))
        }
    }

    static func printPeriods(_ sessions: [SessionMetric], granularity value: String) {
        let granularity = PeriodGranularity(rawValue: value) ?? .month
        let formatter = DateFormatter()
        formatter.dateFormat = granularity == .month ? "yyyy-MM" : "yyyy-MM-dd"
        for period in Analytics.periods(from: sessions, granularity: granularity) {
            print([formatter.string(from: period.start), String(period.sessions), String(period.usage.total), MetricFormatters.duration(period.activeRuntime), MetricFormatters.currency(period.estimatedCost)].joined(separator: "\t"))
        }
    }

    static func printSubscription(_ snapshot: SubscriptionSnapshot?) {
        guard let snapshot else {
            print("No subscription quota snapshot was found in recent Codex rollouts.")
            return
        }
        print("Plan               \(snapshot.displayPlan)")
        print("Observed           \(snapshot.observedAt.formatted(date: .abbreviated, time: .standard))")
        for window in snapshot.windows {
            print("\(window.displayName.padding(toLength: 19, withPad: " ", startingAt: 0))\(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% used · resets \(window.resetsAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if let credits = snapshot.credits {
            let value = credits.unlimited ? "Unlimited" : credits.hasCredits ? (credits.balance ?? "Available") : "None"
            print("Credits            \(value)")
        }
        if let reached = snapshot.rateLimitReachedType { print("Limit status       Reached: \(reached)") }
    }

    static func exportJSON(_ sessions: [SessionMetric], output: String?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sessions)
        if let output {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
            print()
        }
    }

    static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func printHelp() {
        print("""
        codex-metrics [summary|projects|sessions|models|periods|subscription|export] [options]

          --codex-home PATH   Read a non-default Codex directory
          --enrich            Scan rollouts for timings and token breakdown (cached; cold scans can be large)
          --project TEXT      Filter sessions by project path
          --limit NUMBER      Limit sessions after filtering (useful for quick enriched checks)
          --by day|week|month Period grouping (default: month)
          --output PATH       Write JSON export to a file

        Costs are API-equivalent estimates, not ChatGPT subscription invoices.
        """)
    }
}
