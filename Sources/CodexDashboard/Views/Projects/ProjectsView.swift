import Charts
import CodexMetricsCore
import SwiftUI

private enum ProjectTreeSelection: Hashable {
    case project(String)
    case session(String)
}

struct ProjectsView: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DashboardPreferences.projectActivityMetricKey, store: DashboardPreferences.sharedDefaults()) private var activityMetric = "Tokens"
    @State private var expandedProjects = Set<String>()
    @State private var selection: ProjectTreeSelection?
    @State private var searchText = ""

    private var visibleProjects: [ProjectMetric] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.allProjects }
        return store.allProjects.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleProjectGroups: [ProjectMetric] {
        visibleProjects.filter { $0.kind == .project }
    }

    private var visibleStandaloneGroups: [ProjectMetric] {
        visibleProjects.filter { $0.kind == .standalone }
    }

    private var duplicateProjectNames: Set<String> {
        Set(
            Dictionary(
                grouping: store.allProjects.filter { $0.kind == .project },
                by: { $0.name.lowercased() }
            )
                .filter { $0.value.count > 1 }
                .keys
        )
    }

    var body: some View {
        HSplitView {
            projectTree
                .frame(minWidth: 300, idealWidth: 390, maxWidth: 500)
            selectedDetail
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Projects")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search projects")
        .onDisappear {
            selection = nil
            expandedProjects.removeAll()
        }
        .frame(minWidth: 800, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectTree: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                if !visibleProjectGroups.isEmpty {
                    treeSectionHeader("Projects")
                    ForEach(visibleProjectGroups) { project in projectEntry(project) }
                }
                if !visibleStandaloneGroups.isEmpty {
                    treeSectionHeader("Standalone")
                        .padding(.top, visibleProjectGroups.isEmpty ? 0 : 8)
                    ForEach(visibleStandaloneGroups) { project in projectEntry(project) }
                }
            }
            .padding(10)
        }
        .background(.background.secondary)
        .overlay(alignment: .top) {
            if store.isLoadingSessionHierarchy {
                VStack(spacing: 10) {
                    ActivityIndicator(size: 24)
                    Text("Loading projects…")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)
            } else if store.allProjects.isEmpty {
                ContentUnavailableView(
                    "No projects",
                    systemImage: "folder",
                    description: Text("No Codex projects or sessions are available yet.")
                )
            } else if visibleProjects.isEmpty {
                ContentUnavailableView(
                    "No matching projects",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different project name.")
                )
            }
        }
    }

    @ViewBuilder private var selectedDetail: some View {
        switch selection {
        case .project(let projectID):
            if let project = store.allProjects.first(where: { $0.id == projectID }) {
                let rangedSessions = project.sessions
                ProjectDetailLoaderView(
                    project: project,
                    rangedSessions: rangedSessions,
                    rangeLabel: "All time",
                    granularity: store.range.granularity,
                    pricing: store.pricing,
                    activityMetric: $activityMetric,
                ) { sessionID in
                    expandedProjects.insert(project.id)
                    selection = .session(sessionID)
                }
            } else { selectionPlaceholder }
        case .session(let id):
            SessionDetailLoaderView(
                sessionID: id,
                fallback: store.allProjects.flatMap(\.sessions).first { $0.id == id }
            )
        case nil:
            selectionPlaceholder
        }
    }

    private var selectionPlaceholder: some View {
        ContentUnavailableView("Select a project", systemImage: "folder", description: Text("Expand a project to browse the sessions that belong to it."))
    }

    private func treeSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    private func selectProject(_ project: ProjectMetric) {
        selection = .project(project.id)
        store.loadProjectSessions(projectID: project.id)
    }

    private func selectSession(_ session: SessionSummary) {
        selection = .session(session.id)
    }

    @ViewBuilder private func projectEntry(_ project: ProjectMetric) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 7) {
                Button { toggle(project.id) } label: {
                    Image(systemName: expandedProjects.contains(project.id) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 16, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expandedProjects.contains(project.id) ? "Collapse \(project.name)" : "Expand \(project.name)")

                Button {
                    selectProject(project)
                } label: {
                    ProjectTreeRow(
                        project: project,
                        showsPath: duplicateProjectNames.contains(project.name.lowercased())
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selection == .project(project.id) ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7))

            if expandedProjects.contains(project.id) {
                LazyVStack(spacing: 2) {
                    ForEach(project.sessions) { session in
                        Button {
                            selectSession(session)
                        } label: {
                            SessionTreeRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 31)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3)
                        .background(selection == .session(session.id) ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .onAppear {
                            guard session.id == project.sessions.last?.id else { return }
                            store.loadMoreProjectSessions(projectID: project.id)
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func toggle(_ projectID: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            if expandedProjects.contains(projectID) {
                expandedProjects.remove(projectID)
                guard let project = store.allProjects.first(where: { $0.id == projectID }) else { return }
                switch selection {
                case .project(let id) where id == project.id:
                    selection = nil
                case .session(let sessionID) where project.sessions.contains(where: { $0.id == sessionID }):
                    selection = nil
                default:
                    break
                }
            } else {
                expandedProjects.insert(projectID)
                store.loadProjectSessions(projectID: projectID)
            }
        }
    }

}

private struct ProjectDetailLoaderView: View {
    @EnvironmentObject private var store: DashboardStore
    let project: ProjectMetric
    let rangedSessions: [SessionSummary]
    let rangeLabel: String
    let granularity: PeriodGranularity
    let pricing: PricingHistory
    @Binding var activityMetric: String
    let onSelectSession: (String) -> Void
    @State private var detailMode = ProjectDetailMode.overview
    @State private var indexed: SQLProjectAggregate?
    @State private var periods: [PeriodMetric] = []
    @State private var sessionIndexes: [String: IndexedSessionCost] = [:]

    private var summaryAggregate: SQLProjectAggregate {
        let estimatedCost = project.sessions.reduce(Decimal.zero) { total, session in
            total + (pricing.estimate(usage: session.usage, model: session.model, serviceTier: session.serviceTier, on: session.updatedAt) ?? 0)
        }
        return SQLProjectAggregate(
            usage: project.usage,
            estimatedCost: estimatedCost,
            costCoverage: estimatedCost > 0 ? 1 : 0,
            activeRuntime: project.activeRuntime,
            toolCalls: project.sessions.reduce(0) { $0 + $1.toolCalls },
            skillCalls: project.sessions.reduce(0) { $0 + $1.skillCalls },
            activeDays: project.activeDays,
            medianTurnDuration: nil,
            p95TurnDuration: nil,
            averageFirstTokenTime: nil,
            tools: [],
            skills: []
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Project detail", selection: $detailMode) {
                Label("Overview", systemImage: "chart.xyaxis.line").tag(ProjectDetailMode.overview)
                Label("Structured", systemImage: "point.3.connected.trianglepath.dotted").tag(ProjectDetailMode.structured)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.vertical, 10)

            Divider()

            switch detailMode {
            case .overview:
                ProjectDetailView(
                    project: project,
                    rangedSessions: rangedSessions,
                    rangeLabel: rangeLabel,
                    granularity: granularity,
                    pricing: pricing,
                    indexed: indexed ?? summaryAggregate,
                    periods: periods,
                    activityMetric: $activityMetric,
                    sessionIndexes: sessionIndexes,
                    onSelectSession: { onSelectSession($0.id) }
                )
                .task(id: "\(project.path)-\(granularity.rawValue)") {
                    indexed = nil
                    periods.removeAll()
                    sessionIndexes.removeAll()
                    let aggregate = await store.loadProjectAggregate(paths: project.paths)
                    guard !Task.isCancelled else { return }
                    indexed = aggregate

                    let visibleSessions = project.sessions.prefix(8)
                    let visibleIDs = Set(visibleSessions.map(\.id))
                    async let periodRows = store.projectPeriods(paths: project.paths, granularity: granularity)
                    async let indexedCosts = store.indexedSessionCosts(projectPaths: project.paths, sessionIDs: visibleIDs)

                    let allCosts = await indexedCosts
                    let costs = allCosts.filter { visibleIDs.contains($0.key) }
                    let loadedPeriods = await periodRows
                    guard !Task.isCancelled else { return }
                    sessionIndexes = costs
                    periods = loadedPeriods
                }
            case .structured:
                ProjectStructuredView(project: project)
            }
        }
    }
}

private enum ProjectDetailMode: Hashable {
    case overview
    case structured
}

struct SessionDetailLoaderView: View {
    @EnvironmentObject private var store: DashboardStore
    let sessionID: String
    let fallback: SessionSummary?
    @State private var session: SessionMetric?

    private var fallbackMetric: SessionMetric? {
        guard let fallback else { return nil }
        let completedTurns = Array(repeating: true, count: fallback.completedTurns)
        let abortedTurns = Array(repeating: false, count: fallback.abortedTurns)
        let turns = (completedTurns + abortedTurns).map { completed in
            TurnMetric(
                completedAt: fallback.updatedAt,
                duration: fallback.completedTurns > 0 ? fallback.activeRuntime / Double(fallback.completedTurns) : 0,
                timeToFirstToken: fallback.averageTTFT,
                completed: completed
            )
        }
        return SessionMetric(
            id: fallback.id,
            rolloutPath: fallback.rolloutPath,
            projectPath: fallback.projectPath,
            title: fallback.title,
            source: fallback.source,
            originator: fallback.originator,
            provider: fallback.provider,
            createdAt: fallback.createdAt,
            updatedAt: fallback.updatedAt,
            model: fallback.model,
            reasoningEffort: fallback.reasoningEffort,
            serviceTier: fallback.serviceTier,
            gitBranch: fallback.gitBranch,
            cliVersion: fallback.cliVersion,
            archived: fallback.archived,
            usage: fallback.usage,
            turns: turns,
            toolCalls: fallback.toolCalls,
            userMessages: fallback.userMessages,
            abortedTurns: fallback.abortedTurns,
            subscription: fallback.subscription,
            enrichmentAvailable: fallback.enrichmentAvailable
        )
    }

    var body: some View {
        Group {
            if let session = session ?? fallbackMetric {
                SessionDetailView(
                    session: session,
                    displayTitle: fallback?.displayTitle ?? session.displayTitle,
                    pricing: store.pricing
                )
            } else {
                ContentUnavailableView("Session Not Found", systemImage: "bubble.left.and.text.bubble.right", description: Text("The selected session could not be retrieved from history."))
            }
        }
        .task(id: sessionID) {
            session = nil
            let loaded = try? await store.sessionMetric(withID: sessionID)
            guard !Task.isCancelled else { return }
            if let loaded { session = loaded }
        }
    }
}

private struct ProjectTreeRow: View {
    let project: ProjectMetric
    let showsPath: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: project.kind == .standalone ? "tray.full.fill" : "folder.fill")
                .foregroundStyle(project.kind == .standalone ? Color.secondary : Color.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if showsPath {
                    Text(project.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("\(project.sessionCount) sessions · \(MetricFormatters.compactNumber(project.usage.total)) tokens · \((project.usage.cacheHitRate * 100).formatted(.number.precision(.fractionLength(1))))% cache hit")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(MetricFormatters.age(since: project.lastActivity)).font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct SessionTreeRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(session.model ?? "Unknown") · \(MetricFormatters.compactNumber(session.usage.total)) tokens · \((session.usage.cacheHitRate * 100).formatted(.number.precision(.fractionLength(1))))% cache hit")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(MetricFormatters.age(since: session.updatedAt)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct ProjectDetailView: View {
    let project: ProjectMetric
    let rangedSessions: [SessionSummary]
    let rangeLabel: String
    let granularity: PeriodGranularity
    let pricing: PricingHistory
    let indexed: SQLProjectAggregate
    let periods: [PeriodMetric]
    @Binding var activityMetric: String
    let sessionIndexes: [String: IndexedSessionCost]
    let onSelectSession: (SessionSummary) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: project.kind == .standalone ? "tray.full.fill" : "folder.fill")
                            .foregroundStyle(project.kind == .standalone ? Color.secondary : Color.blue)
                        Text(project.name)
                            .font(.largeTitle.weight(.semibold))
                            .textSelection(.enabled)
                    }
                    if project.kind == .standalone {
                        Text("Sessions without a recognized project root · \(project.paths.count) working folders")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(project.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    MetricCard(title: "Sessions", value: project.sessionCount.formatted(), detail: "\(rangedSessions.count) in \(rangeLabel)", icon: "bubble.left.and.text.bubble.right.fill", tint: .blue)
                    MetricCard(title: "Tokens", value: MetricFormatters.compactNumber(indexed.usage.total), detail: "\((indexed.usage.cacheHitRate * 100).formatted(.number.precision(.fractionLength(1))))% cached · \(rangeLabel)", icon: "text.word.spacing", tint: .purple, definition: .totalTokens)
                    MetricCard(title: "Cache hit rate", value: indexed.usage.cacheHitRate.formatted(.percent.precision(.fractionLength(1))), detail: "Cached input / total input · \(rangeLabel)", icon: "arrow.triangle.2.circlepath", tint: .teal, definition: .cacheHitRate)
                    MetricCard(title: "Agent runtime", value: MetricFormatters.duration(indexed.activeRuntime), detail: "Completed turns · \(rangeLabel)", icon: "clock.fill", tint: .orange, definition: .agentRuntime)
                    MetricCard(title: "Equivalent cost", value: indexed.costCoverage > 0 ? MetricFormatters.currency(indexed.estimatedCost) : "—", detail: "\((indexed.costCoverage * 100).formatted(.number.precision(.fractionLength(0))))% coverage · \(rangeLabel)", icon: "dollarsign", tint: .green, definition: .estimatedCost)
                    ToolCallsMetricCard(calls: indexed.toolCalls, tools: indexed.tools, detail: "\(indexed.tools.count) tools · \(rangeLabel)")
                    SkillCallsMetricCard(calls: indexed.skillCalls, skills: indexed.skills, detail: "\(indexed.skills.count) skills · \(rangeLabel)")
                }
                ActivityChart(periods: periods, granularity: granularity, metric: $activityMetric)
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Recent sessions", subtitle: "Sessions stay scoped to this project.")
                    ForEach(project.sessions.prefix(8)) { session in
                        Button { onSelectSession(session) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(session.model ?? "Unknown") · \(session.completedTurns) turns · \(MetricFormatters.duration(session.activeRuntime))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(MetricFormatters.compactNumber(session.usage.total)).monospacedDigit()
                                    Text(session.usage.cacheHitRate.formatted(.percent.precision(.fractionLength(1))) + " cache hit")
                                        .font(.caption).foregroundStyle(.teal).monospacedDigit()
                                    let sessionCost = sessionIndexes[session.id]?.estimatedCost
                                        ?? (pricing.estimate(usage: session.usage, model: session.model, serviceTier: session.serviceTier, on: session.updatedAt) ?? 0)
                                    let sessionCoverage = sessionIndexes[session.id].map { indexed in
                                        indexed.totalTokens > 0 ? Double(indexed.coveredTokens) / Double(indexed.totalTokens) : 0
                                    } ?? (pricing.price(for: session.model, on: session.updatedAt) != nil ? 1.0 : 0.0)
                                    Text(sessionCoverage > 0 ? MetricFormatters.preciseCurrency(sessionCost) : "Cost —")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(11).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(26)
        }
    }
}

struct SessionDetailView: View {
    let session: SessionMetric
    let displayTitle: String
    let pricing: PricingHistory
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dashboardConversationOpenAction) private var dashboardConversationOpenAction
    @State private var showsFullTitle = false
    private var cost: Decimal { Analytics.totalEstimatedCost([session], pricing: pricing) }
    private var coverage: Double { Analytics.costCoverage([session], pricing: pricing) }
    private var tools: [ToolMetric] { Analytics.tools(from: [session], pricing: pricing) }
    private var skills: [SkillMetric] { Analytics.skills(from: [session], pricing: pricing) }
    private var hasLongTitle: Bool {
        displayTitle.count > 120 || displayTitle.filter { $0.isNewline }.count > 1
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        sessionTitle
                        Label(session.projectName, systemImage: "folder.fill").font(.subheadline.weight(.medium)).foregroundStyle(.blue)
                        Text(session.projectPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        let request = ConversationWindowRequest(
                            rolloutPath: session.rolloutPath,
                            sessionTitle: displayTitle,
                            projectName: session.projectName
                        )
                        if let dashboardConversationOpenAction {
                            dashboardConversationOpenAction.open(request)
                        } else {
                            openWindow(value: request)
                        }
                    } label: {
                        Label("Debug Conversation", systemImage: "waveform.path.ecg.text")
                    }
                    .buttonStyle(.bordered)
                    .help("Open sent and received conversation events in a separate window")
                    .disabled(session.rolloutPath.isEmpty)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    MetricCard(title: "Tokens", value: MetricFormatters.compactNumber(session.usage.total), detail: "\(MetricFormatters.compactNumber(session.usage.output)) output", icon: "text.word.spacing", tint: .purple, definition: .totalTokens)
                    MetricCard(title: "Agent runtime", value: MetricFormatters.duration(session.activeRuntime), detail: "\(session.completedTurns) completed turns", icon: "clock.fill", tint: .orange, definition: .agentRuntime)
                    MetricCard(title: "Session span", value: MetricFormatters.duration(session.sessionSpan), detail: "Includes idle gaps", icon: "calendar.badge.clock", tint: .blue, definition: .sessionSpan)
                    MetricCard(title: "First token", value: session.averageTTFT.map(MetricFormatters.duration) ?? "—", detail: "Average startup latency", icon: "bolt.fill", tint: .yellow, definition: .firstTokenLatency)
                    MetricCard(title: "Equivalent cost", value: coverage > 0 ? MetricFormatters.preciseCurrency(cost) : "—", detail: "\((coverage * 100).formatted(.number.precision(.fractionLength(0))))% token coverage", icon: "dollarsign", tint: .green, definition: .estimatedCost)
                    ToolCallsMetricCard(calls: session.toolCalls, tools: tools, detail: "\(tools.count) tools · click for cost")
                    SkillCallsMetricCard(calls: session.skillCallEvents?.count ?? 0, skills: skills, detail: "\(skills.count) skills · click for cost")
                }
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Token composition", subtitle: "Input is split into uncached, cached, and cache-write tokens; reasoning is a subset of output.", definition: .tokenComposition)
                    TokenCompositionView(usage: session.usage)
                }
                .padding(18).background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 11) {
                    metadata("Model", session.model ?? "Unknown")
                    metadata("Reasoning effort", session.reasoningEffort ?? "Unknown")
                    metadata("Service tier", session.serviceTier ?? "Default")
                    metadata("Source", session.displaySource)
                    metadata("Git branch", session.gitBranch ?? "—")
                    metadata("Aborted turns", session.abortedTurns.formatted())
                    metadata("Created", session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    metadata("Updated", session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .padding(26)
        }
    }

    @ViewBuilder private var sessionTitle: some View {
        if hasLongTitle {
            Button { showsFullTitle = true } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    Text(displayTitle).lineLimit(2)
                }
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsFullTitle) {
                ScrollView {
                    Text(displayTitle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
                .frame(width: 520, height: 260)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                Text(displayTitle).textSelection(.enabled)
            }
            .font(.title.weight(.semibold))
        }
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

}

private struct TokenCompositionSegment: Identifiable {
    let id: String
    let title: String
    let value: Int64
    let color: Color
}

private struct TokenCompositionView: View {
    let usage: TokenUsage

    private var inputSegments: [TokenCompositionSegment] {
        [
            .init(id: "uncached", title: "Uncached", value: usage.uncachedInput, color: .blue),
            .init(id: "cached", title: "Cached", value: usage.cachedInput, color: .cyan),
            .init(id: "cache-write", title: "Cache write", value: usage.cacheWriteInput, color: .orange)
        ]
    }

    private var outputSegments: [TokenCompositionSegment] {
        [
            .init(id: "output", title: "Output", value: usage.output, color: .purple),
            .init(id: "reasoning", title: "Reasoning", value: usage.reasoningOutput, color: .pink)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TokenCompositionGroup(
                title: "INPUT",
                total: usage.input,
                grandTotal: usage.total,
                segments: inputSegments,
                showsNestedLegend: false
            )
            TokenCompositionGroup(
                title: "OUTPUT",
                total: usage.output,
                grandTotal: usage.total,
                segments: outputSegments,
                showsNestedLegend: true
            )
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TokenCompositionGroup: View {
    let title: String
    let total: Int64
    let grandTotal: Int64
    let segments: [TokenCompositionSegment]
    let showsNestedLegend: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(MetricFormatters.compactNumber(total)) tokens · \(percentage(total, of: grandTotal)) of total")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if showsNestedLegend {
                NestedTokenBar(total: total, nested: segments.last?.value ?? 0, baseColor: segments.first?.color ?? .purple, nestedColor: segments.last?.color ?? .pink)
                TokenNestedLegend(segment: segments.last ?? .init(id: "reasoning", title: "Reasoning", value: 0, color: .pink), percentage: fraction(segments.last?.value ?? 0, of: total))
            } else {
                SegmentedTokenBar(segments: segments, total: total)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: segments.count),
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(segments) { segment in
                        TokenCompositionLegend(segment: segment, percentage: fraction(segment.value, of: total))
                    }
                }
            }
        }
    }

    private func percentage(_ value: Int64, of denominator: Int64) -> String {
        guard denominator > 0 else { return "—" }
        return (Double(value) / Double(denominator)).formatted(.percent.precision(.fractionLength(1)))
    }

    private func fraction(_ value: Int64, of denominator: Int64) -> Double {
        guard denominator > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(denominator)))
    }
}

