#!/bin/bash
# Run as root. Generates a Chrome configuration profile and installs a signed
# Safari containing app from a parent-provided PKG. Profile approval is manual.
set -euo pipefail
usage() {
  echo 'Usage: sudo bash browser/install-browsers.sh --chrome-id ID --chrome-update-url HTTPS_URL --server-url HTTPS_URL --browser-token TOKEN [--safari-pkg SIGNED.pkg] [--output DIR]' >&2
  exit 2
}
chrome_id='' chrome_update='' server_url='' token='' safari_pkg='' output='/Library/Application Support/Orbit/Browser'
while (($#)); do
  case "$1" in
    --chrome-id) chrome_id="${2:-}"; shift 2;;
    --chrome-update-url) chrome_update="${2:-}"; shift 2;;
    --server-url) server_url="${2:-}"; shift 2;;
    --browser-token) token="${2:-}"; shift 2;;
    --safari-pkg) safari_pkg="${2:-}"; shift 2;;
    --output) output="${2:-}"; shift 2;;
    *) usage;;
  esac
done
[[ $(id -u) -eq 0 ]] || { echo 'Root privileges required' >&2; exit 1; }
[[ "$chrome_id" =~ ^[a-p]{32}$ ]] || { echo 'Supply the actual 32-letter Chrome extension ID' >&2; exit 2; }
[[ "$chrome_update" == https://* && "$server_url" == https://* ]] || { echo 'HTTPS URLs required' >&2; exit 2; }
[[ ${#token} -ge 32 ]] || { echo 'Use a distinct browser token of at least 32 characters' >&2; exit 2; }
[[ "$output" == "/Library/Application Support/Orbit/Browser" ]] || { echo 'Custom output paths are not supported for root-owned secrets' >&2; exit 2; }
# Validate each parent before creating descendants or changing permissions.
# Checking only Browser would still follow a user-controlled Orbit symlink.
/usr/bin/python3 - "$output" <<'PYDIR'
import os
import stat
import sys
from pathlib import Path
output = Path(sys.argv[1])
for path in [output.parent, output]:
    try:
        info = path.lstat()
    except FileNotFoundError:
        path.mkdir(mode=0o700)
        info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise SystemExit('Unsafe browser output directory; inspect ownership and permissions')
# Both directories are now root-owned and cannot be swapped by a standard user.
os.chmod(output, 0o700)
PYDIR
export ORBIT_CHROME_ID="$chrome_id" ORBIT_CHROME_UPDATE="$chrome_update" ORBIT_BROWSER_URL="$server_url" ORBIT_BROWSER_TOKEN="$token" ORBIT_PROFILE_OUTPUT="$output/Orbit-Chrome.mobileconfig"
/usr/bin/python3 "$(dirname "$0")/generate-profile.py"
chmod 600 "$output/Orbit-Chrome.mobileconfig"
if [[ -n "$safari_pkg" ]]; then
  [[ -f "$safari_pkg" && ! -L "$safari_pkg" ]] || { echo 'Signed Safari package not found' >&2; exit 1; }
  signature=$(/usr/sbin/pkgutil --check-signature "$safari_pkg")
  printf '%s\n' "$signature"
  if ! printf '%s\n' "$signature" | /usr/bin/grep -Eq 'Status: signed by a certificate trusted by Mac OS X|Status: signed by a certificate trusted by macOS'; then
    echo 'Safari package does not have a trusted signing chain; refusing installation.' >&2
    exit 1
  fi
  /usr/sbin/installer -pkg "$safari_pkg" -target /
fi
echo "Chrome configuration profile generated at: $output/Orbit-Chrome.mobileconfig"
echo 'Install and approve this profile using device management or macOS System Settings.'
echo 'Verify force installation in chrome://policy and chrome://extensions.'
echo 'Safari extension requires approval in Safari Settings > Extensions.'
echo 'Browser protection must be tested before considering this installation complete.'
