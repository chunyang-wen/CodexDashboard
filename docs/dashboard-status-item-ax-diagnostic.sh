#!/bin/zsh

set -u

status_item_identifier="com.chunyangwen.CodexDashboard.status-item"
if (( $# > 0 )); then
  status_item_identifier="$1"
fi

print "CodexDashboard status-item AX diagnostic"
print "timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
print "identifier: $status_item_identifier"
print "process: ControlCenter"
print
print "Each item is reported as item=<ordinal>|role=<role>|title=<title>|description=<description>|identifier=<AXIdentifier>."
print "An empty title/description/identifier is an unnamed item; the installed gate must refuse to click it."
print

set +e
osascript - "$status_item_identifier" <<'APPLESCRIPT'
on run argv
    set targetIdentifier to item 1 of argv
    tell application "System Events"
        tell application process "ControlCenter"
            if not (exists menu bar 1) then error "ControlCenter has no accessible menu bar"
            set output to "AX_ACCESSIBLE=1" & linefeed
            set itemNumber to 0
            repeat with candidate in (UI elements of menu bar 1)
                set itemNumber to itemNumber + 1
                set candidateRole to ""
                set candidateTitle to ""
                set candidateDescription to ""
                set candidateIdentifier to ""
                try
                    set candidateRole to (role of candidate) as text
                end try
                try
                    set candidateTitle to (title of candidate) as text
                end try
                try
                    set candidateDescription to (description of candidate) as text
                end try
                try
                    set candidateIdentifier to (value of attribute "AXIdentifier" of candidate) as text
                end try
                set output to output & "item=" & itemNumber & "|role=" & candidateRole & "|title=" & candidateTitle & "|description=" & candidateDescription & "|identifier=" & candidateIdentifier & linefeed
                if candidateIdentifier is targetIdentifier then
                    set output to output & "MATCH=stable-identifier" & linefeed
                else if candidateTitle is "Codex quota" or candidateDescription is "Codex quota" then
                    set output to output & "MATCH=visible-semantic-title" & linefeed
                end if
            end repeat
            return output
        end tell
    end tell
end run
APPLESCRIPT
probe_status=$?
set -e

if (( probe_status != 0 )); then
  print "AX_ACCESSIBLE=0"
  print "AX_RESULT=unavailable-or-denied (preserve the exact osascript error above)"
  exit 2
fi
