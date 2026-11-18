#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"
if [ "$(id -u)" -ne 0 ]; then echo 'Run with sudo on the target Mac.' >&2; exit 1; fi
if [ -L settings.json ]; then echo "Refusing symlinked settings." >&2; exit 1; fi
if [ ! -f settings.json ]; then echo 'Create agent/settings.json as described in README.md first.' >&2; exit 1; fi
build_dir=$(mktemp -d /private/tmp/orbit-build.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
/usr/bin/swiftc -O main.swift -framework Security -o "$build_dir/orbit-agent"
"$build_dir/orbit-agent" --check-settings settings.json
settings_dir='/Library/Application Support/Orbit'
if [ -e "$settings_dir" ] || [ -L "$settings_dir" ]; then
  [[ ! -L "$settings_dir" && -d "$settings_dir" && $(stat -f %u "$settings_dir") == 0 ]] || { echo 'Unsafe Orbit settings directory.' >&2; exit 1; }
  permissions=$(stat -f %Lp "$settings_dir")
  (( (8#$permissions & 8#022) == 0 )) || { echo 'Orbit settings directory must not be group/world writable.' >&2; exit 1; }
fi
# Refuse to associate another server with a cached policy.
if [ -f "$settings_dir/settings.json" ]; then
  "$build_dir/orbit-agent" --check-settings "$settings_dir/settings.json"
  old_server=$("$build_dir/orbit-agent" --print-server-origin "$settings_dir/settings.json")
  new_server=$("$build_dir/orbit-agent" --print-server-origin settings.json)
  [[ $old_server == "$new_server" ]] || { echo 'Existing server differs; review the cached policy before reconfiguring.' >&2; exit 1; }
elif [ -e "$settings_dir/policy.json" ]; then
  echo 'Cached policy has no server settings; review it before reconfiguring.' >&2; exit 1
fi
install -d -m 700 -o root -g wheel "$settings_dir"
install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
if launchctl print system/com.side-forge.orbit.agent >/dev/null 2>&1; then
  launchctl bootout system/com.side-forge.orbit.agent
fi
install -m 755 -o root -g wheel "$build_dir/orbit-agent" /Library/PrivilegedHelperTools/orbit-agent
install -m 600 -o root -g wheel settings.json '/Library/Application Support/Orbit/settings.json'
install -m 644 -o root -g wheel com.side-forge.orbit.agent.plist /Library/LaunchDaemons/com.side-forge.orbit.agent.plist
launchctl enable system/com.side-forge.orbit.agent
launchctl bootstrap system /Library/LaunchDaemons/com.side-forge.orbit.agent.plist
launchctl kickstart system/com.side-forge.orbit.agent
rm "$build_dir/orbit-agent"
echo 'Installed. Check the website for a successful device connection.'
echo 'For browser protection, run browser/install-browsers.sh with the published Chrome extension ID/update URL and optional signed Safari package.'
echo 'The Chrome configuration profile requires approval; Safari extension enablement requires user or management approval.'
