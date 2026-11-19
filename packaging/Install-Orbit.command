#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
echo 'Orbit installs app blocking, foreground tracking and Chrome policy setup.'
echo 'Have the VPS DEVICE, ACTIVITY and BROWSER tokens and published Chrome Web Store extension ID ready. macOS will request administrator authorization.'
./OrbitSetup --install "$PWD/Orbit.pkg" || {
  echo 'Installation did not complete. Review the error above.'
  read -rp 'Press Enter to close. ' _
  exit 1
}
