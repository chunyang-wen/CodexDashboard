# Project Session Graph — implementation handoff

## Outcome

Add a **Structured** view to the existing Projects tab that organizes Codex sessions by their real runtime relationships. It should not introduce another workflow definition, require users to annotate skills, or add a backend service.

The read-only session graph grows to include:

- nodes are Codex sessions;
- solid edges are parent-to-subagent spawn relationships;
- dashed edges are fork ancestry when it can be recovered;
- dotted edges are cross-agent communication when available;
- opening a resolvable node reaches its existing session detail and conversation inspector;
- a node can expose turns, commands, tool calls, changed files, status, and timing as the data layer grows.

This is feasible with data Codex already writes. The principal limitation is incomplete relationship metadata for older sessions, not the lack of session activity data.

## Product placement

Keep this inside `ProjectsView` rather than adding another top-level sidebar item.

Proposed hierarchy:

```text
Projects
  Project A
    Overview | Structured
                 ├── session root
                 │     ├── spawned subagent
                 │     └── spawned subagent
                 └── forked session
```

The existing project tree remains the project/session browser. When a project is selected, add an `Overview | Structured` picker to the project detail. `Overview` preserves the current metrics UI. `Structured` replaces the detail pane with the session graph for that project.

Do not put a graph under every expanded project row. The repository's current performance findings show that expanding the SwiftUI project tree is already a CPU and memory hotspot. Load and render one selected project's graph in the detail pane only.

## Version 1 contract

The first independently releasable graph slice has these fixed semantics:

- `Overview` remains the default project detail mode.
- `Structured` loads the 100 most recently updated sessions belonging to the selected project's known paths.
- The graph loader queries `state_5.sqlite` directly and does not reuse the project tree's paged session rows.
- Only explicit `thread_spawn_edges` relationships are rendered initially.
- A directly connected endpoint outside the selected project is included as a lightweight external placeholder. Relationship loading stops there and never recursively expands another project.
- Sessions with no recorded relationship appear in an `Unlinked` lane. They are not described as confirmed roots.
- Graph-level truncation is visible whenever more than 100 matching project sessions exist. A node without a recorded parent in a truncated graph is not treated as proof that no parent exists.
- Single-click selects a node. Double-click or Return opens the existing session detail when the node resolves to a local session; unresolved external placeholders remain selected in the graph. Opening detail does not eagerly load conversation content.
- Status is `unknown` in the index-only slice unless the source index contains authoritative status data. Recency must not be presented as running or waiting.
- Fork, communication, rollout reconstruction, activity items, and controls are excluded from this slice.

These defaults are part of the implementation contract, not hidden tuning parameters. A later product change can replace them deliberately.

## Existing code to reuse

The relevant seams already exist:

- `Sources/CodexDashboard/ContentView.swift`
  - `ProjectsView` owns project and session selection.
  - `ProjectDetailLoaderView` is the correct place to switch between overview and structured detail.
  - `SessionDetailLoaderView` already resolves a selected session lazily.
- `Sources/CodexDashboard/DashboardStore.swift`
  - project sessions are paged through `loadProjectSessions` and `loadMoreProjectSessions`;
  - `sessionMetric(withID:)` loads detail on demand.
- `Sources/CodexMetricsCore/CodexStore.swift`
  - reads `state_5.sqlite` with retry/fallback handling;
  - already performs compact, project-scoped, keyset-paginated reads.
- `Sources/CodexMetricsCore/RolloutParser.swift`
  - incrementally parses append-only rollout JSONL;
  - avoids retaining oversized tool results.
- `Sources/CodexMetricsCore/Conversation.swift`
  - loads conversation content directly from one rollout;
  - deliberately does not persist conversation text.
- `Sources/CodexDashboard/CodexSourceWatcher.swift` and `Sources/CodexMetricsCore/CodexSourcePaths.swift`
  - already observe the Codex index and rollout changes.

Preserve the existing privacy boundary: graph metadata may be cached only if necessary, but conversation text, command output, diffs, and raw tool payloads should continue to be loaded on demand and not copied into dashboard history.

## Data available today

### Source index: `state_5.sqlite`