private struct SegmentedTokenBar: View {
    let segments: [TokenCompositionSegment]
    let total: Int64

    var body: some View {
        GeometryReader { proxy in
            let gap = CGFloat(max(0, segments.count - 1))
            let availableWidth = max(0, proxy.size.width - gap)
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(segment.color.gradient)
                        .frame(width: availableWidth * fraction(segment.value), height: 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 28)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.separator.opacity(0.38)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Segmented token bar")
        .accessibilityValue(segments.map { "\($0.title) \($0.value)" }.joined(separator: ", "))
    }

    private func fraction(_ value: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(total)))
    }
}

private struct NestedTokenBar: View {
    let total: Int64
    let nested: Int64
    let baseColor: Color
    let nestedColor: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(baseColor.gradient)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(nestedColor.gradient)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 28)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.separator.opacity(0.38)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Output bar with reasoning subset")
        .accessibilityValue("Output \(total) tokens, reasoning \(nested) tokens")
    }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(nested) / Double(total)))
    }
}

private struct TokenNestedLegend: View {
    let segment: TokenCompositionSegment
    let percentage: Double

    var body: some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(segment.color.opacity(0.55))
                .frame(width: 18, height: 1)
            Circle()
                .fill(segment.color)
                .frame(width: 7, height: 7)
            Text("\(segment.title): \(MetricFormatters.compactNumber(segment.value)) · \(percentage.formatted(.percent.precision(.fractionLength(1)))) output")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle()
                .fill(segment.color.opacity(0.55))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TokenCompositionLegend: View {
    let segment: TokenCompositionSegment
    let percentage: Double

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(segment.color)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(MetricFormatters.compactNumber(segment.value)) · \(percentage.formatted(.percent.precision(.fractionLength(1))))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
