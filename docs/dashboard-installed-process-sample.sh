#!/bin/zsh

set -euo pipefail

app_path="/Applications/CodexDashboard.app"
requested_pid=""
measurement_role="unspecified"
measurement_state="unspecified"

usage() {
  cat <<'EOF'
Usage: dashboard-installed-process-sample.sh [options]

Read-only sample of a running installed CodexDashboard process.

Options:
  --app PATH   Installed .app bundle to inspect (default: /Applications/CodexDashboard.app)
  --pid PID    Process to sample; otherwise discover the app executable PID
  --role ROLE  Measurement role: host or helper (default: unspecified)
  --state STATE Measurement state, such as open, closed, or baseline
  --help       Show this help

The command prints process metadata, `ps`, `vmmap -summary`, and `heap`
output to stdout. Redirect stdout to a file when keeping a baseline. It never
launches, terminates, installs, or modifies an application or process.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      if (( $# < 2 )); then
        print -u2 "--app requires a path"
        exit 2
      fi
      app_path="$2"
      shift 2
      ;;
    --pid)
      if (( $# < 2 )); then
        print -u2 "--pid requires a number"
        exit 2
      fi
      requested_pid="$2"
      shift 2
      ;;
    --role)
      if (( $# < 2 )); then
        print -u2 "--role requires host or helper"
        exit 2
      fi
      measurement_role="$2"
      shift 2
      ;;
    --state)
      if (( $# < 2 )); then
        print -u2 "--state requires a label"
        exit 2
      fi
      measurement_state="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$app_path" ]]; then
  print -u2 "installed app not found: $app_path"
  exit 1
fi

info_plist="$app_path/Contents/Info.plist"
if [[ ! -f "$info_plist" ]]; then
  print -u2 "bundle Info.plist not found: $info_plist"
  exit 1
fi

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist" 2>/dev/null || print "unknown"
}

bundle_id="$(plist_value CFBundleIdentifier)"
bundle_executable="$(plist_value CFBundleExecutable)"
short_version="$(plist_value CFBundleShortVersionString)"
build_version="$(plist_value CFBundleVersion)"
executable_path="$app_path/Contents/MacOS/$bundle_executable"
pid="$requested_pid"

if [[ -z "$pid" ]]; then
  if [[ "$bundle_executable" == "unknown" ]]; then
    print -u2 "CFBundleExecutable is unavailable; pass --pid PID"
    exit 1
  fi

  typeset -a candidates matching
  candidates=(${(f)"$(pgrep -x "$bundle_executable" 2>/dev/null || true)"})
  if (( ${#candidates[@]} == 0 )); then
    print -u2 "no running process found for $bundle_executable; launch the installed app manually or pass --pid PID"
    exit 1
  fi
  matching=()
  for candidate in "${candidates[@]}"; do
    command_line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == "$executable_path" || "$command_line" == "$executable_path "* ]]; then
      matching+=("$candidate")
    fi
  done
  if (( ${#matching[@]} == 0 )); then
    print -u2 "no running process command line matched $executable_path"
    print -u2 "matching executable-name PIDs were: ${candidates[*]:-none}"
    print -u2 "pass one verified PID explicitly with --pid PID"
    exit 1
  fi
  if (( ${#matching[@]} > 1 )); then
    print -u2 "multiple installed-app processes found: ${matching[*]}"
    print -u2 "pass one PID explicitly with --pid PID"
    exit 1
  fi
  pid="${matching[1]}"
fi

if [[ ! "$pid" =~ '^[0-9]+$' ]]; then
  print -u2 "PID must contain only digits: $pid"
  exit 2
fi

if ! ps -p "$pid" -o pid= >/dev/null 2>&1; then
  print -u2 "process not found: $pid"
  exit 1
fi

print "CodexDashboard installed-process sample"
print "timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
print "app: $app_path"
print "bundle identifier: $bundle_id"
print "version: $short_version"
print "build: $build_version"
print "executable: $executable_path"
print "pid: $pid"
print "measurement role: $measurement_role"
print "measurement state: $measurement_state"
print "primary memory metric: vmmap physical footprint"
print "secondary diagnostic: ps RSS; do not sum RSS across host/helper because shared framework pages can be double-counted"
print

print "--- process metadata ---"
ps -p "$pid" -o pid=,ppid=,state=,etime=,rss=,vsz=,comm=,command=
print

status=0
if command -v vmmap >/dev/null 2>&1; then
  print "--- vmmap -summary $pid ---"
  vmmap_summary=""
  if ! vmmap_summary="$(vmmap -summary "$pid" 2>&1)"; then
    print -r -- "$vmmap_summary"
    status=1
  else
    print -r -- "$vmmap_summary"
    print
    print "--- vmmap primary and private/shared indicators ---"
    print -r -- "$vmmap_summary" | awk '
      BEGIN { IGNORECASE = 1 }
      /physical footprint/ || /private/ || /shared/ || /compressed/ || /swapped/ { print }
    '
    if ! print -r -- "$vmmap_summary" | awk '
      BEGIN { IGNORECASE = 1; found = 0 }
      /physical footprint/ || /private/ || /shared/ || /compressed/ || /swapped/ { found = 1 }
      END { exit(found ? 0 : 1) }
    '; then
      print "vmmap -summary exposed no private/shared indicator lines on this system"
    fi
  fi
else
  print "--- vmmap -summary $pid ---"
  print "UNAVAILABLE: vmmap is not on PATH"
  status=1
fi
print

if command -v heap >/dev/null 2>&1; then
  print "--- heap $pid ---"
  if ! heap "$pid"; then
    status=1
  fi
else
  print "--- heap $pid ---"
  print "UNAVAILABLE: heap is not on PATH"
  status=1
fi

exit "$status"