The current Codex index contains session identity and project context in `threads`, including:

- `id`, `rollout_path`, created and updated timestamps;
- `cwd`, title, source, model, and provider;
- Git branch, commit, and remote where available;
- agent nickname, role, and path for newer subagents;
- organization fields such as section, project, archive, and pin state.

It also contains an explicit relationship table:

```sql
CREATE TABLE thread_spawn_edges (
    parent_thread_id TEXT NOT NULL,
    child_thread_id TEXT NOT NULL PRIMARY KEY,
    status TEXT NOT NULL
);
```

This is the preferred source for solid spawn edges.

Newer subagent rows can also encode a structured parent in `threads.source`, conceptually:

```json
{
  "subagent": {
    "thread_spawn": {
      "parent_thread_id": "…",
      "depth": 1,
      "agent_nickname": "…",
      "agent_role": "…"
    }
  }
}
```

Treat this as a fallback when the explicit edge table does not contain the child.

### Turn/item projection: `thread_history_1.sqlite`

The local projection contains:

- turn status, start/completion timestamps, duration, and errors;
- command execution, aggregated output, exit code, duration, and working directory;
- file changes with path, kind, and diff;
- MCP and dynamic tool calls with status and duration;
- collaboration calls with sender and receiver session IDs;
- subagent activity records;
- agent and user messages.

This is enough for a node activity inspector. It is not necessary for the first graph layout, so read it only after the user selects a node or opens an activity panel.

### Rollout JSONL

Rollouts provide the widest backward-compatible evidence:

- `session_meta` and `forked_from_id` for fork ancestry;
- task start, completion, and interruption events;
- plan updates when the agent used a plan;
- tool calls and results;
- messages and reasoning summaries.

Rollouts are the fallback for ancestry and the on-demand source for logs. Do not scan every rollout just to open the Projects tab.

### Live App Server

Official OpenAI documentation describes Codex App Server as the protocol for rich clients, including conversation history and streamed agent events. Its task listing supports ancestry filters, and it streams task/turn/item/status/plan changes. It also supports interruption. This should become the preferred live source once the static graph is working:

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)

The first implementation does not need to launch or manage App Server. Keep the graph source behind a small protocol so a live provider can replace or augment the local-index provider later.

## Coverage observed during investigation

Snapshot from the local Codex installation on 2026-08-29:

- 831 indexed sessions;
- 126 sessions classified as subagents;
- 18 normalized spawn edges;
- 87 automation sessions;
- 37 rollouts with fork ancestry;
- 7,437 command executions;
- 1,162 file-change items;
- 195 collaboration/agent-control calls;
- 477 completed, 56 interrupted, and 6 failed indexed turns.

Only 17 of the 126 classified subagent sessions had a normalized spawn edge. Therefore:

- relationship confidence must be represented explicitly;
- disconnected subagent sessions are expected;
- the UI must never imply that “no recorded edge” means “definitely a root session.”

## Proposed domain model

Keep this model separate from token/usage aggregation.

```swift
public struct SessionGraph: Sendable {
    public let nodes: [SessionGraphNode]
    public let edges: [SessionGraphEdge]
    public let projectNodeCount: Int
    public let requestedLimit: Int
    public let isTruncated: Bool
}

public struct SessionGraphNode: Identifiable, Sendable {
    public let id: String
    public let projectPath: String?
    public let title: String
    public let createdAt: Date?
    public let updatedAt: Date?
    public let kind: SessionGraphNodeKind
    public let scope: SessionGraphNodeScope
    public let status: SessionGraphStatus
    public let model: String?
    public let agentNickname: String?
    public let rolloutPath: String?
}

public struct SessionGraphEdge: Identifiable, Sendable {
    public let id: String
    public let sourceID: String
    public let targetID: String
    public let kind: SessionGraphEdgeKind
    public let confidence: SessionGraphConfidence
}

public enum SessionGraphNodeKind: Sendable {
    case user
    case subagent
    case automation
    case agentCreatedThread
    case unknown
}

public enum SessionGraphNodeScope: Sendable {
    case project
    case external
}

public enum SessionGraphStatus: Sendable {
    case unknown
    case recentlyActive
    case completed
    case interrupted
    case failed
    case running
    case waiting
}

public enum SessionGraphEdgeKind: Sendable {
    case spawn
    case fork
    case communication
}

public enum SessionGraphConfidence: Sendable {
    case explicit       // normalized source edge
    case metadata       // structured session metadata
    case inferred       // rollout/tool-event reconstruction
}
```

