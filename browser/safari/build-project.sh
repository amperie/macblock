#!/bin/bash
set -euo pipefail
# Run on macOS with Xcode installed. This generates an Xcode project;
# it does not sign, install, or enable the Safari extension.
cd "$(dirname "$0")/../.."
command -v xcrun >/dev/null || { echo 'Xcode command line tools required' >&2; exit 1; }
xcrun safari-web-extension-converter browser/chrome --project-location browser/safari --app-name OrbitSafari --bundle-identifier com.macblock.safari --no-open
echo 'Open the Orbit Xcode project, configure signing, build the containing app, and enable the extension in Safari Settings.'
