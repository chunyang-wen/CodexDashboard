import CodexMetricsCore
import SwiftUI

struct ProjectStructuredView: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            if let presentation, !presentation.workflows.isEmpty {
                workflowToolbar
                Divider()
            }
            contentRegion
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: inspectedSessionID)
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

    private var workflowToolbar: some View {
        HStack(spacing: 10) {
            if let presentation {
                Picker("Workflow", selection: workflowSelection) {
                    ForEach(presentation.workflows) { workflow in
                        Label(workflow.title, systemImage: "point.3.connected.trianglepath.dotted")
                            .tag(workflow.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 300, alignment: .leading)

                if let workflow = selectedWorkflow {
                    Text("\(workflow.nodeCount) \(workflow.nodeCount == 1 ? "session" : "sessions")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if workflow.hiddenNodeCount > 0 {
                        Text("\(workflow.hiddenNodeCount) more not shown")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let graph, graph.isTruncated {
                Label("Latest \(graph.requestedLimit)", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                fitRequestID = UUID()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Fit workflow")
            .accessibilityLabel("Fit workflow")
            .disabled(selectedWorkflow == nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.regularMaterial)
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
                    .frame(width: 440)
                    .frame(maxHeight: .infinity)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
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

}
