#!/bin/zsh
set -euo pipefail

app_path="${1:-/Applications/CodexDashboard.app}"
host_binary="$app_path/Contents/MacOS/CodexDashboard"
helper_binary="$app_path/Contents/Helpers/CodexDashboardUI.app/Contents/MacOS/CodexDashboardUI"
status_item_identifier="com.chunyangwen.CodexDashboard.status-item"
cycle_count="${M7_MEMORY_GATE_CYCLES:-20}"
open_physical_budget_mb="${M7_OPEN_PHYSICAL_BUDGET_MB:-}"

if ! [[ "$cycle_count" =~ '^[0-9]+$' ]] || (( cycle_count < 20 )); then
  print -u2 "M7_MEMORY_GATE_CYCLES must be an integer of at least 20"
  exit 2
fi

host_pid() {
  ps -axo pid=,command= | awk -v binary="$host_binary" \
    'index($0, binary) && $0 !~ /awk/ { print $1; found=1; exit }' || true
}

helper_pid() {
  ps -axo pid=,command= | awk -v binary="$helper_binary" \
    'index($0, binary) && $0 ~ /--codex-dashboard/ && $0 !~ /awk/ { print $1; found=1; exit }' || true
}

physical_footprint() {
  vmmap -summary "$1" | awk '/Physical footprint:/ && $0 !~ /peak/ && value == "" { value=$3 } END { print value }'
}

vmmap_indicators() {
  local pid="$1"
  local summary
  summary="$(vmmap -summary "$pid" 2>&1)" || {
    print "vmmap indicators unavailable for pid=$pid"
    return 0
  }
  print -r -- "$summary" | awk '
    BEGIN { IGNORECASE = 1; found = 0 }
    /private/ || /shared/ || /compressed/ || /swapped/ { print; found = 1 }
    END {
      if (!found) print "vmmap -summary exposed no private/shared indicator lines on this system"
    }
  '
}

rss_kb() {
  ps -p "$1" -o rss= | awk '{ print $1 }'
}

mb_value() {
  awk -v value="$1" 'BEGIN { sub(/M$/, "", value); print value + 0 }'
}

if [[ -z "$(host_pid)" ]]; then
  open -a "$app_path"
  sleep 1
fi
host="$(host_pid)"
[[ -n "$host" ]] || { print -u2 "host did not start"; exit 1; }

close_dashboard() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
    set dashboardProcess to first process whose bundle identifier is "com.chunyangwen.CodexDashboard.DashboardUI"
    repeat with candidateWindow in windows of dashboardProcess
        if exists close button 1 of candidateWindow then
            click close button 1 of candidateWindow
            exit repeat
        end if
    end repeat
end tell
APPLESCRIPT
}

open_dashboard_from_status_item() {
  open_status_item
  osascript <<'APPLESCRIPT'
tell application "System Events"
    set hostProcess to first process whose bundle identifier is "com.chunyangwen.CodexDashboard"
    repeat with candidateWindow in windows of hostProcess
        if exists button "Open Dashboard" of candidateWindow then
            click button "Open Dashboard" of candidateWindow
            exit repeat
        end if
    end repeat
end tell
APPLESCRIPT
}

open_status_item() {
  osascript - "$status_item_identifier" <<'APPLESCRIPT'
on run argv
    set targetIdentifier to item 1 of argv
    tell application "System Events"
        tell application process "ControlCenter"
            if not (exists menu bar 1) then error "ControlCenter has no accessible menu bar"
            set matches to {}
            repeat with candidate in (UI elements of menu bar 1)
                set candidateIdentifier to ""
                set candidateTitle to ""
                set candidateDescription to ""
                try
                    set candidateIdentifier to (value of attribute "AXIdentifier" of candidate) as text
                end try
                try
                    set candidateTitle to (title of candidate) as text
                end try
                try
                    set candidateDescription to (description of candidate) as text
                end try
                if candidateIdentifier is targetIdentifier or candidateTitle is "Codex quota" or candidateDescription is "Codex quota" then
                    set end of matches to candidate
                end if
            end repeat
            if (count of matches) is 0 then
                error "CodexDashboard status item is not exposed with its stable identifier or visible title; refusing an ordinal click"
            end if
            if (count of matches) is not 1 then
                error "CodexDashboard status item match is ambiguous; refusing to click"
            end if
            click item 1 of matches
        end tell
    end tell
end run
APPLESCRIPT
}

# This harness intentionally launches the installed app and clicks its
# accessibility-exposed status-item controls. It never force-quits, kills, or
# deletes a process; close_dashboard uses the app's normal close button.
for _ in {1..50}; do
  [[ -z "$(helper_pid)" ]] && break
  close_dashboard
  sleep 0.1
done
sleep 2
baseline="$(physical_footprint "$host")"
baseline_mb="$(mb_value "$baseline")"
baseline_rss_kb="$(rss_kb "$host")"
print "baseline state=closed-host-baseline role=host pid=$host physical=$baseline (${baseline_mb} MB) ps_rss=${baseline_rss_kb} KB"
print "primary metric=vmmap physical footprint"
print "secondary metric=ps RSS; RSS must not be summed across host/helper because shared framework pages can be double-counted"
print "current helper bundle=$app_path/Contents/Helpers/CodexDashboardUI.app"
print "baseline vmmap private/shared indicators:"
vmmap_indicators "$host"

