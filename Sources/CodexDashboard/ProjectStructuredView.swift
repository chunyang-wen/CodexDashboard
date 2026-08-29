import CodexMetricsCore
import SwiftUI

struct ProjectStructuredView: View {
    @EnvironmentObject private var store: DashboardStore
    let project: ProjectMetric
    @State private var selectedWorkflowID: String?
    @State private var selectedNodeID: String?
    @State private var inspectedSessionID: String?
    @State private var fitRequestID = UUID()

    private var graph: SessionGraph? {
        guard store.projectSessionGraphProjectID == project.id else { return nil }
        return store.projectSessionGraph
    }

    private var presentation: SessionGraphPresentation? {
        graph.map { SessionGraphPresentation(graph: $0) }
    }

    private var selectedWorkflow: SessionGraphWorkflow? {
        guard let presentation else { return nil }
        return presentation.workflows.first { $0.id == selectedWorkflowID } ?? presentation.workflows.first
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider()
            if let presentation, !presentation.workflows.isEmpty {
                controlsBar
                Divider()
            }
            contentRegion
            if inspectedSessionID == nil, let selectedNode { selectionBar(selectedNode) }
        }
        .task(id: project.id) {
            selectedNodeID = nil
            inspectedSessionID = nil
            selectedWorkflowID = nil
            store.loadProjectSessionGraph(projectID: project.id)
        }
        .onChange(of: graph) { _, graph in
            selectedNodeID = nil
            inspectedSessionID = nil
            guard let graph else { return }
            let next = SessionGraphPresentation(graph: graph)
            selectedWorkflowID = next.workflows.first?.id
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 12) {
            Image(systemName: project.kind == .standalone ? "tray.full" : "point.3.connected.trianglepath.dotted")
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
                .textSelection(.enabled)
            if let presentation, let graph {
                Text("\(presentation.workflows.count) workflows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if graph.isTruncated {
                    Label("Latest \(graph.requestedLimit)", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                fitRequestID = UUID()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Fit workflow")
            .disabled(selectedWorkflow == nil)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            if let presentation {
                Picker("Workflow", selection: workflowSelection) {
                    ForEach(presentation.workflows) { workflow in
                        Text("\(workflow.title) (\(workflow.nodeCount))")
                            .lineLimit(1)
                            .tag(workflow.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
                if let workflow = selectedWorkflow, workflow.hiddenNodeCount > 0 {
                    Text("\(workflow.hiddenNodeCount) more not shown")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private var workflowSelection: Binding<String> {
        Binding(
            get: { selectedWorkflow?.id ?? "" },
            set: {
                selectedWorkflowID = $0
                selectedNodeID = nil
                inspectedSessionID = nil
            }
        )
    }

    private var contentRegion: some View {
        HStack(spacing: 0) {
            content
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            if let inspectedSessionID {
                Divider()
                sessionInspector(sessionID: inspectedSessionID)
                    .frame(width: 480)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func sessionInspector(sessionID: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session metrics")
                    .font(.headline)
                Spacer()
                Button {
                    inspectedSessionID = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close session metrics")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            SessionDetailLoaderView(
                sessionID: sessionID,
                fallback: project.sessions.first { $0.id == sessionID }
            )
        }
    }

    private func inspectSession(_ sessionID: String) {
        selectedNodeID = sessionID
        inspectedSessionID = sessionID
    }

    @ViewBuilder private var content: some View {
        if presentation != nil {
            if let workflow = selectedWorkflow {
                SessionGraphCanvas(
                    graph: workflow.graph,
                    selectedNodeID: $selectedNodeID,
                    fitRequestID: fitRequestID,
                    onOpenSession: inspectSession
                )
            } else {
                ContentUnavailableView(
                    "No connected workflows",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Sessions without workflow relationships remain available in the expanded project list.")
                )
            }
        } else if let message = store.projectSessionGraphError,
                  store.projectSessionGraphProjectID == project.id {
            ContentUnavailableView {
                Label("Graph unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { store.retryProjectSessionGraph() }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedNode: SessionGraphNode? {
        guard let selectedNodeID else { return nil }
        return graph?.nodes.first { $0.id == selectedNodeID }
    }

    private func selectionBar(_ node: SessionGraphNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: node.kind))
                .foregroundStyle(node.scope == .external ? .orange : .blue)
            Text(node.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .textSelection(.enabled)
            if let model = node.model {
                Text(model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if node.projectPath != nil {
                Button("Show Metrics") { inspectSession(node.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(.background.secondary)
        .overlay(alignment: .top) { Divider() }
    }

    private func iconName(for kind: SessionGraphNodeKind) -> String {
        switch kind {
        case .user: "person.crop.circle"
        case .subagent: "cpu"
        case .automation: "clock.arrow.2.circlepath"
        case .agentCreatedThread: "plus.bubble"
        case .unknown: "questionmark.circle"
        }
    }
}
