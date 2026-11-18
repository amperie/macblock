#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./OrbitUninstall --prompt || {
  echo 'Uninstall did not complete or was cancelled. Review the message above.'
  read -rp 'Press Enter to close. ' _
  exit 1
}
