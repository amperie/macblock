#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(id -u)" -eq 0 ]; then echo "Run as the logged-in standard user, not root." >&2; exit 1; fi
if [ ! -f monitor-settings.json ]; then echo "Create agent/monitor-settings.json first." >&2; exit 1; fi
if [ -L monitor-settings.json ]; then echo "Refusing symlinked settings." >&2; exit 1; fi
settings_dir="$HOME/Library/Application Support/Orbit"
mkdir -p "$settings_dir" "$HOME/Library/LaunchAgents"
chmod 700 "$settings_dir"
install -m 600 monitor-settings.json "$settings_dir/monitor-settings.json"
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
swiftc -O FocusTracker.swift ForegroundMonitor.swift -framework AppKit -framework IOKit -o "$build_dir/orbit-foreground"
# A user-owned binary avoids requiring administrator privileges for monitoring.
install -m 700 "$build_dir/orbit-foreground" "$settings_dir/orbit-foreground"
plist="$HOME/Library/LaunchAgents/com.side-forge.orbit.foreground.plist"
if [ -L "$plist" ]; then echo "Refusing symlinked LaunchAgent plist." >&2; exit 1; fi
install -m 600 com.side-forge.orbit.foreground.plist "$plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $settings_dir/orbit-foreground" "$plist"
/usr/bin/plutil -lint "$plist"
uid=$(id -u)
launchctl bootout "gui/$uid/com.side-forge.orbit.foreground" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/com.side-forge.orbit.foreground.plist"
echo "Foreground monitor installed in current user's GUI session."