Status should degrade gracefully. Version 1 uses `unknown`. Historical sessions may later use completed/interrupted/failed turn status. A genuinely live `running` or `waiting` state should come from App Server when available; otherwise show `recently active` rather than guessing.

## Relationship resolution

Resolve relationships in this order:

1. Use a dedicated, bounded project-scoped query to read the latest project sessions directly from the source index. Do not build the graph from the project tree's 50-row pages.
2. Read `thread_spawn_edges` where either endpoint is in that bounded session set.
3. Hydrate directly connected endpoints as external nodes when they are outside the selected project, then stop traversal.
4. In the metadata milestone, fill missing child-parent edges from structured `threads.source` JSON.
5. Only when the user requests historical reconstruction, inspect relevant rollouts for `forked_from_id` or collaboration events.
6. Deduplicate by `(sourceID, targetID, kind)`, retaining the strongest confidence.

Project membership currently comes from working-directory paths. A child may run in a Codex worktree with a different `cwd`, so strict same-path filtering can hide valid edges. Include directly connected children even when their `cwd` differs, and label them as outside the selected project scope if the project mapping cannot reconcile them.

## Graph layout and interaction

### Initial layout

Use a deterministic layered layout rather than introducing a graph library immediately:

1. Find roots: nodes without an incoming spawn/fork edge.
2. Assign depth using spawn edges first, fork edges second.
3. Sort siblings by creation time, then ID for stability.
4. Place roots vertically and descendants left-to-right by depth.
5. Route communication edges after node placement.

Cycles are possible once communication edges are present. They must not participate in depth calculation. If malformed spawn/fork data forms a cycle, break the weakest-confidence edge for layout only; keep it in the inspector.

### Rendering

Prefer one AppKit-backed drawing surface hosted in SwiftUI, not a large SwiftUI `ForEach` of nodes and edges. The repository already identifies large SwiftUI render trees as a memory/CPU risk.

Minimum interactions:

- click a node to select it;
- double-click or press Return to open existing session detail;
- pan and zoom;
- hover for title, model, time, status, and relationship confidence;
- filters for roots/subagents/automations and edge kinds;
- “Fit” to restore the full graph bounds.

Accessibility should also expose a linear outline representation of the same spawn hierarchy. The canvas alone is not sufficient.

### Node inspector

The first inspector can reuse existing session detail. Later, add tabs:

```text
Summary | Activity | Files | Conversation
```

- **Summary:** status, timing, model, Git/worktree, parents and children.
- **Activity:** turns, commands, and tool calls loaded from the item projection.
- **Files:** changed paths and diffs loaded on demand.
- **Conversation:** existing `ConversationInspectorView`.

Never render full command output or diffs in graph nodes.

## Implementation sequence

Implementation status (August 29, 2026): Milestone 1 is complete for the version 1 contract. The implementation uses the latest 100 indexed project sessions, explicit spawn edges, one-hop external placeholders, deterministic cycle-safe layout, an Unlinked lane, and a native AppKit canvas. Focused model, layout, lifecycle, build, and live UI checks pass. Milestones 2–4 remain deferred until version 1 performance and usability measurements justify expanding the data sources or adding a live provider.

### Milestone 1 — static spawn graph

Deliverable: project detail can switch to a read-only graph based on `threads` and `thread_spawn_edges`.

1. Add graph model types under `CodexMetricsCore`.
2. Add a project-scoped `CodexStore.loadSessionGraph(...)` query.
3. Add `DashboardStore.loadProjectSessionGraph(projectID:)` with cancellation and one selected-project cache.
4. Add the `Overview | Structured` control to project detail.
5. Render roots and spawn descendants with a lightweight AppKit view.
6. Selecting a graph node opens the existing session detail.

