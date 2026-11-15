#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(id -u)" -ne 0 ]; then echo 'Run with sudo on the target Mac.' >&2; exit 1; fi
if [ ! -f settings.json ]; then echo 'Create agent/settings.json as described in README.md first.' >&2; exit 1; fi
/usr/bin/plutil -lint -s settings.json >/dev/null
build_dir=$(mktemp -d /private/tmp/orbit-build.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
/usr/bin/swiftc -O main.swift -framework Security -o "$build_dir/orbit-agent"
install -d -m 700 -o root -g wheel '/Library/Application Support/Orbit'
install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
launchctl bootout system/com.side-forge.orbit.agent 2>/dev/null || true
install -m 755 -o root -g wheel "$build_dir/orbit-agent" /Library/PrivilegedHelperTools/orbit-agent
install -m 600 -o root -g wheel settings.json '/Library/Application Support/Orbit/settings.json'
install -m 644 -o root -g wheel com.side-forge.orbit.agent.plist /Library/LaunchDaemons/com.side-forge.orbit.agent.plist
launchctl bootstrap system /Library/LaunchDaemons/com.side-forge.orbit.agent.plist
rm "$build_dir/orbit-agent"
echo 'Installed. Check the website for a successful device connection.'
echo 'For browser protection, run browser/install-browsers.sh with the published Chrome extension ID/update URL and optional signed Safari package.'
echo 'The Chrome configuration profile requires approval; Safari extension enablement requires user or management approval.'
