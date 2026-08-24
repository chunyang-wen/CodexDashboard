#!/bin/zsh
set -euo pipefail

app_path="${1:-/Applications/CodexDashboard.app}"
host_binary="$app_path/Contents/MacOS/CodexDashboard"
helper_binary="$app_path/Contents/Helpers/CodexDashboardUI.app/Contents/MacOS/CodexDashboardUI"
status_item_identifier="com.chunyangwen.CodexDashboard.status-item"
cycle_count="${M7_POPOVER_CYCLES:-5}"

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

for _ in {1..50}; do
  [[ -z "$(helper_pid)" ]] && break
  close_dashboard
  sleep 0.1
done
sleep 2
baseline="$(physical_footprint "$host")"
baseline_mb="$(mb_value "$baseline")"
print "baseline host=$host physical=$baseline (${baseline_mb} MB)"

for cycle in {1..$cycle_count}; do
  # Match the app-owned AX identifier first, then its visible semantic title.
  # Never click by Control Center ordinal: unnamed items are not safe evidence
  # of ownership and can change across macOS releases or user configuration.
  open_status_item

  osascript <<'APPLESCRIPT'
tell application "System Events"
    set popoverProcess to first process whose bundle identifier is "com.chunyangwen.CodexDashboard.PopoverUI"
    repeat with candidateWindow in windows of popoverProcess
        if exists button "Open Dashboard" of candidateWindow then
            click button "Open Dashboard" of candidateWindow
            exit repeat
        end if
    end repeat
end tell
APPLESCRIPT

  helper=""
  for _ in {1..50}; do
    helper="$(helper_pid)"
    [[ -n "$helper" ]] && break
    sleep 0.1
  done
  [[ -n "$helper" ]] || { print -u2 "dashboard helper did not start"; exit 1; }

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
  delta_mb="$(awk -v a="$baseline_mb" -v b="$after_mb" 'BEGIN { printf "%.1f", b-a }')"
  print "cycle=$cycle helper=$helper exit=$helper_exit_s host=$host physical=$after (${after_mb} MB) delta=${delta_mb} MB"
done
