#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"
if [ "$(id -u)" -eq 0 ]; then echo "Run as the logged-in standard user, not root." >&2; exit 1; fi
if [ ! -f monitor-settings.json ]; then echo "Create agent/monitor-settings.json first." >&2; exit 1; fi
if [ -L monitor-settings.json ]; then echo "Refusing symlinked settings." >&2; exit 1; fi
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
swiftc -O FocusTracker.swift ForegroundMonitor.swift -framework AppKit -framework IOKit -o "$build_dir/orbit-foreground"
"$build_dir/orbit-foreground" --check-settings monitor-settings.json
settings_dir="$HOME/Library/Application Support/Orbit"
if [ -L "$settings_dir" ]; then echo 'Refusing symlinked monitor directory.' >&2; exit 1; fi
mkdir -p "$settings_dir" "$HOME/Library/LaunchAgents"
chmod 700 "$settings_dir"
install -m 600 monitor-settings.json "$settings_dir/monitor-settings.json"
# A user-owned binary avoids requiring administrator privileges for monitoring.
install -m 700 "$build_dir/orbit-foreground" "$settings_dir/orbit-foreground"
plist="$HOME/Library/LaunchAgents/com.side-forge.orbit.foreground.plist"
if [ -L "$plist" ]; then echo "Refusing symlinked LaunchAgent plist." >&2; exit 1; fi
install -m 600 com.side-forge.orbit.foreground.plist "$plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $settings_dir/orbit-foreground" "$plist"
/usr/bin/plutil -lint "$plist"
uid=$(id -u)
if launchctl print "gui/$uid/com.side-forge.orbit.foreground" >/dev/null 2>&1; then
  launchctl bootout "gui/$uid/com.side-forge.orbit.foreground"
fi
launchctl enable "gui/$uid/com.side-forge.orbit.foreground"
launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/com.side-forge.orbit.foreground.plist"
launchctl kickstart "gui/$uid/com.side-forge.orbit.foreground"
echo "Foreground monitor installed in current user's GUI session."
