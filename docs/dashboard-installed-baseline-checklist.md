# Installed Dashboard Baseline Checklist

This is the Milestone 1 installed-app baseline for the process-separation
plan. It records current behavior before any process separation. Run it against
the signed app at `/Applications/CodexDashboard.app`, not an Xcode preview or
the Swift package executable.

The rows marked **manual** require visual or interactive observation. The
sampler is objective but only samples the process that is already running; it
does not launch, terminate, install, or modify an app.

## Run metadata

Record these before the first launch:

| Field | Value |
| --- | --- |
| Date/time and macOS version | |
| Installed app path | `/Applications/CodexDashboard.app` |
| App version/build | |
| Git revision used for the installed build | |
| Data directory / fixture profile | |
| Display scaling and attached displays | |

If the app was not built from the current revision, record the installed build
identity rather than assuming it matches the checkout.

## Baseline scenarios

For each row, record the observation, timestamp, and any PID/window count in a
test note. A pass means the stated expected result was observed; do not infer a
pass from a command alone.

| ID | Check | Procedure | Record / expected result |
| --- | --- | --- | --- |
| L1 **manual** | First launch | With no Codex Dashboard process running, launch the installed app once from Finder or the Dock. | Record launch time, host PID, visible window titles, and count. Expected: exactly one dashboard window, with no splash, blank, restored-hidden, or second window. |
| L2 **manual** | Close dashboard | Close the dashboard window using its normal close control. | Expected: the window disappears and the menu-bar item remains usable. Record whether any Dock icon or process state changes. |
| L3 **manual** | Reopen/focus | Use the menu-bar **Open Dashboard** command; repeat it several times, including rapid repeats. | Expected: an existing dashboard is focused, or one new dashboard opens; never more than one dashboard window. Record window count and focus behavior. |
| I1 **manual** | Dock and document icons | Observe the Dock during launch, close, reopen, minimize, and focus. Also observe Finder/app activation. | Record screenshots or notes. Expected: the correct product icon only; no generic document icon, duplicate product icon, helper icon, or icon caused by opening the executable as a document. |
| M1 **manual** | Menu-bar-only state | Close the dashboard and leave the app running. Open and close the menu-bar popover; test the menu-bar setting enabled and disabled if available. | Expected: menu-bar-only operation remains responsive, no dashboard window is restored unexpectedly, and disabling the icon does not create an unexplained window. |
| D1 **manual** | Overview interactions | Exercise overview tabs, timeframe changes, chart movement, and a representative chart-bar selection. | Record any missing data, stale selection, lag, crash, extra window, or focus change. Expected: interactions remain usable and return to the expected dashboard state. |
| D2 **manual** | Projects and sessions | Expand/collapse a project, open a project, expand sessions, open a session, scroll, and switch to another project. | Record the project/session used and any loading or stale-data behavior. Expected: navigation, scrolling, and selection work without an extra dashboard window. |
| D3 **manual** | Conversation window | Open and close **Debug Conversation** for one representative session, including Raw events if available. | Expected: the auxiliary window opens and closes normally, the dashboard remains usable, and no duplicate Dock/document icon appears. |
| S1 **manual** | Settings | Open Settings with the dashboard open and closed; close it and reopen it once. | Record window title/count and focus. Expected: settings opens once, remains usable, and does not leave a blank or hidden dashboard window. |
| U1 **manual** | Updater | Invoke **Check for Updates** from the product menu. | Record whether the updater sheet/window appears, reports no update, or reports an update. Expected: no crash, duplicate icon, or dashboard-window regression. Do not install an update as part of this baseline unless explicitly intended. |
| Q1 **manual** | Product Quit | Quit through the product menu or `Cmd-Q` while the dashboard, settings, and any conversation window have each been tested. | Record time and remaining app processes. Expected: the product exits cleanly and no Codex Dashboard process remains. |

## Process and memory sample

Run the sampler only while the installed app is already open. It discovers the
bundle executable from the installed `Info.plist`, finds its PID with
`pgrep -x`, and prints a verifying `ps` row before sampling. If discovery finds
more than one process, choose the PID manually and pass `--pid`; do not kill a
process to make the result fit the checklist.

```bash
cd /Users/chunyangwen/Documents/Ideas/CodexDashboard
zsh docs/dashboard-installed-process-sample.sh \
  --app /Applications/CodexDashboard.app \
  > /tmp/codexdashboard-installed-baseline-$(date +%Y%m%d-%H%M%S).txt
```

To identify the PID without the sampler, read the installed executable name and
verify the process command line:

```bash
APP=/Applications/CodexDashboard.app
EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")
pgrep -x "$EXEC"
ps -p PID -o pid=,ppid=,state=,etime=,rss=,vsz=,comm=,command=
```

Replace `PID` with the numeric result. If there is more than one matching PID,
record all of them and use the one whose `command` begins with the installed
bundle executable path. A PID is not evidence of a helper process; this
Milestone 1 artifact measures the current installed app only.

The sampler runs these measurable commands against the selected PID:

```bash
ps -p PID -o pid=,ppid=,state=,etime=,rss=,vsz=,comm=,command=
vmmap -summary PID
heap PID
```

Record the sampler file name, timestamp, PID, `rss` from `ps`, the physical
footprint / dirty / swapped totals reported by `vmmap -summary`, and the
headline allocation totals or errors reported by `heap`. Tool availability and
permissions vary by Xcode/Command Line Tools installation; retain the exact
error text when a command cannot run. A full map can be saved separately when
needed:

