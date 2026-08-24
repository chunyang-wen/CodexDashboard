# Dashboard Process Separation Plan

## Objective

Keep the menu-bar host lightweight and move all dashboard-only UI, Charts,
session data, analytics, and allocator churn into an embedded helper app. When
the last dashboard-owned window closes, the helper process exits and macOS
reclaims all of its memory.

No milestone is complete until its measurable acceptance checks pass. The
installed, signed app in `/Applications` is the final source of truth for
launch, activation, Dock-icon, window, crash, and memory behavior.

## Non-negotiable behavior

- The first application launch opens exactly one dashboard.
- Closing the dashboard leaves the menu-bar host running.
- Open Dashboard focuses an existing dashboard or starts exactly one helper.
- No blank splash, transient window, generic document icon, duplicate Dock
  icon, helper Dock icon, or hidden restored dashboard window.
- Projects, sessions, charts, aggregation controls, settings, refresh,
  conversation windows, updater commands, and product-level Quit continue to
  work.
- A helper crash must not crash or wedge the menu-bar host.
- The helper remains alive while any dashboard-owned auxiliary window remains
  visible; it exits after the last such window closes.

## Target architecture

```text
CodexDashboard.app (persistent menu-bar host)
|- compact quota/menu-bar data only
|- settings and Sparkle updater
|- owns the single visible Dock icon
`- launches/focuses Contents/Helpers/CodexDashboardUI.app
   |- dashboard SwiftUI and Charts
   |- DashboardStore, analytics, indexing, source watcher
   |- project/session/conversation windows
   `- terminates after its last window closes
```

The helper is an embedded, signed `.app`, launched with
`NSWorkspace.openApplication`. Its executable must never be launched directly
with `Process`, and it must never be opened as a document.

## IPC trust model and lifecycle authentication

The lifecycle channel uses `DistributedNotificationCenter` for small routing
messages. Notification names are global, and any local process can post a
notification with arbitrary user information. The launch token is passed in
the helper's launch arguments, which are also visible to local process
inspection. Neither the notification names nor the launch arguments are a
security boundary; the launch token is a per-launch correlation value and must
not be treated as a secret, credential, or proof of code identity.

The current implementation is deliberately an authenticated-cooperating-
process protocol. The host creates a fresh token and generation for each
launch. Both sides include the following values in lifecycle messages, and the
host accepts a message only when they match the currently tracked launch:

- the launch token;
- the host PID;
- the helper PID; and
- the launch generation.

The host also records the helper's `NSWorkspace` process identity. Termination
events are accepted only for the tracked PID and matching launch date when
available, or for the expected embedded helper bundle URL when the PID is not
already known. This prevents an unrelated process or a stale process reusing a
PID from being treated as the dashboard helper. The helper performs the
corresponding token, host-PID, target-PID, and generation checks before acting
on host commands.

Stale and out-of-state messages are rejected: ready is accepted only while a
launch is in progress; commands are accepted only in the ready state for the
current helper PID; and token, PID, and generation mismatches are ignored.
Abandoned launch tokens are retained long enough to terminate a late launch
completion rather than binding it to a newer generation. The host has one
lifecycle-bus observer, owned by `DashboardProcessCoordinator`; `AppDelegate`
receives only the coordinator's already-validated helper-command callback.

Lifecycle behavior is bounded even when a notification is lost. Startup and
ready-handshake phases each have a 10-second deadline, host-initiated helper
termination has a 2-second completion fallback, and both processes retain a
5-second liveness fallback alongside `NSWorkspace` termination notifications.
For product quit, the host sends the authenticated `quitProduct` command. The
helper sets `isTerminatingForHost`, posts the authenticated
`quitAcknowledged` command, and then calls `NSApp.terminate`. The coordinator
accepts a matching `quitAcknowledged` message and calls `runtime.terminate` for
the helper; its two-second termination fallback still completes the lifecycle
if the acknowledgement or termination event is lost. `helperClosing` remains
the helper's acknowledgement for its normal last-owned-window close path, not
a security assertion.

