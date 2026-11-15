#!/bin/bash
# Stop local test services and remove ONLY a daemon owned by this dev session.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$PWD/.macblock-dev"
session_file="$work/session-id"
errors=0
stop_pid() {
  local file="$1" expected="$2" pid command
  [[ -f "$file" ]] || return 0
  pid=$(cat "$file")
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    if [[ "$command" == *"$expected"* ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "Process $pid did not stop" >&2
        errors=1
      fi
    else
      echo "PID $pid no longer belongs to $expected; not killing" >&2
    fi
  fi
  rm -f "$file"
}
stop_pid "$work/monitor.pid" macblock-foreground
stop_pid "$work/server.pid" dev/https_server.py
if [[ -f "$session_file" ]]; then
  session=$(cat "$session_file")
  if [[ "$session" =~ ^[a-zA-Z0-9-]{12,100}$ ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then
      if ! sudo bash dev/daemon.sh remove "$session"; then
        echo 'Daemon removal failed; ownership was not verified or privileges were unavailable.' >&2
        errors=1
      else
        rm -f "$session_file"
      fi
    fi
  else
    echo 'Invalid session marker; refusing privileged removal' >&2
    errors=1
  fi
fi
if [[ "$(uname -s)" == Darwin ]]; then
  if launchctl print system/com.macblock.agent >/dev/null 2>&1; then
    echo 'WARNING: MacBlock daemon remains loaded (may be a non-dev installation).' >&2
    errors=1
  fi
fi
if ((errors)); then exit 1; fi
echo 'Development services stopped; no owned development daemon remains.'