Verification:

- explicit edges match direct SQLite queries;
- sessions without relationships still appear in an “Unlinked” group;
- switching projects cancels the previous graph load;
- opening Projects does not scan rollout files;
- graph memory is released when leaving Projects.

### Milestone 2 — metadata and historical relationships

Deliverable: structured parent metadata and fork ancestry appear with confidence styling.

1. Parse structured `threads.source` without failing on plain-string legacy values.
2. Parse `forked_from_id` lazily from only the relevant rollout headers.
3. Add dashed fork edges and confidence labels.
4. Add external/worktree-connected placeholders when required.

Verification:

- malformed JSON source values are ignored;
- explicit edges win over inferred duplicates;
- historical reconstruction is cancellable and bounded;
- no conversation or command content is persisted.

### Milestone 3 — activity inspector

Deliverable: selecting a node can show turn, command, tool, and file-change records.

1. Add a read-only adapter for the available `thread_history_*.sqlite` projection.
2. Query by selected session ID and page items by turn/ordinal.
3. Reuse the existing conversation inspector for message content.
4. Load large command output and diffs only after explicit expansion.

The projection database name and schema are implementation details and may change. Locate compatible candidates and feature-detect tables/columns as `CodexStore` already does for the source index.

### Milestone 4 — live status and controls

Deliverable: active nodes update without polling and can be interrupted.

1. Add an App Server-backed graph event provider.
2. Merge streamed task/turn/item/status changes into the in-memory graph.
3. Add Start/Continue and Interrupt controls only after the live provider owns the task lifecycle.
4. Define Pause as “interrupt the current turn and do not start another turn.” Codex has no separate durable paused workflow state to infer from historical data.

Do not implement controls by writing directly to Codex SQLite databases or rollout files.

## Suggested file boundaries

```text
Sources/CodexMetricsCore/
  SessionGraph.swift
  SessionGraphStore.swift

Sources/CodexDashboard/
  ProjectStructuredView.swift
  SessionGraphCanvas.swift
  SessionGraphInspectorView.swift
```

Avoid expanding `ContentView.swift` further than the picker and routing seam.

## Tests and performance gates

### Core tests

- explicit spawn-edge decoding;
- plain and structured `threads.source` compatibility;
- missing parent/child rows;
- deduplication and confidence precedence;
- roots, disconnected components, and cycle-safe layout;
- cross-worktree child inclusion;
- cancellation during project changes.

### UI tests

- Overview remains the default unless product decides otherwise;
- selection remains stable across graph refreshes;
- node selection reaches existing session detail;
- reduced-motion mode avoids animated graph transitions;
- keyboard and accessibility outline navigation work.

### Resource gates

Measure with the same discipline as the existing memory tests:

- no full rollout scan when the Structured view opens;
- no complete history-item load before node selection;
- bounded graph nodes for very large projects, with a time/range control or component paging if needed;
- no retained graph after leaving Projects;
- compare memory and CPU before and after opening, panning, project switching, and graph teardown.

Disk I/O should be proportional to the selected project and selected node. The graph should not increase the always-running menu-bar process's workload.

## Explicit non-goals

- no new YAML/JSON workflow definition;
- no requirement to modify `SKILL.md`;
- no cloud/backend storage;
- no claim that inferred prose steps are authoritative dependencies;
- no execution engine in the first version;
- no direct mutation of Codex's databases or rollouts;
- no persistent storage of conversations, command output, diffs, or raw tool payloads.

## Post-v1 decisions

1. Should Structured show all project history by default, or a recent time window?
2. Should cross-project/worktree children appear as placeholders or be hidden behind a toggle?
3. Should communication edges be opt-in to avoid visual noise?
4. Should disconnected sessions be a separate lane or independent roots?
5. Once App Server is integrated, should control actions live in this dashboard or remain in Codex?

The version 1 contract fixes the first four choices for the initial slice: the most recent 100 sessions, external children as placeholders, communication edges excluded, and disconnected sessions in an Unlinked lane. Revisit them only after the initial performance and usability measurements. Control actions remain a separate product decision for the App Server milestone.