This is an intentional threat-model decision for a personal menu-bar app: a
hostile local process is out of scope, and these checks are routing and stale-
message mitigations rather than authorization. Supporting a hostile-local-
process threat model would require a protected IPC boundary, such as an XPC
service/connection with peer audit-token and code-signing identity checks (and
possibly authenticated per-connection state), instead of relying on global
distributed notifications and visible launch arguments. That redesign is out
of scope for this process separation.

## Resource tradeoffs

- Closed-dashboard memory should fall to the untouched menu-host baseline.
- `vmmap -summary` physical footprint is the primary process-memory metric.
  `ps` RSS is retained as a secondary diagnostic only; summing RSS for the
  host and `Contents/Helpers/CodexDashboardUI.app` can double-count shared
  framework pages and must not be presented as physical memory.
- Open-state evidence records separate `host/open` and `helper/open`
  physical-footprint samples, plus RSS and any private/shared indicators that
  the installed `vmmap` exposes. A per-process physical-footprint sum may be
  reported as a diagnostic, but it is not a whole-system physical-memory
  total. If an open-state budget is adopted, it must be expressed in those
  separate `vmmap` measurements rather than summed RSS.
- Reopening the dashboard incurs a cold-start CPU and disk-I/O cost. The helper
  must not be prewarmed because that would retain the memory this design is
  intended to reclaim.

## Milestone 1 - Characterize and lock current behavior

Add regression coverage and a repeatable installed-app checklist before moving
any UI to another target.

Acceptance checks:

- Existing unit tests and Xcode build pass.
- Automated tests cover launch-request deduplication and current store memory
  residency expectations where possible.
- A written baseline records first launch, close, reopen, settings, updater,
  Quit, project/session windows, Dock behavior, and `vmmap` measurements.
- No production behavior changes in this milestone.

## Milestone 2 - Extract the lightweight menu-bar boundary

Create a `MenuBarStore` containing only subscription, compact popover metrics,
account, banked-reset, and preference state. The current single-process app must
continue to behave identically at this stage.

The persistent boundary may not own full sessions, dashboard analytics,
project/session detail, source watchers, or dashboard refresh tasks.

Acceptance checks:

- All pre-existing behavior and tests pass.
- Menu-only tests prove no full session or dashboard index is loaded.
- Existing dashboard interactions still pass before process separation.
- Memory benchmark remains no worse than the current build.

## Milestone 3 - Add and validate the embedded helper target

Add the `CodexDashboardUI` application target:

- Bundle ID `com.chunyangwen.CodexDashboard.DashboardUI`.
- Embedded at `CodexDashboard.app/Contents/Helpers/CodexDashboardUI.app`.
- `LSUIElement = true`, no document declarations, no Sparkle, no menu-bar item,
  no settings scene, and no automatic state-restored windows.
- Embedded with `CodeSignOnCopy` and its required framework/resources.

Use AppKit for deterministic helper process/window lifecycle and host the
existing SwiftUI dashboard with `NSHostingController`.

Acceptance checks:

- Debug and Release builds contain a valid nested `.app` bundle.
- `codesign --verify --deep --strict` passes for an archive/export build.
- The helper can be launched only as an application and creates one expected
  dashboard window.
- The helper creates no Dock or document icon and no blank/extra window.
- Closing its last window terminates its PID.

## Milestone 4 - Add the host process coordinator

Implement a coordinator with explicit states:

```text
stopped -> launching -> ready -> terminating -> stopped
```

It must deduplicate launch requests, focus a running helper, observe launch and
termination through `NSWorkspace`, use a launch-token ready handshake, recover
from crashes/timeouts, terminate the helper with the product, and prevent an
orphan helper if the host disappears.

Only small lifecycle commands cross the process boundary: ready, open settings,
check for updates, and quit product. Analytics/session data never crosses it.

