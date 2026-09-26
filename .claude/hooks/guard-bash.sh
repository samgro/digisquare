#!/usr/bin/env bash
# PreToolUse hook for Bash: refuses commands that reach outside what a Claude
# session owns on this machine. Port 3000 is the user's own API server (dev
# servers take the first free port from 3001), and pkill/killall reach the
# user's processes and other checkouts' servers, not just this session's.
set -euo pipefail

command=$(jq -r '.tool_input.command // ""')

deny() {
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

if grep -Eq '(^|[^[:alnum:]_])PORT=3000([^[:digit:]]|$)|(localhost|127\.0\.0\.1|0\.0\.0\.0):3000([^[:digit:]]|$)' <<<"$command"; then
  deny "Port 3000 is the user's own server, never Claude's. Start dev servers with plain npm run dev (HACKYSACK_AUTOMATIC_PORT makes them take the first free port from 3001; read it from the 'Server running at' line) and test against that server, not 3000."
fi

if grep -Eq '(^|[^[:alnum:]_./-])(pkill|killall)([^[:alnum:]_-]|$)' <<<"$command"; then
  deny "pkill and killall reach processes this session did not start (the user's server, other checkouts). Kill by pid: the one you started, or the one lsof -t -iTCP:<port> -sTCP:LISTEN reports for your own port."
fi

exit 0
