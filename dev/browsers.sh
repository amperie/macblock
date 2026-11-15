#!/bin/bash
# Builds an unpacked Chrome dev extension and generates Safari Xcode project.
# Browser permission prompts cannot be approved programmatically.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Requires macOS' >&2; exit 1; }
work="$PWD/.orbit-dev"
[[ -f "$work/tokens.env" ]] || { echo 'Run bash dev/start.sh first.' >&2; exit 1; }
set -a; source "$work/tokens.env"; set +a
python3 - "$work/chrome-extension" "$ORBIT_BROWSER_TOKEN" <<'PY'
import json,pathlib,shutil,sys
dst=pathlib.Path(sys.argv[1])
src=pathlib.Path('browser/chrome')
dst.mkdir(parents=True,exist_ok=True)
manifest=json.loads((src/'manifest.json').read_text())
manifest.pop('storage',None) # dev build has no enterprise managed storage
manifest['name']='Orbit Website Filter (local development)'
(dst/'manifest.json').write_text(json.dumps(manifest,indent=2))
source=(src/'background.js').read_text()
needle="  const managed = await api.storage.managed.get(['serverURL', 'browserToken']).catch(() => ({}));"
assert needle in source
source=source.replace(needle,"  const managed = {serverURL:'https://localhost:18443',browserToken:"+json.dumps(sys.argv[2])+"};")
(dst/'background.js').write_text(source)
PY
chmod -R go-rwx "$work/chrome-extension"
echo "Chrome: open chrome://extensions, enable Developer mode, click Load unpacked, select:"
echo "  $work/chrome-extension"
echo 'Chrome does not permit a normal local script to silently install an unpacked extension.'
if command -v xcrun >/dev/null && xcrun --find safari-web-extension-converter >/dev/null 2>&1; then
  echo 'Generating Safari project (Xcode and signing still required)...'
  mkdir -p "$work/safari"
  xcrun safari-web-extension-converter "$work/chrome-extension" \
    --project-location "$work/safari" --app-name OrbitSafariDev \
    --bundle-identifier com.side-forge.orbit.safari.dev --no-open
  echo "Open the generated Safari Xcode project in $work/safari, choose your signing team,"
  echo 'run the containing app, and enable its extension in Safari Settings.'
else
  echo 'Safari conversion requires full Xcode and safari-web-extension-converter.'
fi
echo 'NOTE: Browser extension testing needs the local HTTPS server running.'
echo 'The development browser token is visible to the local user and grants read-only domain access.'
