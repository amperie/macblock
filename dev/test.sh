#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -v
node --check server/app.js
node --check browser/chrome/background.js
node tests/test_browser.js
python3 -m json.tool browser/chrome/manifest.json >/dev/null
bash -n dev/start.sh dev/browsers.sh dev/test.sh
if [[ "$(uname -s)" == Darwin ]]; then
  swiftc agent/FocusTracker.swift tests/FocusTrackerTests.swift -o /tmp/orbit-focus-tests-$$
  /tmp/orbit-focus-tests-$$
  rm -f /tmp/orbit-focus-tests-$$
  swiftc agent/main.swift -framework Security -o /tmp/orbit-agent-test-$$
  rm -f /tmp/orbit-agent-test-$$
  swiftc agent/FocusTracker.swift agent/ForegroundMonitor.swift -framework AppKit -framework IOKit -o /tmp/orbit-monitor-test-$$
  rm -f /tmp/orbit-monitor-test-$$
fi
echo 'Local checks passed.'