Acceptance checks:

- Unit tests cover launch, focus, rapid duplicate requests, launch timeout,
  stale termination, helper crash, host quit, and successful relaunch.
- Ten rapid Open Dashboard requests produce one helper and one window.
- Force-killing the helper leaves the host usable and allows a clean reopen.
- Quitting the host leaves no helper process.

## Milestone 5 - Move dashboard ownership and preserve activation

Move dashboard views, Charts, `DashboardStore`, analytics, source watcher, and
dashboard-owned auxiliary windows exclusively to the helper target.

The host retains the correct Codex Dashboard Dock icon while the helper is
alive. The helper remains an agent app with no Dock icon. Reopening the host
from its Dock icon forwards focus to the helper. Once the helper exits, the host
returns to accessory mode when the menu-bar icon is enabled.

Replace `InitialDashboardOpener` with exactly one coordinator request after host
launch. Preserve the first-launch dashboard contract.

Acceptance checks:

- Clean launch opens one dashboard exactly once.
- Close, reopen, minimize, focus, Settings, Check for Updates, Refresh, Cmd-Q,
  project/session navigation, charts, and conversation windows match baseline.
- Rapid reopen and helper-crash recovery pass.
- At every point there is at most one correct Dock icon and never a generic,
  document, or helper icon.
- No splash, blank window, hidden restored window, or focus flicker is observed.

## Milestone 6 - Remove the in-process dashboard path

After helper integration is proven, remove the dashboard Window scene and all
dashboard/Charts source membership from the persistent target. Do not ship an
in-process fallback because retaining it undermines the memory boundary.

Use an explicit shared preferences suite, migrating existing preference keys.
Pass launch-critical values such as the Codex data path directly to the helper
so stale preferences cannot prevent a launch.

Acceptance checks:

- Host target does not link Charts and cannot instantiate dashboard types.
- Host `heap` contains no `SessionSummary`, `ToolMetric`, `ModelMetric`, metrics
  index, `ContentView`, or Charts render tree after helper close.
- Preference migration and cross-process settings tests pass.
- SQLite WAL concurrency tests show host bounded reads and helper writes do not
  corrupt, block, or duplicate indexing work.

## Milestone 7 - Installed-app regression and memory release gate

Build, sign, install, and test the actual `/Applications` bundle.

Required scenarios:

1. Clean launch and first dashboard presentation.
2. Close and reopen for 20 cycles.
3. Ten rapid Open Dashboard clicks.
4. Force-kill helper and reopen.
5. Quit host while helper is open.
6. Menu icon enabled and disabled.
7. Settings, updater, keyboard commands, all dashboard tabs, timeframe changes,
   chart movement, project/session expansion, scrolling, and conversation
   windows.

Final measurable gates:

- Helper PID disappears within two seconds after its last window closes.
- No orphan helper remains after host exit.
- Host physical footprint after helper exit is within 5 MB of its pre-helper
  baseline on every one of 20 cycles and does not show a sustained upward
  trend across those cycles. The installed gate uses the average of the first
  and last five closed-host samples; the last window may be at most 1 MB above
  the first window to allow normal measurement noise.
- The open state has distinguishable `host/open` and `helper/open` physical-
  footprint samples. Any optional open-state budget is evaluated against those
  `vmmap` values; RSS is never treated as the combined physical-memory value.
- `vmmap` shows no Charts/dashboard residency in the host.
- `heap` shows no dashboard data types in the host.
- All Swift tests and Debug/Release Xcode builds pass.
- No crash, missing dashboard, splash, blank/duplicate window, generic document
  icon, or duplicate Dock icon occurs.

## Orchestration rule

Implement milestones strictly in order. A milestone may be revised by the
orchestrator or returned to its worker if any acceptance check fails. Do not
start the next milestone until the current milestone's tests, diff review, and
measurable results are recorded as passing.
