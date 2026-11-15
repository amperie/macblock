#!/bin/bash
# Diagnostic only: do not claim a browser is protected from these checks alone.
set -euo pipefail
id="${1:-}"
if [[ ! "$id" =~ ^[a-p]{32}$ ]]; then
  echo 'Usage: bash browser/check-browsers.sh CHROME_EXTENSION_ID' >&2
  exit 2
fi
echo 'Chrome:'
if command -v profiles >/dev/null; then
  profiles show -type configuration 2>/dev/null | grep -F -m1 "$id" >/dev/null \
    && echo '  Configuration profile references the extension ID.' \
    || echo '  No installed configuration profile referencing extension ID found.'
else
  echo '  Profile inspection unavailable.'
fi
echo '  Verify chrome://policy shows ExtensionSettings and chrome://extensions shows the extension enabled.'
echo '  Confirm blocked navigation manually; policy presence does not prove enforcement.'
echo 'Safari:'
if command -v pluginkit >/dev/null; then
  pluginkit -m -A 2>/dev/null | grep -i 'macblock' || echo '  No Orbit browser plugin registered (internal identifier may be macblock).'
fi
echo '  Check Safari Settings > Extensions and test blocked navigation manually.'
echo '  Plugin registration does not prove Safari filtering is enabled.'
