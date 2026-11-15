#!/bin/bash
# Privileged development daemon lifecycle. Never replace an existing installation.
set -euo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
action="${1:-}"
root='/Library/Application Support/MacBlock'
plist='/Library/LaunchDaemons/com.macblock.agent.plist'
binary='/Library/PrivilegedHelperTools/macblock-agent'
marker="$root/.macblock-dev-owner"
case "$action" in
  install)
    [[ $# -eq 4 ]] || { echo 'Usage: sudo bash dev/daemon.sh install BUILD_BINARY SETTINGS SESSION_ID' >&2; exit 2; }
    source_binary="$2" source_settings="$3" session="$4"
    [[ "$session" =~ ^[a-zA-Z0-9-]{12,100}$ ]] || exit 2
    [[ -f "$source_binary" && -f "$source_settings" && ! -L "$source_binary" && ! -L "$source_settings" ]] || exit 2
    if [[ -e "$plist" || -e "$binary" || -e "$root/settings.json" || -e "$marker" ]]; then
      echo 'Existing MacBlock installation or state found. Refusing to replace it.' >&2
      exit 1
    fi
    install -d -m 700 -o root -g wheel "$root"
    install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
    install -m 755 -o root -g wheel "$source_binary" "$binary"
    install -m 600 -o root -g wheel "$source_settings" "$root/settings.json"
    install -m 644 -o root -g wheel "$(dirname "$0")/../agent/com.macblock.agent.plist" "$plist"
    printf '%s\n' "$session" > "$marker"
    chmod 600 "$marker"
    if ! launchctl bootstrap system "$plist"; then
      echo 'Bootstrap failed; run dev/stop.sh to clean up.' >&2
      exit 1
    fi
    echo 'Development daemon installed.'
    ;;
  remove)
    [[ $# -eq 2 ]] || exit 2
    session="$2"
    [[ -f "$marker" && ! -L "$marker" ]] || { echo 'No development ownership marker; refusing removal.' >&2; exit 1; }
    [[ "$(<"$marker")" == "$session" ]] || { echo 'Session mismatch; refusing removal.' >&2; exit 1; }
    launchctl bootout system/com.macblock.agent 2>/dev/null || true
    rm -f "$plist" "$binary" "$root/settings.json" "$root/policy.json" "$marker"
    rmdir "$root" 2>/dev/null || true
    [[ ! -e "$plist" && ! -e "$binary" && ! -e "$marker" ]] || exit 1
    echo 'Development daemon removed and verified.'
    ;;
  *) echo 'Usage: daemon.sh install|remove ...' >&2; exit 2;;
esac