```bash
vmmap PID > /tmp/codexdashboard-vmmap-PID.txt
heap PID > /tmp/codexdashboard-heap-PID.txt
```

The `/tmp` examples are explicit output files; no command above writes to
`/Applications` or changes the running process.

Take at least these samples and label them in the notes:

1. **Host baseline:** after launch settles, before opening the dashboard if
   that state is reachable.
2. **Dashboard open:** while the dashboard and one representative auxiliary
   window are visible.
3. **Dashboard closed:** after closing dashboard-owned windows and waiting for
   background work to settle.
4. **Final:** after product Quit, to confirm no PID remains (a failed `ps`
   lookup is the expected result).

For the current single-process build, label the samples accurately rather than
calling them host/helper measurements. The separate host/helper memory gate
belongs to later milestones.

## Repeat and crash checks

These are intentionally **manual-only** in this baseline. The sampler has no
launch, force-quit, or kill operation.

| ID | Check | Procedure and record |
| --- | --- | --- |
| R1 **manual** | Repeat cycle | Repeat launch → wait for one dashboard → close dashboard → reopen for 20 cycles. Record each cycle’s window count, PID, and any crash, stale window, Dock icon, or focus anomaly. Compare the first and last process samples for a visible upward trend. |
| R2 **manual** | Crash/recovery | On a disposable test run, use Activity Monitor’s **Force Quit** on the running app only after recording its PID. Reopen from Finder/Dock and record whether the app returns to one dashboard and whether the menu-bar state is usable. Do not perform this against an unrelated user process. |
| R3 **manual** | Quit cleanup | Quit with the dashboard and auxiliary windows open, then verify in Activity Monitor or `ps` that no app process remains. Record any orphan process or crash dialog. |

## Result record

| Area | Result / evidence |
| --- | --- |
| Automated characterization tests | Passed before this checklist: yes / no / not run |
| L1–L3 launch/window behavior | |
| I1 Dock/icon behavior | |
| M1 menu-bar-only behavior | |
| D1–D3 representative interactions | |
| S1/U1/Q1 settings/updater/Quit | |
| Process samples and tool errors | |
| R1–R3 repeat/crash/cleanup | |
| Baseline accepted by | |
| Date | |

Do not advance the process-separation plan until this record, the
characterization-test result, and the installed-app evidence are attached to
the milestone review.

## Recorded pre-separation baseline — 2026-08-24

This observation was made against the already installed production bundle,
not the current uninstalled checkout.

| Field | Recorded value |
| --- | --- |
| macOS | 26.6.1 (25G76), arm64 |
| Installed bundle | `/Applications/CodexDashboard.app` |
| Installed version/build | 0.1.5 / 20260823190317 |
| Process | PID 48748, executable inside the installed bundle |
| First presentation | One accessible standard window titled `Overview`, identifier `CodexDashboard.dashboard` |
| Visible dashboard structure | One sidebar and one dashboard content area; Overview, Projects, Models, and Usage & Billing navigation present |
| Visual window check | Existing dashboard content appeared directly with the expected dark UI; no second or blank dashboard window was present |
| Close behavior | Earlier close verification left the process alive with no accessible dashboard window and released full dashboard model arrays |
| Reopen behavior | Activating the installed app returned one `Overview` window rather than a duplicate |

Measured process evidence from the same launch:

| State | Physical footprint | Heap evidence |
| --- | ---: | --- |
| Dashboard open, 10:26 | 125.1 MB, peak 247.5 MB | `SessionSummary`, `ToolMetric`, `ModelMetric`, indexed metrics, and Charts render state present |
| Dashboard closed, 09:43 | 97.1 MB | No dashboard session/tool/model/index arrays; one compact `MenuBarDayMetrics` allocation remained |

The closed state retained approximately 44 MB of malloc-zone fragmentation
despite releasing dashboard data. That observation is the memory problem this
process-separation plan must eliminate. Dock-icon appearance, updater behavior,
20-cycle repetition, and forced-crash recovery remain final installed-helper
release gates because the current production build has no helper process to
exercise.

## M7 status-item AX evidence

The installed M7 harness identifies the menu-bar control with the stable AX
identifier `com.chunyangwen.CodexDashboard.status-item`, then falls back to
the visible `Codex quota` title/description. It never clicks a Control Center
ordinal such as “item 26”; an unnamed item is not proof of app ownership.

Run the read-only diagnostic before the full memory gate:

```bash
zsh docs/dashboard-status-item-ax-diagnostic.sh \
  > /tmp/codexdashboard-status-item-ax-$(date +%Y%m%d-%H%M%S).txt
```

`AX_ACCESSIBLE=1` plus a `MATCH=stable-identifier` or
`MATCH=visible-semantic-title` line proves that macOS exposes the item with a
safe semantic match. `AX_ACCESSIBLE=1` with only unnamed items proves that the
Control Center AX tree hides the item's identity and the M7 gate must stop
without clicking. `AX_ACCESSIBLE=0` records a desktop permission/tooling
blocker (for example Apple Events error `-10827`); it does not prove the app is
missing a status item. This shell-only diagnostic cannot prove visual Dock,
window, or focus behavior; those remain desktop-observation steps.
