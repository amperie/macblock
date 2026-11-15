#!/bin/bash
# Local Mac development. Does not install or modify privileged services unless --enforce is specified.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Requires macOS' >&2; exit 1; }
enforce=0
for arg in "$@"; do case "$arg" in --enforce) enforce=1;; *) echo "Unknown option: $arg" >&2; exit 2;; esac; done
command -v mkcert >/dev/null || { echo 'Install mkcert (brew install mkcert) and run mkcert -install once.' >&2; exit 1; }
command -v swiftc >/dev/null || { echo 'Xcode Command Line Tools required' >&2; exit 1; }
work="$PWD/.macblock-dev"
mkdir -p "$work"
chmod 700 "$work"
if [[ ! -f "$work/localhost.pem" || ! -f "$work/localhost-key.pem" ]]; then
  (cd "$work" && mkcert -cert-file localhost.pem -key-file localhost-key.pem localhost 127.0.0.1)
fi
chmod 600 "$work/localhost-key.pem"
if [[ ! -f "$work/tokens.env" ]]; then
  python3 - "$work/tokens.env" <<'PY'
import secrets,sys
with open(sys.argv[1], 'x') as f:
    for name in ('ADMIN','DEVICE','ACTIVITY','BROWSER'):
        f.write('MACBLOCK_'+name+'_TOKEN='+secrets.token_urlsafe(48)+'\n')
PY
fi
chmod 600 "$work/tokens.env"
set -a
# Generated locally, not from user input.
source "$work/tokens.env"
set +a
export MACBLOCK_DB="$work/macblock.sqlite3" MACBLOCK_DEV_CERT="$work/localhost.pem" MACBLOCK_DEV_KEY="$work/localhost-key.pem" PORT=18443
url='https://localhost:18443'
python3 dev/https_server.py >"$work/server.log" 2>&1 &
server_pid=$!
monitor_pid=''
cleanup() {
  [[ -z "$monitor_pid" ]] || kill "$monitor_pid" 2>/dev/null || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  echo 'Stopped development server and monitor. Privileged daemon, if installed, remains installed.'
}
trap cleanup EXIT INT TERM
for i in {1..40}; do
  if curl -fsS --max-time 2 "$url/" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$work/server.log"; exit 1; fi
  sleep 0.25
done
curl -fsS --max-time 3 "$url/" >/dev/null || { echo 'HTTPS server failed; check mkcert trust and server.log' >&2; exit 1; }
python3 - "$work" "$url" "$MACBLOCK_DEVICE_TOKEN" "$MACBLOCK_ACTIVITY_TOKEN" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
(root/'device-settings.json').write_text(json.dumps({'serverURL':sys.argv[2],'deviceToken':sys.argv[3]}))
(root/'monitor-settings.json').write_text(json.dumps({'serverURL':sys.argv[2],'activityToken':sys.argv[4]}))
PY
chmod 600 "$work/"*settings.json
swiftc -O agent/FocusTracker.swift agent/ForegroundMonitor.swift -framework AppKit -framework IOKit -o "$work/macblock-foreground"
# Monitor currently loads settings from the user's Application Support directory.
# Do not overwrite an installed production monitor's credentials.
if launchctl list 2>/dev/null | grep -q 'com.macblock.foreground'; then
  echo 'Installed foreground monitor is running; skipping duplicate development monitor.'
else
  MACBLOCK_MONITOR_SETTINGS="$work/monitor-settings.json" \
  MACBLOCK_MONITOR_QUEUE="$work/activity-queue.json" \
    "$work/macblock-foreground" >"$work/monitor.log" 2>&1 &
  monitor_pid=$!
fi
if ((enforce)); then
  echo 'WARNING: --enforce installs/updates the root LaunchDaemon and may terminate Roblox.'
  echo 'Existing MacBlock daemon settings will be replaced. Press Ctrl-C to cancel.'
  read -r -p 'Type ENFORCE to proceed: ' confirmation
  [[ "$confirmation" == ENFORCE ]] || exit 2
  if [[ -f agent/settings.json ]]; then
    echo 'agent/settings.json exists; refusing to overwrite it. Use a clean test checkout.' >&2
    exit 1
  fi
  cp "$work/device-settings.json" agent/settings.json
  chmod 600 agent/settings.json
  sudo bash agent/install.sh
  rm -f agent/settings.json
fi
echo
echo "Dashboard: $url/"
echo "Admin token (local only): $MACBLOCK_ADMIN_TOKEN"
echo "Server log: $work/server.log"
echo "Chrome/Safari setup: bash dev/browsers.sh"
echo 'Ctrl-C stops the development server and launched monitor.'
wait "$server_pid"
