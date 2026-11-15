#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(id -u)" -ne 0 ]; then echo 'Run with sudo on the target Mac.' >&2; exit 1; fi
if [ ! -f settings.json ]; then echo 'Create agent/settings.json as described in README.md first.' >&2; exit 1; fi
/usr/bin/plutil -lint -s settings.json >/dev/null
build_dir=$(mktemp -d /private/tmp/macblock-build.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
/usr/bin/swiftc -O main.swift -framework Security -o "$build_dir/macblock-agent"
install -d -m 700 -o root -g wheel '/Library/Application Support/MacBlock'
install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
launchctl bootout system/com.macblock.agent 2>/dev/null || true
install -m 755 -o root -g wheel "$build_dir/macblock-agent" /Library/PrivilegedHelperTools/macblock-agent
install -m 600 -o root -g wheel settings.json '/Library/Application Support/MacBlock/settings.json'
install -m 644 -o root -g wheel com.macblock.agent.plist /Library/LaunchDaemons/com.macblock.agent.plist
launchctl bootstrap system /Library/LaunchDaemons/com.macblock.agent.plist
rm "$build_dir/macblock-agent"
echo 'Installed. Check the website for a successful device connection.'
echo 'For browser protection, run browser/install-browsers.sh with the published Chrome extension ID/update URL and optional signed Safari package.'
echo 'The Chrome configuration profile requires approval; Safari extension enablement requires user or management approval.'
