#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
echo 'Orbit installs app blocking and foreground tracking for the currently logged-in user.'
echo 'Have the VPS device and activity tokens ready. macOS will request administrator authorization.'
./OrbitSetup --install "$PWD/Orbit.pkg" || {
  echo 'Installation did not complete. Review the error above.'
  read -rp 'Press Enter to close. ' _
  exit 1
}