typeset -a closed_host_mb_values
closed_host_mb_values=()
gate_status=0

if command -v lipo >/dev/null 2>&1; then
  print "host architectures: $(lipo -archs "$host_binary" 2>/dev/null || print unknown)"
  print "helper architectures: $(lipo -archs "$helper_binary" 2>/dev/null || print unknown)"
fi

for cycle in {1..$cycle_count}; do
  # Match the app-owned AX identifier first, then its visible semantic title.
  # Never click by Control Center ordinal: unnamed items are not safe evidence
  # of ownership and can change across macOS releases or user configuration.
  open_dashboard_from_status_item

  helper=""
  for _ in {1..50}; do
    helper="$(helper_pid)"
    [[ -n "$helper" ]] && break
    sleep 0.1
  done
  [[ -n "$helper" ]] || { print -u2 "dashboard helper did not start"; exit 1; }

  open_host_physical="$(physical_footprint "$host")"
  open_host_mb="$(mb_value "$open_host_physical")"
  helper_physical="$(physical_footprint "$helper")"
  helper_mb="$(mb_value "$helper_physical")"
  open_host_rss_kb="$(rss_kb "$host")"
  helper_rss_kb="$(rss_kb "$helper")"
  open_physical_report="host=$open_host_physical helper=$helper_physical"
  print "cycle=$cycle state=open role=host pid=$host physical=$open_host_physical (${open_host_mb} MB) ps_rss=${open_host_rss_kb} KB"
  print "cycle=$cycle state=open role=host vmmap private/shared indicators:"
  vmmap_indicators "$host"
  print "cycle=$cycle state=open role=helper pid=$helper physical=$helper_physical (${helper_mb} MB) ps_rss=${helper_rss_kb} KB"
  print "cycle=$cycle state=open role=helper vmmap private/shared indicators:"
  vmmap_indicators "$helper"
  print "cycle=$cycle state=open per-process physical footprints: $open_physical_report (diagnostic; not a whole-system total)"
  if [[ -n "$open_physical_budget_mb" ]]; then
    open_physical_total_mb="$(awk -v a="$open_host_mb" -v b="$helper_mb" 'BEGIN { printf "%.1f", a+b }')"
    print "cycle=$cycle state=open physical-footprint sum=$open_physical_total_mb MB budget=$open_physical_budget_mb MB"
    if ! awk -v value="$open_physical_total_mb" -v budget="$open_physical_budget_mb" 'BEGIN { exit(value <= budget ? 0 : 1) }'; then
      print -u2 "open physical-footprint budget exceeded on cycle $cycle"
      gate_status=1
    fi
  fi

  close_dashboard

  helper_exit_s=""
  for _ in {1..20}; do
    if [[ -z "$(helper_pid)" ]]; then
      helper_exit_s="<=$((10 * _))0ms"
      break
    fi
    sleep 0.1
  done
  [[ -z "$(helper_pid)" ]] || { print -u2 "helper did not exit within 2 seconds"; exit 1; }

  sleep 2
  after="$(physical_footprint "$host")"
  after_mb="$(mb_value "$after")"
  after_rss_kb="$(rss_kb "$host")"
  delta_mb="$(awk -v a="$baseline_mb" -v b="$after_mb" 'BEGIN { printf "%.1f", b-a }')"
  closed_host_mb_values+=("$after_mb")
  print "cycle=$cycle state=closed role=host helper=$helper exit=$helper_exit_s pid=$host physical=$after (${after_mb} MB) ps_rss=${after_rss_kb} KB delta=${delta_mb} MB"
  print "cycle=$cycle state=closed role=host vmmap private/shared indicators:"
  vmmap_indicators "$host"
  if ! awk -v delta="$delta_mb" 'BEGIN { exit((delta >= -5 && delta <= 5) ? 0 : 1) }'; then
    print -u2 "closed-host physical footprint exceeded the 5 MB baseline gate on cycle $cycle"
    gate_status=1
  fi
done

trend_report="$(printf '%s\n' "${closed_host_mb_values[@]}" | awk '
  { values[NR] = $1; total += $1 }
  END {
    n = NR
    window = (n < 5 ? n : 5)
    for (i = 1; i <= window; i++) first += values[i]
    for (i = n - window + 1; i <= n; i++) last += values[i]
    first /= window
    last /= window
    print first, last, last - first
  }
')"
read -r first_window_mb last_window_mb trend_delta_mb <<< "$trend_report"
print "closed-host trend first_window=${first_window_mb} MB last_window=${last_window_mb} MB delta=${trend_delta_mb} MB over $cycle_count cycles"
if ! awk -v delta="$trend_delta_mb" 'BEGIN { exit(delta <= 1 ? 0 : 1) }'; then
  print -u2 "closed-host physical footprint shows a sustained upward trend"
  gate_status=1
fi

exit "$gate_status"
